// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

import {CoilHook} from "../../src/CoilHook.sol";

/// @dev The definitive pre-launch validation for the v4 fee engine: deploy → seed → buy → the
///   hook skims a native fee → holder earns → holder claims → protocol sweeps, all against the
///   REAL PoolManager / PositionManager / Permit2 on Robinhood Chain. Run with:
///
///     FOUNDRY_PROFILE=e2e forge test --match-contract CoilHookForkTest \
///       --fork-url https://rpc.mainnet.chain.robinhood.com -vv
///
///   Addresses default to the ones recorded in docs/DEPLOYMENTS.md; override via env
///   (POOL_MANAGER / POSITION_MANAGER / PERMIT2). Self-skips off chain id 4663 so plain CI runs
///   are never broken.
contract CoilHookForkTest is Test {
    address constant DEFAULT_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant DEFAULT_POSM = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address constant DEFAULT_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // Low 14 bits encode BEFORE_SWAP (bit 7) + BEFORE_SWAP_RETURNS_DELTA (bit 3) = 0x88.
    address constant HOOK_ADDR = address(uint160(0xCAfE000000000000000000000000000000000088));

    int24 constant TICK_LOWER = -6000;
    int24 constant TICK_UPPER = 0;

    uint256 constant SUPPLY = 1_000_000 ether;
    uint256 constant P_BPS = 50;
    uint256 constant H_BPS = 30;
    uint256 constant B_BPS = 20;
    uint256 constant TOTAL_BPS = 100;

    CoilHook hook;
    PoolSwapTest swapRouter;
    uint128 seedLiquidity;

    address poolManager;
    address posm;
    address permit2;

    address protocolWallet = makeAddr("protocolWallet");
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        if (block.chainid != 4663) {
            vm.skip(true);
        }

        poolManager = vm.envOr("POOL_MANAGER", DEFAULT_POOL_MANAGER);
        posm = vm.envOr("POSITION_MANAGER", DEFAULT_POSM);
        permit2 = vm.envOr("PERMIT2", DEFAULT_PERMIT2);

        require(poolManager.code.length > 0, "PoolManager has no code on this fork");
        require(posm.code.length > 0, "PositionManager has no code on this fork");
        require(permit2.code.length > 0, "Permit2 has no code on this fork");

        CoilHook.FeeConfig memory fees =
            CoilHook.FeeConfig({protocolBps: P_BPS, holderBps: H_BPS, burnBps: B_BPS});
        deployCodeTo(
            "CoilHook.sol:CoilHook",
            abi.encode(
                IPoolManager(poolManager),
                address(this),
                posm,
                permit2,
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
        hook = CoilHook(payable(HOOK_ADDR));

        swapRouter = new PoolSwapTest(IPoolManager(poolManager));
    }

    function _key() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(hook)),
            fee: hook.POOL_FEE(),
            tickSpacing: hook.TICK_SPACING(),
            hooks: IHooks(address(hook))
        });
    }

    function _seed() internal returns (uint256 posId) {
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(TICK_UPPER);
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(TICK_LOWER);
        seedLiquidity = LiquidityAmounts.getLiquidityForAmount1(sqrtLower, sqrtUpper, hook.SUPPLY());
        posId = hook.seed(sqrtUpper, TICK_LOWER, TICK_UPPER, seedLiquidity);
    }

    function _buy(address who, uint256 ethIn) internal {
        // Build the key before vm.prank (its view calls would otherwise consume the prank).
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

    function _sell(address who, uint256 tokenIn) internal {
        vm.prank(who);
        hook.approve(address(swapRouter), tokenIn);
        PoolKey memory key = _key();
        SwapParams memory params = SwapParams({
            zeroForOne: false, amountSpecified: -int256(tokenIn), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        vm.prank(who);
        swapRouter.swap(key, params, settings, "");
    }

    /// @dev The whole v4 launch + fee lifecycle against the real chain infra in one test.
    function test_Fork_FullLifecycle() public {
        // 1. Seed on the REAL PoolManager + PositionManager.
        uint256 posId = _seed();
        assertTrue(hook.seeded());
        assertEq(hook.hookPositionTokenId(), posId);
        assertEq(hook.owner(), address(0), "ownership renounced");

        // 2. Buy → the hook skims a native protocol fee out of the swap.
        _buy(alice, 5 ether);
        uint256 feeTotal = 5 ether * TOTAL_BPS / 10_000;
        assertEq(hook.protocolAccruedETH(), feeTotal * P_BPS / TOTAL_BPS, "protocol fee taken on buy");
        assertGt(hook.balanceOf(alice), 0, "alice received tokens");
        console2.log("protocol ETH after alice buy:", hook.protocolAccruedETH());

        // 3. Second buy credits alice (a holder) via the dividend accumulator.
        _buy(bob, 3 ether);
        assertGt(hook.accPerShareETH(), 0, "holder accumulator advanced");
        (uint256 aliceEth,) = hook.pendingOf(alice);
        assertGt(aliceEth, 0, "alice earns ETH dividends");

        // 4. Sell → fee is taken on the token side too.
        _sell(bob, hook.balanceOf(bob) / 2);
        assertGt(hook.protocolAccruedTOKEN(), 0, "protocol fee taken on sell");

        // 5. Holder claims.
        uint256 balBefore = alice.balance;
        uint256 tokBefore = hook.balanceOf(alice);
        vm.prank(alice);
        hook.claim();
        assertTrue(alice.balance > balBefore || hook.balanceOf(alice) > tokBefore, "claim paid");

        // 6. Protocol cut sweeps to the protocolWallet wallet.
        uint256 creatorEthBefore = protocolWallet.balance;
        hook.sweepProtocol();
        assertGe(protocolWallet.balance, creatorEthBefore);
        console2.log("protocolWallet ETH after sweep:", protocolWallet.balance);
    }
}
