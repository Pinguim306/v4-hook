// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

import {QuiverHook} from "../src/QuiverHook.sol";

/// @notice One-shot launch: initialize the pool and deposit the whole supply as one-sided
///   token liquidity, then ownership is renounced inside seed().
/// @dev The launch price sits at the top of the range so the entire supply is provided as
///   QUIVER only (no ETH from the deployer — a genuine fair launch). Buyers pushing price
///   down into the range is what mints their arrows and starts fee accrual.
///
///   Env:
///     HOOK        — deployed QuiverHook address (must be the owner's hook)
///     TICK_LOWER  — lower bound of the LP range (multiple of 200)
///     TICK_UPPER  — upper bound = launch price (multiple of 200)
///   Run:
///     forge script script/Seed.s.sol:SeedQuiver --rpc-url $RPC_URL --broadcast --private-key $PK
contract SeedQuiver is Script {
    function run() external {
        QuiverHook hook = QuiverHook(payable(vm.envAddress("HOOK")));
        int24 tickLower = int24(vm.envInt("TICK_LOWER"));
        int24 tickUpper = int24(vm.envInt("TICK_UPPER"));

        require(tickLower < tickUpper, "range");
        require(tickLower % hook.TICK_SPACING() == 0 && tickUpper % hook.TICK_SPACING() == 0, "spacing");

        uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(tickLower);

        // Launch price = upper bound → position is 100% token1 (QUIVER).
        uint128 liquidity =
            LiquidityAmounts.getLiquidityForAmount1(sqrtPriceLower, sqrtPriceUpper, hook.SUPPLY());

        console2.log("sqrtPriceX96:", uint256(sqrtPriceUpper));
        console2.log("liquidity:", uint256(liquidity));

        vm.startBroadcast();
        uint256 posId = hook.seed(sqrtPriceUpper, tickLower, tickUpper, liquidity);
        vm.stopBroadcast();

        console2.log("Seeded. POSM position tokenId:", posId);
        console2.log("Owner after seed (should be 0):", hook.owner());
    }
}
