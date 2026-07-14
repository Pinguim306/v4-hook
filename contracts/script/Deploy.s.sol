// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {QuiverHook} from "../src/QuiverHook.sol";

/// @notice Deploys QuiverHook to a CREATE2 address whose flag bits encode AFTER_SWAP.
/// @dev Reads deployment parameters from the environment so the same script targets the
///   Robinhood Chain testnet and mainnet without edits:
///     POOL_MANAGER      — v4 PoolManager on the target chain
///     POSITION_MANAGER  — v4 PositionManager (POSM)
///     PERMIT2           — canonical Permit2 (usually 0x000000000022D473030F116dDEE9F6B43aC78BA3)
///     HOOK_OWNER        — address allowed to call seed() (renounced inside seed())
///   Run:
///     forge script script/Deploy.s.sol:DeployQuiver \
///       --rpc-url $RPC_URL --broadcast --private-key $PK
contract DeployQuiver is Script {
    // Canonical CREATE2 deployer proxy (same address on every EVM chain).
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external returns (QuiverHook hook) {
        address poolManager = vm.envAddress("POOL_MANAGER");
        address posm = vm.envAddress("POSITION_MANAGER");
        address permit2 = vm.envAddress("PERMIT2");
        address owner = vm.envAddress("HOOK_OWNER");

        uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG);
        bytes memory ctorArgs = abi.encode(IPoolManager(poolManager), owner, posm, permit2);

        (address hookAddr, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(QuiverHook).creationCode, ctorArgs);

        console2.log("Mined hook address:", hookAddr);
        console2.logBytes32(salt);

        vm.startBroadcast();
        hook = new QuiverHook{salt: salt}(IPoolManager(poolManager), owner, posm, permit2);
        vm.stopBroadcast();

        require(address(hook) == hookAddr, "hook address mismatch");
        console2.log("QuiverHook deployed:", address(hook));
        console2.log("QuiverMirror (ERC721):", address(hook.mirror()));
    }
}
