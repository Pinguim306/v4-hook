// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "solady/src/tokens/ERC20.sol";
import {Ownable} from "solady/src/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/src/utils/ReentrancyGuard.sol";

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";

import {BaseHook} from "./base/BaseHook.sol";
import {QuiverArt} from "./QuiverArt.sol";
import {QuiverMirror} from "./QuiverMirror.sol";

interface IPoolInit {
    function initializePool(PoolKey memory key, uint160 sqrtPriceX96) external;
}

/// @notice one v4 pool. 4663 arrows.
/// @author Quiver — a fair launch on Robinhood Chain, in the spirit of Prism (0xsolazy).
/// @dev Faithful adaptation of Prism's single-contract design: the hook IS the ERC-20, the LP
///   owner, the fee router, and the NFT ledger. Supply is 4663 (Robinhood Chain's chain id;
///   4663 = HOOD in T9). Storage packing is inspired by Vectorized's DN404 — packed
///   owner+index slot, 8 ids per Uint32 word, packed AddressData, derived art seed.
contract QuiverHook is ERC20, BaseHook, Ownable, ReentrancyGuard {
    using TransientStateLibrary for IPoolManager;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       CUSTOM ERRORS                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev `seed()` already called.
    error AlreadySeeded();

    /// @dev A required address is the zero address.
    error ZeroAddress();

    /// @dev Caller is neither owner nor approved for the NFT.
    error NotOwnerOrApproved();

    /// @dev TokenId has no owner or `from` mismatch.
    error InvalidTokenId();

    /// @dev Caller is not the mirror.
    error MirrorOnly();

    /// @dev NFT transfer recipient is address(0).
    error TransferToZero();

    /// @dev NFT transfer source equals recipient (would be a free pending-harvest).
    error SelfTransferDisallowed();

    /// @dev Native ETH send failed.
    error EthSendFailed();

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                           EVENTS                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    event Seeded(uint256 indexed posmTokenId, uint160 sqrtPriceX96, uint128 liquidity);
    event NFTMinted(address indexed to, uint256 indexed tokenId);
    event NFTBurned(address indexed from, uint256 indexed tokenId);
    event FeesPoked(uint256 ethGained, uint256 quiverGained);
    event Claimed(uint256 indexed tokenId, address indexed owner, uint256 ethOut, uint256 quiverOut);
    event PendingCredited(address indexed user, uint256 ethAmount, uint256 quiverAmount);
    event PendingWithdrawn(address indexed user, uint256 ethAmount, uint256 quiverAmount);

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         CONSTANTS                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev 4663 = Robinhood Chain's chain id (HOOD in T9). One arrow per whole token.
    uint256 public constant SUPPLY = 4663 ether;
    uint256 public constant UNIT = 1 ether;
    uint24 public constant POOL_FEE = 10_000;
    int24 public constant TICK_SPACING = 200;

    /// @dev Accumulator scaling. 1e12 fits per-share fees in uint128 (vs 1e18 which
    /// would saturate at ~340 ETH/share). Precision floor is 1 wei per share with
    /// totalShares ≤ 1e12, identical to a 1e18 scaling for any realistic claim cadence.
    uint256 private constant ACC_SCALE = 1e12;

    /// @dev Transient slot for the realignment-skip flag.
    uint256 private constant _SILENT_SLOT =
        0x9a8f8d1e3c5b7a9d6e2f4a8c7b5d3f9e1a6c4b8d2e7f5a9c3b1d6e8f2a4c7b9d;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         IMMUTABLES                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    address public immutable POSM;
    address public immutable PERMIT2;
    QuiverMirror public immutable mirror;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       PACKED STORAGE                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    bool public seeded;
    uint256 public hookPositionTokenId;
    int24 public globalTickLower;
    int24 public globalTickUpper;

    /// @dev Monotonic ERC-721 id counter. First minted id is 1.
    uint256 private _nextTokenId;

    /// @dev Live NFT count. Doubles as the share denominator for fee distribution.
    uint256 public totalShares;

    /// @dev Cumulative fees per share, scaled by `ACC_SCALE`. Monotonic, capped at uint128.
    uint256 public accFeesPerShareETH;
    uint256 public accFeesPerShareQUIVER;

    /// @dev Packed owner + ownedIndex per tokenId.
    ///   bits [  0..159] = owner address  (uint160)
    ///   bits [160..191] = ownedIndex     (uint32)
    ///   bits [192..255] = reserved
    mapping(uint256 => uint256) private _oo;

    /// @dev Per-user packed array of owned tokenIds, 8 uint32 per slot.
    mapping(address => mapping(uint256 => uint256)) private _ownedSlots;

    /// @dev Packed per-user metadata. bits [0..31] = ownedLength (uint32).
    mapping(address => uint256) private _addressData;

    /// @dev Per-NFT fee debt, packed: bits [0..127] = quiver debt, bits [128..255] = eth debt.
    mapping(uint256 => uint256) private _feeDebt;

    /// @dev Pending withdrawable balances (credited from burns / NFT moves / claim ETH fallback).
    mapping(address => uint256) public pendingETH;
    mapping(address => uint256) public pendingQUIVER;

    /// @dev NFT approvals (single + operator).
    mapping(uint256 => address) private _nftApprovals;
    mapping(address => mapping(address => bool)) private _nftOperatorApprovals;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       PACKING HELPERS                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev DN404-style: own a slot's high bits with `ownedIndex`, low bits with `owner`.
    function _ownerOf(uint256 id) internal view returns (address) {
        return address(uint160(_oo[id]));
    }

    function _ownedIndexOf(uint256 id) internal view returns (uint32) {
        return uint32(_oo[id] >> 160);
    }

    function _setOo(uint256 id, address owner, uint32 index) internal {
        _oo[id] = uint256(uint160(owner)) | (uint256(index) << 160);
    }

    /// @dev `_ownedSlots[user][index/8]` holds 8 packed uint32 tokenIds.
    function _ownedGet(address user, uint256 index) internal view returns (uint32) {
        return uint32(_ownedSlots[user][index >> 3] >> ((index & 7) << 5));
    }

    function _ownedSet(address user, uint256 index, uint32 value) internal {
        uint256 slotIdx = index >> 3;
        uint256 shift = (index & 7) << 5;
        uint256 word = _ownedSlots[user][slotIdx];
        _ownedSlots[user][slotIdx] = (word & ~(uint256(0xFFFFFFFF) << shift)) | (uint256(value) << shift);
    }

    function _ownedLength(address user) internal view returns (uint32) {
        return uint32(_addressData[user]);
    }

    function _setOwnedLength(address user, uint32 len) internal {
        uint256 v = _addressData[user];
        _addressData[user] = (v & ~uint256(0xFFFFFFFF)) | uint256(len);
    }

    function _ethDebtOf(uint256 id) internal view returns (uint128) {
        return uint128(_feeDebt[id] >> 128);
    }

    function _quiverDebtOf(uint256 id) internal view returns (uint128) {
        return uint128(_feeDebt[id]);
    }

    function _setFeeDebt(uint256 id, uint128 ethD, uint128 quiverD) internal {
        _feeDebt[id] = (uint256(ethD) << 128) | uint256(quiverD);
    }

    /// @dev Deterministic per-id art seed. No storage.
    /// Including `address(this)` decorrelates seeds across deployments.
    function _deriveSeed(uint256 id) internal view returns (bytes32) {
        return keccak256(abi.encode(id, address(this)));
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        CONSTRUCTOR                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    constructor(IPoolManager _poolManager, address _owner, address _posm, address _permit2)
        BaseHook(_poolManager)
    {
        if (_owner == address(0) || _posm == address(0) || _permit2 == address(0)) revert ZeroAddress();

        POSM = _posm;
        PERMIT2 = _permit2;

        mirror = new QuiverMirror(address(this));

        _initializeOwner(_owner);

        _mint(address(this), SUPPLY);

        _approve(address(this), _permit2, type(uint256).max);
        IAllowanceTransfer(_permit2).approve(address(this), _posm, type(uint160).max, type(uint48).max);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       ERC20 METADATA                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function name() public pure override returns (string memory) {
        return "Quiver";
    }

    function symbol() public pure override returns (string memory) {
        return "QUIVER";
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          V4 HOOK                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.afterSwap = true;
    }

    function _afterSwap(
        address, /*sender*/
        PoolKey calldata, /*key*/
        SwapParams calldata, /*params*/
        BalanceDelta, /*delta*/
        bytes calldata
    )
        internal
        pure
        override
        returns (bytes4, int128)
    {
        return (IHooks.afterSwap.selector, 0);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                            SEED                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Initialize the pool, deposit the entire supply as one-sided liquidity, then
    ///   renounce ownership so the launch is provably immutable (the hook keeps no privileged
    ///   powers over funds afterwards). One-shot.
    function seed(uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper, uint128 liquidity)
        external
        onlyOwner
        returns (uint256 tokenId)
    {
        if (seeded) revert AlreadySeeded();
        seeded = true;
        globalTickLower = tickLower;
        globalTickUpper = tickUpper;

        PoolKey memory key = _hostKey();

        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory mintParams = new bytes[](2);
        mintParams[0] =
            abi.encode(key, tickLower, tickUpper, liquidity, uint256(0), SUPPLY, address(this), bytes(""));
        mintParams[1] = abi.encode(key.currency0, key.currency1);

        bytes[] memory mc = new bytes[](2);
        mc[0] = abi.encodeWithSelector(IPoolInit.initializePool.selector, key, sqrtPriceX96);
        mc[1] = abi.encodeWithSelector(
            IPositionManager.modifyLiquidities.selector, abi.encode(actions, mintParams), block.timestamp + 60
        );

        tokenId = IPositionManager(POSM).nextTokenId();
        hookPositionTokenId = tokenId;
        IPositionManager(POSM).multicall(mc);

        emit Seeded(tokenId, sqrtPriceX96, liquidity);

        // Fair-launch guarantee: no owner powers remain after the pool is live.
        _setOwner(address(0));
    }

    function _hostKey() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(this)),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(this))
        });
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                     ERC20 → NFT SYNC                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function _afterTokenTransfer(
        address from,
        address to,
        uint256 /*amount*/
    )
        internal
        override
    {
        if (_isSilent()) return;

        address pm = address(poolManager);
        address self = address(this);

        bool fromIsUser = from != address(0) && from != pm && from != self;
        bool toIsUser = to != address(0) && to != pm && to != self;

        if (fromIsUser && toIsUser) _realignPair(from, to);
        else if (fromIsUser) _realignSolo(from);
        else if (toIsUser) _realignSolo(to);
    }

    function _maybePoke() private {
        if (!seeded || totalShares == 0) return;
        if (poolManager.isUnlocked()) return;
        pokeFees();
    }

    function _realignPair(address from, address to) private {
        uint256 fromTarget = balanceOf(from) / UNIT;
        uint256 toTarget = balanceOf(to) / UNIT;
        uint256 fromCur = _ownedLength(from);
        uint256 toCur = _ownedLength(to);

        uint256 fromLoses = fromCur > fromTarget ? fromCur - fromTarget : 0;
        uint256 toGains = toTarget > toCur ? toTarget - toCur : 0;

        uint256 transferable = fromLoses < toGains ? fromLoses : toGains;
        uint256 toBurn = fromLoses - transferable;
        uint256 toMint = toGains - transferable;

        if (toMint > 0) _maybePoke();

        for (uint256 i = 0; i < transferable; i++) {
            uint256 tokenId = _pickTail(from);
            _move(from, to, tokenId);
        }
        for (uint256 i = 0; i < toBurn; i++) {
            uint256 tokenId = _pickTail(from);
            _burnNFT(from, tokenId);
        }
        for (uint256 i = 0; i < toMint; i++) {
            _mintNFT(to);
        }
    }

    function _realignSolo(address user) private {
        uint256 target = balanceOf(user) / UNIT;
        uint256 cur = _ownedLength(user);

        if (target > cur) {
            uint256 toMint = target - cur;
            _maybePoke();
            for (uint256 i = 0; i < toMint; i++) {
                _mintNFT(user);
            }
        } else if (cur > target) {
            uint256 toBurn = cur - target;
            for (uint256 i = 0; i < toBurn; i++) {
                uint256 tokenId = _pickTail(user);
                _burnNFT(user, tokenId);
            }
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                     NFT INTERNAL OPS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function _mintNFT(address to) private {
        unchecked {
            uint256 tokenId = ++_nextTokenId;
            uint32 index = _ownedLength(to);
            _setOo(tokenId, to, index);
            _ownedSet(to, index, uint32(tokenId));
            _setOwnedLength(to, index + 1);
            _setFeeDebt(tokenId, uint128(accFeesPerShareETH), uint128(accFeesPerShareQUIVER));
            totalShares = totalShares + 1;
            mirror.emitTransfer(address(0), to, tokenId);
            emit NFTMinted(to, tokenId);
        }
    }

    /// @dev Burn an NFT held by `from`.
    function _burnNFT(address from, uint256 tokenId) private {
        _captureAndCreditPending(from, tokenId);

        uint32 index = _ownedIndexOf(tokenId);
        uint32 lastIdx = _ownedLength(from) - 1;

        if (index != lastIdx) {
            uint32 lastTokenId = _ownedGet(from, lastIdx);
            _ownedSet(from, index, lastTokenId);
            _setOo(lastTokenId, from, index);
        }
        _setOwnedLength(from, lastIdx);

        delete _oo[tokenId];
        delete _feeDebt[tokenId];
        delete _nftApprovals[tokenId];

        unchecked {
            totalShares = totalShares - 1;
        }
        mirror.emitTransfer(from, address(0), tokenId);
        emit NFTBurned(from, tokenId);
    }

    function _move(address from, address to, uint256 tokenId) private {
        _captureAndCreditPending(from, tokenId);
        _setFeeDebt(tokenId, uint128(accFeesPerShareETH), uint128(accFeesPerShareQUIVER));

        uint32 fromIdx = _ownedIndexOf(tokenId);
        uint32 lastIdx = _ownedLength(from) - 1;

        if (fromIdx != lastIdx) {
            uint32 lastTokenId = _ownedGet(from, lastIdx);
            _ownedSet(from, fromIdx, lastTokenId);
            _setOo(lastTokenId, from, fromIdx);
        }
        _setOwnedLength(from, lastIdx);

        uint32 toIdx = _ownedLength(to);
        _ownedSet(to, toIdx, uint32(tokenId));
        _setOo(tokenId, to, toIdx);
        _setOwnedLength(to, toIdx + 1);

        delete _nftApprovals[tokenId];
        mirror.emitTransfer(from, to, tokenId);
    }

    function _captureAndCreditPending(address holder, uint256 tokenId) private {
        uint256 owedETH = (accFeesPerShareETH - _ethDebtOf(tokenId)) / ACC_SCALE;
        uint256 owedQUIVER = (accFeesPerShareQUIVER - _quiverDebtOf(tokenId)) / ACC_SCALE;
        if (owedETH == 0 && owedQUIVER == 0) return;
        if (owedETH > 0) pendingETH[holder] += owedETH;
        if (owedQUIVER > 0) pendingQUIVER[holder] += owedQUIVER;
        emit PendingCredited(holder, owedETH, owedQUIVER);
    }

    /// @dev Pick the tail tokenId from `user`'s owned set.
    function _pickTail(address user) private view returns (uint256) {
        return _ownedGet(user, _ownedLength(user) - 1);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       FEE DISTRIBUTION                     */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function pokeFees() public {
        if (!seeded || totalShares == 0) return;
        if (poolManager.isUnlocked()) return;

        uint256 ethBefore = address(this).balance;
        uint256 quiverBefore = balanceOf(address(this));

        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(hookPositionTokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(Currency.wrap(address(0)), Currency.wrap(address(this)), address(this));

        IPositionManager(POSM).modifyLiquidities(abi.encode(actions, params), block.timestamp + 60);

        uint256 ethGained = address(this).balance - ethBefore;
        uint256 quiverGained = balanceOf(address(this)) - quiverBefore;

        if (ethGained > 0) accFeesPerShareETH += ethGained * ACC_SCALE / totalShares;
        if (quiverGained > 0) accFeesPerShareQUIVER += quiverGained * ACC_SCALE / totalShares;

        if (ethGained > 0 || quiverGained > 0) emit FeesPoked(ethGained, quiverGained);
    }

    function claim(uint256 tokenId) external nonReentrant {
        pokeFees();
        _claimOne(tokenId);
    }

    function claimMany(uint256[] calldata tokenIds) external nonReentrant {
        pokeFees();
        for (uint256 i = 0; i < tokenIds.length; i++) {
            if (_ownerOf(tokenIds[i]) != address(0)) _claimOne(tokenIds[i]);
        }
    }

    function withdrawPending() external nonReentrant {
        _withdrawPendingTo(msg.sender);
    }

    function withdrawPendingTo(address recipient) external nonReentrant {
        if (recipient == address(0)) revert TransferToZero();
        _withdrawPendingTo(recipient);
    }

    function _withdrawPendingTo(address recipient) private {
        uint256 ethAmount = pendingETH[msg.sender];
        uint256 quiverAmount = pendingQUIVER[msg.sender];
        if (ethAmount == 0 && quiverAmount == 0) return;
        pendingETH[msg.sender] = 0;
        pendingQUIVER[msg.sender] = 0;
        if (ethAmount > 0) {
            (bool ok,) = recipient.call{value: ethAmount}("");
            if (!ok) revert EthSendFailed();
        }
        if (quiverAmount > 0) {
            _transfer(address(this), recipient, quiverAmount);
        }
        emit PendingWithdrawn(msg.sender, ethAmount, quiverAmount);
    }

    function _claimOne(uint256 tokenId) private {
        address owner = _ownerOf(tokenId);
        if (owner == address(0)) revert InvalidTokenId();

        uint256 owedETH = (accFeesPerShareETH - _ethDebtOf(tokenId)) / ACC_SCALE;
        uint256 owedQUIVER = (accFeesPerShareQUIVER - _quiverDebtOf(tokenId)) / ACC_SCALE;

        _setFeeDebt(tokenId, uint128(accFeesPerShareETH), uint128(accFeesPerShareQUIVER));

        if (owedETH > 0) {
            (bool ok,) = owner.call{value: owedETH}("");
            if (!ok) {
                pendingETH[owner] += owedETH;
                emit PendingCredited(owner, owedETH, 0);
            }
        }
        if (owedQUIVER > 0) {
            _transfer(address(this), owner, owedQUIVER);
        }

        emit Claimed(tokenId, owner, owedETH, owedQUIVER);
    }

    function pendingFees(uint256 tokenId) external view returns (uint256 owedETH, uint256 owedQUIVER) {
        if (_ownerOf(tokenId) == address(0)) return (0, 0);
        owedETH = (accFeesPerShareETH - _ethDebtOf(tokenId)) / ACC_SCALE;
        owedQUIVER = (accFeesPerShareQUIVER - _quiverDebtOf(tokenId)) / ACC_SCALE;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                     MIRROR CALLBACKS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    modifier onlyMirror() {
        if (msg.sender != address(mirror)) revert MirrorOnly();
        _;
    }

    function handleNFTTransfer(address from, address to, uint256 tokenId, address caller)
        external
        onlyMirror
        nonReentrant
    {
        if (to == address(0)) revert TransferToZero();
        if (from == to) revert SelfTransferDisallowed();

        address owner = _ownerOf(tokenId);
        if (owner == address(0) || owner != from) revert InvalidTokenId();
        if (caller != owner && _nftApprovals[tokenId] != caller && !_nftOperatorApprovals[owner][caller]) {
            revert NotOwnerOrApproved();
        }

        _move(from, to, tokenId);

        _setSilent(true);
        _transfer(from, to, UNIT);
        _setSilent(false);
    }

    function handleNFTApprove(address spender, uint256 tokenId, address caller) external onlyMirror {
        address owner = _ownerOf(tokenId);
        if (owner == address(0)) revert InvalidTokenId();
        if (caller != owner && !_nftOperatorApprovals[owner][caller]) revert NotOwnerOrApproved();
        _nftApprovals[tokenId] = spender;
        mirror.emitApproval(owner, spender, tokenId);
    }

    function handleNFTSetApprovalForAll(address operator, bool approved, address caller) external onlyMirror {
        _nftOperatorApprovals[caller][operator] = approved;
        mirror.emitApprovalForAll(caller, operator, approved);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          NFT VIEWS                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function nftOwnerOf(uint256 tokenId) external view returns (address o) {
        o = _ownerOf(tokenId);
        if (o == address(0)) revert InvalidTokenId();
    }

    function nftBalanceOf(address owner) external view returns (uint256) {
        return _ownedLength(owner);
    }

    function nftGetApproved(uint256 tokenId) external view returns (address) {
        return _nftApprovals[tokenId];
    }

    function nftIsApprovedForAll(address o, address s) external view returns (bool) {
        return _nftOperatorApprovals[o][s];
    }

    function nftTokenURI(uint256 tokenId) external view returns (string memory) {
        if (_ownerOf(tokenId) == address(0)) revert InvalidTokenId();
        return QuiverArt.tokenURI(tokenId, _deriveSeed(tokenId));
    }

    /// @dev Unpacks the per-user packed array into a fresh memory array. View only.
    function ownedTokensOf(address owner) external view returns (uint256[] memory ids) {
        uint256 n = _ownedLength(owner);
        ids = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            ids[i] = uint256(_ownedGet(owner, i));
        }
    }

    /// @dev Art seed for `tokenId`. Pure function of (id, this); no storage read for seed.
    function seedOf(uint256 tokenId) external view returns (bytes32) {
        if (_ownerOf(tokenId) == address(0)) revert InvalidTokenId();
        return _deriveSeed(tokenId);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       SILENT FLAG                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function _setSilent(bool v) private {
        assembly {
            tstore(_SILENT_SLOT, v)
        }
    }

    function _isSilent() private view returns (bool v) {
        assembly {
            v := tload(_SILENT_SLOT)
        }
    }

    receive() external payable {}
}
