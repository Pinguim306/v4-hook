// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "solady/src/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/src/utils/ReentrancyGuard.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {CoilHook} from "./CoilHook.sol";

/// @title CoilLaunchpad
/// @notice The v4 launch factory for Coil — the successor to the Ouroboros v3 `createTokenV3`
///   mode. One transaction spins up a full market: a `CoilHook` (which IS the ERC-20, the LP
///   owner and the native per-swap fee router) deployed at a mined CREATE2 address, with its
///   entire supply seeded as one-sided liquidity into a fresh v4 pool. The launch is immutable
///   the instant it confirms — the hook renounces ownership inside `seed()`, and the liquidity is
///   locked by construction (no FeeLocker: the hook owns the position and never withdraws it).
///
///   Why v4 beats the v3 flow it replaces:
///     - no FeeLocker + no manual `collect()` harvest: fees come out on every swap, automatically;
///     - no `postGradTaxBps` fee-on-transfer: the fee is taken inside the swap (works with every
///       router/aggregator);
///     - the protocol's cut streams straight to `feeRecipient` — profit on volume, forever.
///
///   The hook address must encode the BEFORE_SWAP + BEFORE_SWAP_RETURNS_DELTA flags, so the salt
///   is mined off-chain (HookMiner) for the exact init code and passed to `createTokenV4`. A wrong
///   salt makes the hook constructor's own permission check revert, so a bad launch fails safely.
contract CoilLaunchpad is Ownable, ReentrancyGuard {
    /// @notice Bumped when the create signature changes; the frontend reads it to pick the ABI.
    uint256 public constant LAUNCHPAD_VERSION = 3;

    /*                            CONFIG                            */

    /// @notice Shared v4 infrastructure every launch wires into.
    IPoolManager public immutable poolManager;
    address public immutable posm;
    address public immutable permit2;

    /// @notice Protocol wallet (receives the protocol fee cut + the creation fee) and the COIL
    ///   buy&burn treasury (receives the burn cut). Updatable by the owner for future launches.
    address public feeRecipient;
    address public platformTreasury;

    /// @notice Fixed native fee charged on every launch.
    uint256 public creationFee;

    /// @notice Total supply minted per launch and seeded one-sided into the pool.
    uint256 public tokenSupply;

    /// @notice The per-swap fee waterfall applied to every launched token (bps of the swap).
    ///   protocol → feeRecipient, holder → holders/creator, burn → platformTreasury.
    CoilHook.FeeConfig public fees;

    /// @notice One-sided launch range + pre-computed pricing. Launch price is the price at
    ///   `tickUpper` (all supply is token1), so the pool opens with token-only liquidity — buyers
    ///   move price up the range. `launchSqrtPriceX96` and `launchLiquidity` are computed off-chain
    ///   for the fixed (`tokenSupply`, range) — they are constant across launches, so keeping them
    ///   as config (like Ouroboros's V3Params) avoids pulling TickMath/LiquidityAmounts on-chain.
    int24 public tickLower;
    int24 public tickUpper;
    uint160 public launchSqrtPriceX96;
    uint128 public launchLiquidity;

    /*                            MARKETS                           */

    struct Market {
        address token; // the CoilHook (token + pool + fee router)
        address creator;
        bool creatorRewards; // true = holder slice pays the creator; false = Loop (all holders)
        string name;
        string symbol;
        string metadataURI;
        uint256 createdAt;
    }

    Market[] public markets;
    mapping(address => uint256) public marketIndexByToken; // token => index+1 (0 = none)

    /*                            EVENTS                            */

    event TokenLaunchedV4(
        uint256 indexed id,
        address indexed creator,
        address indexed token,
        uint256 positionId,
        bool creatorRewards
    );
    event FeeRecipientUpdated(address feeRecipient);
    event TreasuryUpdated(address platformTreasury);
    event CreationFeeUpdated(uint256 creationFee);
    event TokenSupplyUpdated(uint256 tokenSupply);
    event FeesUpdated(CoilHook.FeeConfig fees);
    event RangeUpdated(int24 tickLower, int24 tickUpper);

    /*                            ERRORS                           */

    error InsufficientCreationFee();
    error NativeTransferFailed();
    error ZeroAddress();

    /// @dev One-sided launch range + its off-chain-computed pricing (constant for the fixed
    ///   supply/range). Grouped so the constructor stays within the legacy stack limit.
    struct LaunchConfig {
        int24 tickLower;
        int24 tickUpper;
        uint160 sqrtPriceX96;
        uint128 liquidity;
    }

    constructor(
        address initialOwner,
        IPoolManager _poolManager,
        address _posm,
        address _permit2,
        address _feeRecipient,
        address _platformTreasury,
        uint256 _creationFee,
        uint256 _tokenSupply,
        CoilHook.FeeConfig memory _fees,
        LaunchConfig memory _launch
    ) {
        if (
            _posm == address(0) || _permit2 == address(0) || _feeRecipient == address(0)
                || _platformTreasury == address(0)
        ) revert ZeroAddress();
        _initializeOwner(initialOwner);
        poolManager = _poolManager;
        posm = _posm;
        permit2 = _permit2;
        feeRecipient = _feeRecipient;
        platformTreasury = _platformTreasury;
        creationFee = _creationFee;
        tokenSupply = _tokenSupply;
        fees = _fees;
        tickLower = _launch.tickLower;
        tickUpper = _launch.tickUpper;
        launchSqrtPriceX96 = _launch.sqrtPriceX96;
        launchLiquidity = _launch.liquidity;
    }

    /*                            ADMIN                            */

    function setFeeRecipient(address v) external onlyOwner {
        if (v == address(0)) revert ZeroAddress();
        feeRecipient = v;
        emit FeeRecipientUpdated(v);
    }

    function setPlatformTreasury(address v) external onlyOwner {
        if (v == address(0)) revert ZeroAddress();
        platformTreasury = v;
        emit TreasuryUpdated(v);
    }

    function setCreationFee(uint256 v) external onlyOwner {
        creationFee = v;
        emit CreationFeeUpdated(v);
    }

    function setTokenSupply(uint256 v) external onlyOwner {
        tokenSupply = v;
        emit TokenSupplyUpdated(v);
    }

    function setFees(CoilHook.FeeConfig calldata v) external onlyOwner {
        fees = v;
        emit FeesUpdated(v);
    }

    function setLaunchConfig(LaunchConfig calldata v) external onlyOwner {
        tickLower = v.tickLower;
        tickUpper = v.tickUpper;
        launchSqrtPriceX96 = v.sqrtPriceX96;
        launchLiquidity = v.liquidity;
        emit RangeUpdated(v.tickLower, v.tickUpper);
    }

    function marketsCount() external view returns (uint256) {
        return markets.length;
    }

    /// @notice Return a page of markets, newest first — convenient for the frontend.
    function getMarkets(uint256 offset, uint256 limit) external view returns (Market[] memory page) {
        uint256 n = markets.length;
        if (offset >= n) return new Market[](0);
        uint256 end = offset + limit;
        if (end > n) end = n;
        page = new Market[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            page[i - offset] = markets[n - 1 - i];
        }
    }

    /*                            LAUNCH                           */

    /// @notice Compute the exact CoilHook init code hash for a launch, so the frontend can mine
    ///   the CREATE2 salt (via HookMiner) that lands the hook on a BEFORE_SWAP-flagged address.
    ///   `creator` must be the launching wallet (msg.sender) when `creatorRewards` is true, else 0.
    function hookInitCodeHash(string calldata name, string calldata symbol, address creator)
        external
        view
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(type(CoilHook).creationCode, _ctorArgs(name, symbol, creator)));
    }

    function _ctorArgs(string calldata name, string calldata symbol, address creator)
        internal
        view
        returns (bytes memory)
    {
        return abi.encode(
            poolManager,
            address(this), // owner — the launchpad calls seed() then the hook renounces
            posm,
            permit2,
            feeRecipient,
            platformTreasury,
            creator,
            tokenSupply,
            name,
            symbol,
            fees
        );
    }

    /// @notice Launch a token straight into a v4 pool with the native per-swap fee. `salt` is the
    ///   CREATE2 salt mined off-chain (see `hookInitCodeHash`) so the hook lands on a valid hook
    ///   address. `creatorRewards`: false = Loop Rewards (holder slice → all holders); true =
    ///   Creator Rewards (that slice → the creator's wallet). Requires `creationFee`; excess is
    ///   refunded.
    function createTokenV4(
        string calldata name,
        string calldata symbol,
        string calldata metadataURI,
        bytes32 salt,
        bool creatorRewards
    ) external payable nonReentrant returns (address token, uint256 positionId) {
        if (msg.value < creationFee) revert InsufficientCreationFee();

        address creator = creatorRewards ? msg.sender : address(0);

        // 1. Deploy the hook at the mined address. The hook mints its whole supply to itself and
        //    (via BaseHook) validates that this address encodes the required flags — a wrong salt
        //    reverts here, so the launch fails safely with nothing spent but gas.
        CoilHook hook = _deployHook(name, symbol, creator, salt);
        token = address(hook);

        // 2. Seed: initialize the pool and deposit the entire supply as one-sided liquidity, then
        //    the hook renounces ownership (done inside seed()). Liquidity is locked forever.
        positionId = _seed(hook);

        // 3. Record the market (checks-effects-interactions: before any value transfer).
        _recordMarket(token, creatorRewards, name, symbol, metadataURI);

        // 4. Creation fee to the protocol wallet, refund the rest.
        if (creationFee > 0) _sendNative(feeRecipient, creationFee);
        uint256 refund = msg.value - creationFee;
        if (refund > 0) _sendNative(msg.sender, refund);

        emit TokenLaunchedV4(markets.length - 1, msg.sender, token, positionId, creatorRewards);
    }

    /// @dev Deploy the hook via CREATE2 with the mined salt. Isolated in its own frame so the
    ///   11-argument constructor call doesn't blow the legacy pipeline's stack.
    function _deployHook(string calldata name, string calldata symbol, address creator, bytes32 salt)
        internal
        returns (CoilHook hook)
    {
        hook = new CoilHook{salt: salt}(
            poolManager, address(this), posm, permit2, feeRecipient, platformTreasury, creator,
            tokenSupply, name, symbol, fees
        );
    }

    /// @dev Seed the pool with the pre-configured one-sided range + pricing. Launch price is the
    ///   price at `tickUpper`, so the whole supply is provided as token1 only.
    function _seed(CoilHook hook) internal returns (uint256 positionId) {
        positionId = hook.seed(launchSqrtPriceX96, tickLower, tickUpper, launchLiquidity);
    }

    function _recordMarket(
        address token,
        bool creatorRewards,
        string calldata name,
        string calldata symbol,
        string calldata metadataURI
    ) internal {
        markets.push(
            Market({
                token: token,
                creator: msg.sender,
                creatorRewards: creatorRewards,
                name: name,
                symbol: symbol,
                metadataURI: metadataURI,
                createdAt: block.timestamp
            })
        );
        marketIndexByToken[token] = markets.length; // index+1
    }

    function _sendNative(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
    }
}
