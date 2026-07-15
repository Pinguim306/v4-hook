// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

import {CoilHook} from "../src/CoilHook.sol";
import {CoilLaunchpad} from "../src/CoilLaunchpad.sol";

/// @notice Deploys the CoilLaunchpad (Phase B v4 factory). Pricing for the fixed supply + range is
///   computed here (off-chain relative to the launchpad) and stored as immutable launch config, so
///   the launchpad never pulls TickMath/LiquidityAmounts on-chain.
/// @dev Env:
///     POOL_MANAGER, POSITION_MANAGER, PERMIT2  — v4 infra
///     LAUNCHPAD_OWNER   — admin (can update fee recipient/treasury/fees; not per-token power)
///     FEE_RECIPIENT     — protocol wallet (protocol fee cut + creation fee)
///     PLATFORM_TREASURY — COIL buy&burn treasury (burn cut)
///     CREATION_FEE      — native fee per launch (wei), default 0
///     TOKEN_SUPPLY      — supply per launch (wei)
///     TICK_LOWER, TICK_UPPER — one-sided range (defaults -6000 / 0)
///     PROTOCOL_FEE_BPS / HOLDER_FEE_BPS / BURN_FEE_BPS — default 50 / 30 / 20
///   Run:
///     FOUNDRY_PROFILE=e2e forge script script/DeployCoilLaunchpad.s.sol:DeployCoilLaunchpad \
///       --rpc-url $RPC_URL --broadcast --private-key $PK
contract DeployCoilLaunchpad is Script {
    function run() external returns (CoilLaunchpad pad) {
        address poolManager = vm.envAddress("POOL_MANAGER");
        address posm = vm.envAddress("POSITION_MANAGER");
        address permit2 = vm.envAddress("PERMIT2");
        address owner = vm.envAddress("LAUNCHPAD_OWNER");
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");
        address treasury = vm.envAddress("PLATFORM_TREASURY");
        uint256 creationFee = vm.envOr("CREATION_FEE", uint256(0));
        uint256 supply = vm.envUint("TOKEN_SUPPLY");

        int24 tickLower = int24(vm.envOr("TICK_LOWER", int256(-6000)));
        int24 tickUpper = int24(vm.envOr("TICK_UPPER", int256(0)));

        CoilHook.FeeConfig memory fees = CoilHook.FeeConfig({
            protocolBps: vm.envOr("PROTOCOL_FEE_BPS", uint256(50)),
            holderBps: vm.envOr("HOLDER_FEE_BPS", uint256(30)),
            burnBps: vm.envOr("BURN_FEE_BPS", uint256(20))
        });

        // Launch price = price at tickUpper (one-sided token1); liquidity for the whole supply.
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(sqrtLower, sqrtUpper, supply);
        CoilLaunchpad.LaunchConfig memory launch = CoilLaunchpad.LaunchConfig({
            tickLower: tickLower, tickUpper: tickUpper, sqrtPriceX96: sqrtUpper, liquidity: liquidity
        });

        vm.startBroadcast();
        pad = new CoilLaunchpad(
            owner, IPoolManager(poolManager), posm, permit2, feeRecipient, treasury, creationFee,
            supply, fees, launch
        );
        vm.stopBroadcast();

        console2.log("CoilLaunchpad deployed:", address(pad));
        console2.log("  supply / creationFee:", supply, creationFee);
        console2.log("  fee bps protocol/holder/burn:", fees.protocolBps, fees.holderBps, fees.burnBps);
    }
}
