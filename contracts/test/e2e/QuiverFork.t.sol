// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

import {QuiverHook} from "../../src/QuiverHook.sol";
import {QuiverMirror} from "../../src/QuiverMirror.sol";

/// @dev The definitive pre-launch validation: exercises the full lifecycle — deploy, seed,
///   buy, arrow mint, fee poke, claim — against the REAL PoolManager / PositionManager /
///   Permit2 deployed on Robinhood Chain. Run with:
///
///     forge test --match-contract QuiverForkTest \
///       --fork-url https://rpc.mainnet.chain.robinhood.com -vv
///
///   Addresses default to the ones recorded in docs/DEPLOYMENTS.md; override via env
///   (POOL_MANAGER / POSITION_MANAGER / PERMIT2) for the testnet dry-run. The suite
///   self-skips when not running against chain id 4663, so it never breaks plain CI runs.
contract QuiverForkTest is Test {
    address constant DEFAULT_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant DEFAULT_POSM = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address constant DEFAULT_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // Same flag-encoded address used by the other suites (AFTER_SWAP only).
    address constant HOOK_ADDR = address(uint160(0xCAfe000000000000000000000000000000000040));

    int24 constant TICK_LOWER = -6000;
    int24 constant TICK_UPPER = 0;

    QuiverHook hook;
    QuiverMirror mirror;
    PoolSwapTest swapRouter;

    address poolManager;
    address posm;
    address permit2;

    address alice = makeAddr("alice");

    function setUp() public {
        // Only meaningful on a Robinhood Chain fork (mainnet or a testnet with the same infra).
        if (block.chainid != 4663) {
            vm.skip(true);
        }

        poolManager = vm.envOr("POOL_MANAGER", DEFAULT_POOL_MANAGER);
        posm = vm.envOr("POSITION_MANAGER", DEFAULT_POSM);
        permit2 = vm.envOr("PERMIT2", DEFAULT_PERMIT2);

        // The real infra must exist on the fork.
        require(poolManager.code.length > 0, "PoolManager has no code on this fork");
        require(posm.code.length > 0, "PositionManager has no code on this fork");
        require(permit2.code.length > 0, "Permit2 has no code on this fork");

        // Deploy the hook at the flag-encoded address (mining is exercised by Deploy.s.sol;
        // here deployCodeTo keeps the test independent of CREATE2 salt search time).
        deployCodeTo(
            "QuiverHook.sol:QuiverHook",
            abi.encode(IPoolManager(poolManager), address(this), posm, permit2),
            HOOK_ADDR
        );
        hook = QuiverHook(payable(HOOK_ADDR));
        mirror = hook.mirror();

        // A local swap router against the real PoolManager.
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
        uint128 liq = LiquidityAmounts.getLiquidityForAmount1(sqrtLower, sqrtUpper, hook.SUPPLY());
        posId = hook.seed(sqrtUpper, TICK_LOWER, TICK_UPPER, liq);
    }

    function _buy(address who, uint256 ethIn) internal {
        vm.deal(who, ethIn);
        vm.prank(who);
        swapRouter.swap{value: ethIn}(
            _key(),
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(ethIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev The whole launch lifecycle against the real chain infra in one test.
    function test_Fork_FullLifecycle() public {
        // 1. Seed: initializes the pool on the REAL PoolManager and mints the LP position
        //    on the REAL PositionManager via multicall — the exact calls the launch makes.
        uint256 posId = _seed();
        assertTrue(hook.seeded());
        assertEq(hook.hookPositionTokenId(), posId);
        assertEq(hook.owner(), address(0), "ownership renounced");

        // 2. Buy: a swap through the real PoolManager mints arrows to the buyer.
        _buy(alice, 5 ether);
        uint256 whole = hook.balanceOf(alice) / hook.UNIT();
        assertGt(whole, 0, "alice bought whole tokens");
        assertEq(hook.nftBalanceOf(alice), whole, "arrows track whole tokens");

        // 3. Fees: poke harvests from the real position; alice's arrow accrues value.
        _buy(makeAddr("bob"), 2 ether); // more volume → more fees
        hook.pokeFees();
        uint256[] memory ids = hook.ownedTokensOf(alice);
        (uint256 owedEth, uint256 owedQuiver) = hook.pendingFees(ids[0]);
        assertTrue(owedEth > 0 || owedQuiver > 0, "fees accrued to the arrow");

        // 4. Claim pays out.
        uint256 balBefore = alice.balance;
        uint256 tokBefore = hook.balanceOf(alice);
        vm.prank(alice);
        hook.claim(ids[0]);
        assertTrue(alice.balance > balBefore || hook.balanceOf(alice) > tokBefore, "claim paid");

        // 5. On-chain art resolves through the mirror.
        string memory uri = mirror.tokenURI(ids[0]);
        assertGt(bytes(uri).length, 100);
    }
}
