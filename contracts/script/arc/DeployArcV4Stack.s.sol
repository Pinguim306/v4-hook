// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Deploy, IPositionDescriptor, IPositionManager} from "@uniswap/v4-periphery/test/shared/Deploy.sol";

import {WrappedNative} from "../../src/WrappedNative.sol";

/// @notice Deploys the Uniswap v4 stack Coil needs on a chain that ships without one — built for
///   Circle's Arc (USDC-native gas), but chain-agnostic. Deploys PoolManager, a WETH9-style
///   wrapped-native, PositionDescriptor and PositionManager; Permit2 must already exist (on Arc
///   it is live at the canonical address).
/// @dev POSM and the descriptor are deployed via vm.getCode (upstream's Deploy helper), NOT
///   direct imports: each carries its own optimizer-runs compilation restriction (500 / 1, to
///   fit EIP-170 — see foundry.toml), and importing both here would put two irreconcilable
///   restrictions in one compilation unit. Their artifacts are emitted by the full e2e build,
///   so ALWAYS `forge build` before running:
///
///     export POOL_MANAGER_OWNER=<admin wallet> NATIVE_DECIMALS=18
///     FOUNDRY_PROFILE=e2e forge build
///     FOUNDRY_PROFILE=e2e forge script script/arc/DeployArcV4Stack.s.sol:DeployArcV4Stack \
///       --rpc-url https://rpc.testnet.arc.network --broadcast --private-key $PK
///
///   The descriptor is used directly, without upstream's TransparentUpgradeableProxy: Coil burns
///   every LP position NFT at seed, so descriptor upgradability is pointless complexity here.
///
///   Env:
///     PERMIT2             — canonical Permit2 (must have code on-chain)
///     POOL_MANAGER_OWNER  — PoolManager owner (protocol-fee admin only; can renounce later)
///     NATIVE_DECIMALS     — native currency scaling, PROBED on-chain first (Arc: 18)
///     WRAPPED_NAME/SYMBOL — default "Wrapped USDC" / "WUSDC"
///     NATIVE_LABEL        — descriptor's native currency label, default "USDC"
///     UNSUBSCRIBE_GAS_LIMIT — POSM unsubscribe gas cap, default 300000
contract DeployArcV4Stack is Script {
    function run()
        external
        returns (PoolManager poolManager, WrappedNative wrappedNative, IPositionManager posm)
    {
        address permit2 = vm.envOr("PERMIT2", 0x000000000022D473030F116dDEE9F6B43aC78BA3);
        require(permit2.code.length > 0, "Permit2 has no code on this chain - deploy it first");

        address owner = vm.envAddress("POOL_MANAGER_OWNER");
        uint8 nativeDecimals = uint8(vm.envOr("NATIVE_DECIMALS", uint256(18)));
        string memory wName = vm.envOr("WRAPPED_NAME", string("Wrapped USDC"));
        string memory wSymbol = vm.envOr("WRAPPED_SYMBOL", string("WUSDC"));
        bytes32 label = bytes32(bytes(vm.envOr("NATIVE_LABEL", string("USDC"))));
        uint256 unsubscribeGasLimit = vm.envOr("UNSUBSCRIBE_GAS_LIMIT", uint256(300_000));

        vm.startBroadcast();

        poolManager = new PoolManager(owner);
        wrappedNative = new WrappedNative(wName, wSymbol, nativeDecimals);
        IPositionDescriptor descriptor =
            Deploy.positionDescriptor(address(poolManager), address(wrappedNative), label, hex"00");
        posm = Deploy.positionManager(
            address(poolManager),
            permit2,
            unsubscribeGasLimit,
            address(descriptor),
            address(wrappedNative),
            hex"03"
        );

        vm.stopBroadcast();

        console2.log("PoolManager       :", address(poolManager));
        console2.log("WrappedNative     :", address(wrappedNative));
        console2.log("PositionDescriptor:", address(descriptor));
        console2.log("PositionManager   :", address(posm));
        console2.log("Permit2 (existing):", permit2);
        console2.log("native decimals   :", nativeDecimals);
    }
}
