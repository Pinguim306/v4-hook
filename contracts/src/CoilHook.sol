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
import {BeforeSwapDelta, toBeforeSwapDelta, BeforeSwapDeltaLibrary} from
    "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

import {BaseHook} from "./base/BaseHook.sol";

interface IPoolInit {
    function initializePool(PoolKey memory key, uint160 sqrtPriceX96) external;
}

/// @notice A Uniswap v4 launchpad token whose hook skims a native per-swap fee.
/// @author Coil — the v4 successor to the v3 launchpad (github.com not linked on purpose).
/// @dev The profit engine for Coil on v4. Where the v3 launchpad captured post-graduation
///   volume via a manual `FeeLocker.collect()` harvest plus a `postGradTaxBps` fee-on-transfer
///   (fragile — many routers/aggregators block transfer taxes), this hook takes the fee INSIDE
///   the swap accounting via `beforeSwap` + `beforeSwapReturnDelta`. That is:
///     - clean: not a transfer tax, so it works with Uniswap, 1inch, aggregators and bots;
///     - automatic: no harvest button — the cut comes out on every trade;
///     - forever: on every swap of the pool, not only during the bonding-curve phase.
///
///   The 1% fee is split on-chain in a fixed "waterfall": PROTOCOL (your wallet), HOLDERS
///   (pro-rata dividends by ERC-20 balance, via a MasterChef-style accumulator — the same maths
///   Quiver uses, keyed on token balance instead of NFT count), and BURN (accrued to the COIL
///   platform-token buy&burn treasury). The pool's own LP fee is 0, so the trader is never
///   double-charged;
///   100% of fee capture flows through this hook where the split is fully controllable.
///
///   The hook IS the ERC-20, the LP owner, and the fee router. After `seed()` it renounces
///   ownership, so the launch is provably immutable and the liquidity is locked by construction
///   (no FeeLocker needed — the hook itself owns and never withdraws the principal).
contract CoilHook is ERC20, BaseHook, Ownable, ReentrancyGuard {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       CUSTOM ERRORS                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev `seed()` already called.
    error AlreadySeeded();

    /// @dev A required address is the zero address.
    error ZeroAddress();

    /// @dev Fee split parameters are out of range (sum must be in (0, MAX_TOTAL_FEE_BPS]).
    error InvalidFeeConfig();

    /// @dev Native ETH send failed.
    error EthSendFailed();

    /// @dev A computed fee did not fit in int128 (unreachable for realistic swap sizes).
    error FeeOverflow();

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                           EVENTS                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    event Seeded(uint256 indexed posmTokenId, uint160 sqrtPriceX96, uint128 liquidity);
    event FeeTaken(bool indexed isEth, uint256 protocol, uint256 holders, uint256 burn);
    event HoldersCredited(bool indexed isEth, uint256 amount, uint256 circulating);
    event Claimed(address indexed holder, uint256 ethOut, uint256 tokenOut);
    event ProtocolSwept(uint256 ethOut, uint256 tokenOut);
    event TreasurySwept(uint256 ethOut, uint256 tokenOut);
    event CreatorSwept(uint256 ethOut, uint256 tokenOut);

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         CONSTANTS                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    uint256 public constant UNIT = 1 ether;

    /// @dev Fee is captured entirely by the hook, so the pool's own LP fee is 0 — the trader is
    ///   never charged twice. A valid tickSpacing is still required for a static-fee pool.
    uint24 public constant POOL_FEE = 0;
    int24 public constant TICK_SPACING = 200;

    /// @dev Basis-point denominator. 100 bps = 1%.
    uint256 public constant BPS_DENOM = 10_000;

    /// @dev Hard ceiling on the total swap fee (5%). A launch cannot exceed this; keeps the
    ///   fixed, immutable config from ever being set to a predatory value.
    uint256 public constant MAX_TOTAL_FEE_BPS = 500;

    /// @dev Accumulator scaling. Shares are token wei (ERC-20 balance), so 1e18 keeps the
    ///   per-share rounding floor negligible for any realistic circulating supply.
    uint256 private constant ACC_SCALE = 1e18;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         IMMUTABLES                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    address public immutable POSM;
    address public immutable PERMIT2;

    /// @dev Total supply minted to the hook and seeded as one-sided liquidity.
    uint256 public immutable SUPPLY;

    /// @dev The fee waterfall, fixed at launch and immutable thereafter. bps of the swap amount.
    uint256 public immutable PROTOCOL_FEE_BPS; // → feeRecipient (your wallet)
    uint256 public immutable HOLDER_FEE_BPS; //   → holders (dividends by balance)
    uint256 public immutable BURN_FEE_BPS; //     → platformTreasury (COIL buy&burn)
    uint256 public immutable TOTAL_FEE_BPS; //    sum of the three

    /// @dev Where the protocol cut goes (creator/protocol wallet) and where the buy&burn cut
    ///   goes (the COIL buy&burn treasury/keeper). Excluded from holder dividends so they never
    ///   dilute real holders.
    address public immutable feeRecipient;
    address public immutable platformTreasury;

    /// @dev Rewards mode, fixed at launch. `creator == address(0)` → Loop Rewards: the holder
    ///   slice streams to all holders via the accumulator (the classic "holding is providing
    ///   liquidity" loop). A non-zero `creator` → Creator Rewards: that same slice is paid to the
    ///   creator's wallet instead (holders then earn nothing from the holder slice).
    address public immutable creator;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          STORAGE                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    bool public seeded;
    uint256 public hookPositionTokenId;

    string private _name;
    string private _symbol;

    /// @dev Circulating shares = sum of balances held by eligible (real-holder) accounts. The
    ///   pool, the hook and the protocol addresses are excluded so the fee never dilutes itself.
    uint256 public circulating;

    /// @dev Cumulative fees per circulating share, scaled by `ACC_SCALE`.
    uint256 public accPerShareETH;
    uint256 public accPerShareTOKEN;

    /// @dev Per-holder accumulator debt (settled snapshot of accPerShare) and pulled-out claim.
    mapping(address => uint256) private _debtETH;
    mapping(address => uint256) private _debtTOKEN;
    mapping(address => uint256) public claimableETH;
    mapping(address => uint256) public claimableTOKEN;

    /// @dev Accrued protocol / treasury cuts, waiting to be swept to their fixed recipients.
    uint256 public protocolAccruedETH;
    uint256 public protocolAccruedTOKEN;
    uint256 public treasuryAccruedETH;
    uint256 public treasuryAccruedTOKEN;

    /// @dev Accrued creator cut (Creator Rewards mode only), swept to `creator`.
    uint256 public creatorAccruedETH;
    uint256 public creatorAccruedTOKEN;

    /// @dev Addresses excluded from holder-dividend accounting (pool, hook, protocol wallets).
    mapping(address => bool) public isExcluded;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        CONSTRUCTOR                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    struct FeeConfig {
        uint256 protocolBps;
        uint256 holderBps;
        uint256 burnBps;
    }

    constructor(
        IPoolManager _poolManager,
        address _owner,
        address _posm,
        address _permit2,
        address _feeRecipient,
        address _platformTreasury,
        address _creator,
        uint256 _supply,
        string memory name_,
        string memory symbol_,
        FeeConfig memory _fees
    ) BaseHook(_poolManager) {
        if (
            _owner == address(0) || _posm == address(0) || _permit2 == address(0)
                || _feeRecipient == address(0) || _platformTreasury == address(0)
        ) revert ZeroAddress();
        if (_supply == 0) revert InvalidFeeConfig();

        uint256 total = _fees.protocolBps + _fees.holderBps + _fees.burnBps;
        if (total == 0 || total > MAX_TOTAL_FEE_BPS) revert InvalidFeeConfig();

        POSM = _posm;
        PERMIT2 = _permit2;
        feeRecipient = _feeRecipient;
        platformTreasury = _platformTreasury;
        creator = _creator; // address(0) → Loop Rewards; non-zero → Creator Rewards
        SUPPLY = _supply;

        PROTOCOL_FEE_BPS = _fees.protocolBps;
        HOLDER_FEE_BPS = _fees.holderBps;
        BURN_FEE_BPS = _fees.burnBps;
        TOTAL_FEE_BPS = total;

        _name = name_;
        _symbol = symbol_;

        // Excluded from holder dividends: none of these are "real" holders.
        isExcluded[address(this)] = true;
        isExcluded[address(_poolManager)] = true;
        isExcluded[_feeRecipient] = true;
        isExcluded[_platformTreasury] = true;
        // In Creator Rewards mode the creator collects the holder slice via a bucket, so its own
        // token balance must not also draw dividends — exclude it too.
        if (_creator != address(0)) isExcluded[_creator] = true;

        _initializeOwner(_owner);

        _mint(address(this), _supply);

        _approve(address(this), _permit2, type(uint256).max);
        IAllowanceTransfer(_permit2).approve(address(this), _posm, type(uint160).max, type(uint48).max);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       ERC20 METADATA                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          V4 HOOK                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.beforeSwap = true;
        p.beforeSwapReturnDelta = true;
    }

    /// @notice Skim the fee out of every swap and split it in the fixed waterfall.
    /// @dev Charges the "specified" currency: for the exact-input swaps that routers and
    ///   aggregators use this is the INPUT (ETH on buys, token on sells), so both directions
    ///   pay. The hook takes `feeTotal` from the pool and returns a matching positive
    ///   `BeforeSwapDelta`, which is the canonical v4 fee-taking pattern — the cost is pushed
    ///   onto the swapper and the hook's own delta nets to zero.
    function _beforeSwap(
        address, /*sender*/
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata /*hookData*/
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        bool exactInput = params.amountSpecified < 0;
        uint256 specifiedAmount =
            exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);

        uint256 feeTotal = specifiedAmount * TOTAL_FEE_BPS / BPS_DENOM;
        if (feeTotal == 0) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        if (feeTotal > uint256(uint128(type(int128).max))) revert FeeOverflow();

        // The specified currency is currency0 exactly when (zeroForOne == exactInput).
        Currency feeCurrency = (params.zeroForOne == exactInput) ? key.currency0 : key.currency1;

        // Physically pull the fee out of the swap into this hook (creates a hook debt the
        // returned delta below offsets). No further external calls follow — the split is pure
        // bookkeeping — so there is no reentrancy surface inside the swap.
        poolManager.take(feeCurrency, address(this), feeTotal);

        _distribute(Currency.unwrap(feeCurrency) == address(0), feeTotal);

        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(int256(feeTotal)), 0), 0);
    }

    /// @dev Split `feeTotal` (already held by the hook) into protocol / holders / burn.
    ///   `internal` (not `private`) purely so a test harness can drive it without a live pool;
    ///   it has no external/public entrypoint, so it is unreachable in production except via the
    ///   `onlyPoolManager`-guarded `_beforeSwap`.
    function _distribute(bool isEth, uint256 feeTotal) internal {
        uint256 toProtocol = feeTotal * PROTOCOL_FEE_BPS / TOTAL_FEE_BPS;
        uint256 toBurn = feeTotal * BURN_FEE_BPS / TOTAL_FEE_BPS;
        uint256 toHolders = feeTotal - toProtocol - toBurn; // remainder → holders (no dust lost)

        if (isEth) {
            protocolAccruedETH += toProtocol;
            treasuryAccruedETH += toBurn;
        } else {
            protocolAccruedTOKEN += toProtocol;
            treasuryAccruedTOKEN += toBurn;
        }
        _creditHolders(isEth, toHolders);
        emit FeeTaken(isEth, toProtocol, toHolders, toBurn);
    }

    /// @dev Route the holder slice: Creator Rewards → the creator bucket; Loop Rewards → the
    ///   dividend accumulator (with a treasury fallback when no holders exist yet, e.g. the very
    ///   first buy, so nothing is lost).
    function _creditHolders(bool isEth, uint256 toHolders) private {
        if (toHolders == 0) return;
        if (creator != address(0)) {
            if (isEth) creatorAccruedETH += toHolders;
            else creatorAccruedTOKEN += toHolders;
            return;
        }
        uint256 shares = circulating;
        if (shares == 0) {
            if (isEth) treasuryAccruedETH += toHolders;
            else treasuryAccruedTOKEN += toHolders;
            return;
        }
        if (isEth) accPerShareETH += toHolders * ACC_SCALE / shares;
        else accPerShareTOKEN += toHolders * ACC_SCALE / shares;
        emit HoldersCredited(isEth, toHolders, shares);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                            SEED                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Initialize the pool, deposit the entire supply as one-sided liquidity, then
    ///   renounce ownership so the launch is provably immutable — the hook keeps no privileged
    ///   powers and never withdraws the principal (the liquidity is locked by construction).
    ///   One-shot.
    function seed(uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper, uint128 liquidity)
        external
        onlyOwner
        returns (uint256 tokenId)
    {
        if (seeded) revert AlreadySeeded();
        seeded = true;

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
    /*                   HOLDER-DIVIDEND ACCOUNTING               */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function _eligible(address a) private view returns (bool) {
        return a != address(0) && !isExcluded[a];
    }

    /// @dev Settle a holder's owed dividends into their pulled-out balance at the CURRENT
    ///   accumulator, using their CURRENT (pre-transfer) balance, then advance their debt.
    ///   Called on both sides of every transfer before balances move.
    function _settle(address a) private {
        if (!_eligible(a)) return;
        uint256 bal = balanceOf(a);
        uint256 owedETH = bal * (accPerShareETH - _debtETH[a]) / ACC_SCALE;
        uint256 owedTOKEN = bal * (accPerShareTOKEN - _debtTOKEN[a]) / ACC_SCALE;
        if (owedETH > 0) claimableETH[a] += owedETH;
        if (owedTOKEN > 0) claimableTOKEN[a] += owedTOKEN;
        _debtETH[a] = accPerShareETH;
        _debtTOKEN[a] = accPerShareTOKEN;
    }

    function _beforeTokenTransfer(address from, address to, uint256 /*amount*/ ) internal override {
        // Credit both parties at the current accumulator before their balances change, so no one
        // earns on tokens they did not hold while the fee accrued.
        _settle(from);
        _settle(to);
    }

    function _afterTokenTransfer(address from, address to, uint256 amount) internal override {
        // Maintain the circulating-share denominator: tokens entering an eligible holder count,
        // tokens leaving one stop counting.
        if (_eligible(from)) circulating -= amount;
        if (_eligible(to)) circulating += amount;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        CLAIM / SWEEP                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Pull a holder's accrued dividends (settles up to the latest accumulator first).
    function claim() external nonReentrant {
        _settle(msg.sender);
        uint256 ethOut = claimableETH[msg.sender];
        uint256 tokenOut = claimableTOKEN[msg.sender];
        if (ethOut == 0 && tokenOut == 0) return;
        claimableETH[msg.sender] = 0;
        claimableTOKEN[msg.sender] = 0;
        if (tokenOut > 0) _transfer(address(this), msg.sender, tokenOut);
        if (ethOut > 0) {
            (bool ok,) = msg.sender.call{value: ethOut}("");
            if (!ok) revert EthSendFailed();
        }
        emit Claimed(msg.sender, ethOut, tokenOut);
    }

    /// @notice Read a holder's claimable dividends live, as if `claim()` were called now.
    function pendingOf(address holder) external view returns (uint256 owedETH, uint256 owedTOKEN) {
        owedETH = claimableETH[holder];
        owedTOKEN = claimableTOKEN[holder];
        if (_eligible(holder)) {
            uint256 bal = balanceOf(holder);
            owedETH += bal * (accPerShareETH - _debtETH[holder]) / ACC_SCALE;
            owedTOKEN += bal * (accPerShareTOKEN - _debtTOKEN[holder]) / ACC_SCALE;
        }
    }

    /// @notice Push the accrued protocol cut to `feeRecipient`. Permissionless — the funds can
    ///   only ever go to the fixed recipient, so anyone may trigger the transfer ("money shows
    ///   up" without the recipient needing to act).
    function sweepProtocol() external nonReentrant {
        uint256 ethOut = protocolAccruedETH;
        uint256 tokenOut = protocolAccruedTOKEN;
        if (ethOut == 0 && tokenOut == 0) return;
        protocolAccruedETH = 0;
        protocolAccruedTOKEN = 0;
        if (tokenOut > 0) _transfer(address(this), feeRecipient, tokenOut);
        if (ethOut > 0) {
            (bool ok,) = feeRecipient.call{value: ethOut}("");
            if (!ok) revert EthSendFailed();
        }
        emit ProtocolSwept(ethOut, tokenOut);
    }

    /// @notice Push the accrued buy&burn cut to `platformTreasury`. Permissionless (see above).
    function sweepTreasury() external nonReentrant {
        uint256 ethOut = treasuryAccruedETH;
        uint256 tokenOut = treasuryAccruedTOKEN;
        if (ethOut == 0 && tokenOut == 0) return;
        treasuryAccruedETH = 0;
        treasuryAccruedTOKEN = 0;
        if (tokenOut > 0) _transfer(address(this), platformTreasury, tokenOut);
        if (ethOut > 0) {
            (bool ok,) = platformTreasury.call{value: ethOut}("");
            if (!ok) revert EthSendFailed();
        }
        emit TreasurySwept(ethOut, tokenOut);
    }

    /// @notice Push the accrued creator cut to `creator` (Creator Rewards mode). Permissionless;
    ///   no-op in Loop Rewards mode, where the holder slice never routes here.
    function sweepCreator() external nonReentrant {
        uint256 ethOut = creatorAccruedETH;
        uint256 tokenOut = creatorAccruedTOKEN;
        if (ethOut == 0 && tokenOut == 0) return;
        creatorAccruedETH = 0;
        creatorAccruedTOKEN = 0;
        if (tokenOut > 0) _transfer(address(this), creator, tokenOut);
        if (ethOut > 0) {
            (bool ok,) = creator.call{value: ethOut}("");
            if (!ok) revert EthSendFailed();
        }
        emit CreatorSwept(ethOut, tokenOut);
    }

    receive() external payable {}
}
