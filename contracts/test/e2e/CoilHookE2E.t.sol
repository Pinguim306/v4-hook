// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PosmTestSetup} from "@uniswap/v4-periphery/test/shared/PosmTestSetup.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

import {CoilHook} from "../../src/CoilHook.sol";

/// @dev End-to-end proof of the CoilHook fee engine against a live local v4 stack
///   (PoolManager + PositionManager + Permit2 from PosmTestSetup). This is the definitive test
///   that the native per-swap fee actually fires: it runs REAL swaps through the REAL
///   PoolManager and checks that the coil skimmed the protocol / holder / burn cuts out of the
///   swap accounting — the mechanic the whole v4 migration is built on.
contract CoilHookE2ETest is PosmTestSetup {
    CoilHook coil;

    // Low 14 bits encode BEFORE_SWAP (bit 7) + BEFORE_SWAP_RETURNS_DELTA (bit 3) = 0x88.
    address constant HOOK_ADDR = address(uint160(0xCAfE000000000000000000000000000000000088));

    int24 constant TICK_LOWER = -6000;
    int24 constant TICK_UPPER = 0; // launch price at the upper bound → one-sided token1
    uint160 sqrtPriceX96;
    uint128 seedLiquidity;

    uint256 constant SUPPLY = 1_000_000 ether;
    uint256 constant P_BPS = 50; // 0.50% protocol
    uint256 constant H_BPS = 30; // 0.30% holders
    uint256 constant B_BPS = 20; // 0.20% burn → treasury
    uint256 constant TOTAL_BPS = 100; // 1%

    address protocolWallet = makeAddr("protocolWallet");
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        deployFreshManagerAndRouters();
        deployPosm(manager);

        CoilHook.FeeConfig memory fees =
            CoilHook.FeeConfig({protocolBps: P_BPS, holderBps: H_BPS, burnBps: B_BPS});
        deployCodeTo(
            "CoilHook.sol:CoilHook",
            abi.encode(
                IPoolManager(address(manager)),
                address(this),
                address(lpm),
                address(permit2),
                protocolWallet,
                treasury,
                address(0), // Loop Rewards
                SUPPLY,
                "Coil Token",
                "COIL-T",
                fees
            ),
            HOOK_ADDR
        );
        coil = CoilHook(payable(HOOK_ADDR));

        sqrtPriceX96 = TickMath.getSqrtPriceAtTick(TICK_UPPER);
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(TICK_LOWER);
        seedLiquidity = LiquidityAmounts.getLiquidityForAmount1(sqrtLower, sqrtPriceX96, coil.SUPPLY());
    }

    function _seed() internal {
        coil.seed(sqrtPriceX96, TICK_LOWER, TICK_UPPER, seedLiquidity);
    }

    function _key() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(coil)),
            fee: coil.POOL_FEE(),
            tickSpacing: coil.TICK_SPACING(),
            hooks: IHooks(address(coil))
        });
    }

    /// @dev Buy `ethIn` worth of the token (ETH→token, zeroForOne, exact input).
    function _buy(address who, uint256 ethIn) internal {
        // Build the key (external view calls to the coil) BEFORE vm.prank, or the first of those
        // calls consumes the prank and the swap runs as this test contract, not `who`.
        PoolKey memory key = _key();
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.deal(who, ethIn);
        vm.prank(who);
        swapRouter.swap{value: ethIn}(key, params, settings, "");
    }

    /// @dev Sell `tokenIn` of the token back for ETH (token→ETH, exact input).
    function _sell(address who, uint256 tokenIn) internal {
        vm.prank(who);
        coil.approve(address(swapRouter), tokenIn);
        PoolKey memory key = _key();
        SwapParams memory params = SwapParams({
            zeroForOne: false, amountSpecified: -int256(tokenIn), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        vm.prank(who);
        swapRouter.swap(key, params, settings, "");
    }

    /*                         BASICS                          */

    function test_Metadata() public view {
        assertEq(coil.name(), "Coil Token");
        assertEq(coil.symbol(), "COIL-T");
        assertEq(coil.totalSupply(), SUPPLY);
        assertEq(coil.POOL_FEE(), 0);
    }

    function test_Permissions_BeforeSwapReturnsDelta() public view {
        Hooks.Permissions memory p = coil.getHookPermissions();
        assertTrue(p.beforeSwap);
        assertTrue(p.beforeSwapReturnDelta);
        assertFalse(p.afterSwap);
    }

    function test_Seed_MintsPositionAndRenounces() public {
        assertEq(coil.owner(), address(this));
        _seed();
        assertTrue(coil.seeded());
        assertGt(coil.hookPositionTokenId(), 0);
        assertEq(coil.owner(), address(0), "ownership renounced");
    }

    /*                 THE PROFIT MECHANIC                     */

    /// @dev The core claim: on a buy the coil skims a native fee out of the ETH input and books
    ///   the exact protocol / burn cuts. Fee is computed on the specified (input) amount, so the
    ///   numbers are deterministic.
    function test_Buy_TakesNativeProtocolFee() public {
        _seed();

        uint256 ethIn = 5 ether;
        _buy(alice, ethIn);

        uint256 feeTotal = ethIn * TOTAL_BPS / 10_000; // 0.05 ETH
        // First buy: no holders existed when the fee fired, so the holder slice is routed to the
        // treasury alongside the burn slice.
        assertEq(coil.protocolAccruedETH(), feeTotal * P_BPS / TOTAL_BPS, "protocol skims 0.50%");
        assertEq(
            coil.treasuryAccruedETH(),
            feeTotal * (B_BPS + H_BPS) / TOTAL_BPS,
            "burn + (holder, no holders yet) -> treasury"
        );
        assertEq(coil.accPerShareETH(), 0, "no holder accumulator without holders");

        // The buyer still received tokens for the post-fee ETH.
        assertGt(coil.balanceOf(alice), 0, "alice received tokens");
        assertEq(coil.circulating(), coil.balanceOf(alice), "alice is the sole circulating holder");
    }

    /// @dev With a holder present, the holder slice flows to the dividend accumulator and the
    ///   protocol slice keeps stacking — proving fee capture on *every* swap, both directions.
    function test_Swaps_FeedHoldersAndProtocol_BothDirections() public {
        _seed();
        _buy(alice, 5 ether); // alice becomes the holder
        uint256 protoAfterFirst = coil.protocolAccruedETH();

        // A second buy now credits alice (a holder) on the ETH side.
        _buy(bob, 3 ether);
        assertEq(
            coil.protocolAccruedETH(), protoAfterFirst + (3 ether * TOTAL_BPS / 10_000) * P_BPS / TOTAL_BPS
        );
        assertGt(coil.accPerShareETH(), 0, "holder ETH accumulator advanced");
        (uint256 aliceEth,) = coil.pendingOf(alice);
        assertGt(aliceEth, 0, "alice earns ETH dividends from bob's buy");

        // Bob sells: the fee is now taken on the TOKEN side → token-side protocol + holder cuts.
        uint256 protoTokBefore = coil.protocolAccruedTOKEN();
        _sell(bob, coil.balanceOf(bob) / 2);
        assertGt(coil.protocolAccruedTOKEN(), protoTokBefore, "protocol skims token on sells");
        assertGt(coil.accPerShareTOKEN(), 0, "holder token accumulator advanced");
        (, uint256 aliceTok) = coil.pendingOf(alice);
        assertGt(aliceTok, 0, "alice earns token dividends from bob's sell");
    }

    /*                   CLAIM / SWEEP                         */

    function test_Holder_Claims_Dividends() public {
        _seed();
        _buy(alice, 5 ether);
        _buy(bob, 4 ether); // credits alice on ETH
        _sell(bob, coil.balanceOf(bob) / 2); // credits alice on token

        (uint256 owedEth, uint256 owedTok) = coil.pendingOf(alice);
        assertTrue(owedEth > 0 || owedTok > 0);

        uint256 ethBefore = alice.balance;
        uint256 tokBefore = coil.balanceOf(alice);
        vm.prank(alice);
        coil.claim();
        assertGe(alice.balance, ethBefore);
        assertGe(coil.balanceOf(alice), tokBefore);

        (uint256 afterEth, uint256 afterTok) = coil.pendingOf(alice);
        assertEq(afterEth, 0);
        assertEq(afterTok, 0);
    }

    function test_Protocol_Sweeps_ToCreator() public {
        _seed();
        _buy(alice, 6 ether);
        _sell(alice, coil.balanceOf(alice) / 3); // generate a token-side protocol cut too

        uint256 accruedEth = coil.protocolAccruedETH();
        uint256 accruedTok = coil.protocolAccruedTOKEN();
        assertTrue(accruedEth > 0 || accruedTok > 0);

        uint256 ethBefore = protocolWallet.balance;
        uint256 tokBefore = coil.balanceOf(protocolWallet);
        coil.sweepProtocol(); // permissionless; funds can only reach the fixed protocolWallet wallet
        assertEq(protocolWallet.balance - ethBefore, accruedEth, "protocolWallet got the ETH protocol cut");
        assertEq(coil.balanceOf(protocolWallet) - tokBefore, accruedTok, "protocolWallet got the token protocol cut");
        assertEq(coil.protocolAccruedETH(), 0);
        assertEq(coil.protocolAccruedTOKEN(), 0);
    }

    /// @dev A trader is never double-charged: pool LP fee is 0, so the only fee is the coil's 1%.
    function test_TraderPaysExactlyOnePercent_NoLpFee() public {
        _seed();
        // The whole fee capture equals TOTAL_BPS of the input; there is no separate LP fee
        // accruing to the position, because POOL_FEE == 0.
        assertEq(coil.POOL_FEE(), 0);
        _buy(alice, 10 ether);
        uint256 feeTotal = 10 ether * TOTAL_BPS / 10_000;
        // Everything captured (protocol + treasury + holder-accumulated) sums to exactly the fee.
        uint256 captured = coil.protocolAccruedETH() + coil.treasuryAccruedETH();
        // No holders at first buy → all of it is in the accrued buckets, summing to the full fee.
        assertEq(captured, feeTotal, "captured == 1% of input, nothing more");
    }
}
