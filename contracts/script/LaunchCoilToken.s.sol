// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {CoilHook} from "../src/CoilHook.sol";
import {CoilLaunchpad} from "../src/CoilLaunchpad.sol";

/// @notice Launch a Coil token from the CLI: mines the CREATE2 salt (what the site's HookMiner
///   does) and calls createTokenV4. Chain-agnostic — used for the Arc pilot and for smoke tests
///   after any launchpad redeploy.
/// @dev MUST run under the DEFAULT profile: the mined salt is only valid if the local
///   `type(CoilHook).creationCode` matches the launchpad's embedded one bit-for-bit, i.e. the
///   same compiler settings the launchpad was deployed with (800 runs). The script asserts this
///   against the launchpad's on-chain `hookInitCodeHash` before spending any gas.
///
///     LAUNCHPAD=0x... TOKEN_NAME="Arc Test" TOKEN_SYMBOL="ARCT" \
///     forge script script/LaunchCoilToken.s.sol:LaunchCoilToken \
///       --rpc-url $RPC_URL --broadcast --private-key $PK
///
///   Env: LAUNCHPAD, TOKEN_NAME, TOKEN_SYMBOL, METADATA_URI (optional),
///        CREATOR_REWARDS (optional bool, default false = Loop Rewards)
contract LaunchCoilToken is Script {
    uint160 constant FLAGS =
        uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);

    function run() external returns (address token, uint256 positionId) {
        CoilLaunchpad pad = CoilLaunchpad(vm.envAddress("LAUNCHPAD"));
        string memory name = vm.envString("TOKEN_NAME");
        string memory symbol = vm.envString("TOKEN_SYMBOL");
        string memory uri = vm.envOr("METADATA_URI", string(""));
        bool creatorRewards = vm.envOr("CREATOR_REWARDS", false);

        // Creator Rewards bakes the launcher into the hook's constructor args (and address).
        // With --private-key, msg.sender here is the broadcasting wallet.
        address creator = creatorRewards ? msg.sender : address(0);

        // Reconstruct the constructor args exactly as the launchpad will (its _ctorArgs).
        (uint256 pBps, uint256 hBps, uint256 bBps) = pad.fees();
        bytes memory ctorArgs = abi.encode(
            pad.poolManager(),
            address(pad),
            pad.posm(),
            pad.permit2(),
            pad.feeRecipient(),
            pad.platformTreasury(),
            creator,
            pad.tokenSupply(),
            name,
            symbol,
            CoilHook.FeeConfig({protocolBps: pBps, holderBps: hBps, burnBps: bBps})
        );

        // Fail BEFORE mining/spending if the local CoilHook build doesn't match the launchpad's
        // embedded creation code (wrong compiler profile/settings would burn gas on a revert).
        bytes32 localHash = keccak256(abi.encodePacked(type(CoilHook).creationCode, ctorArgs));
        require(
            localHash == pad.hookInitCodeHash(name, symbol, creator),
            "local CoilHook build != launchpad's embedded creation code (wrong profile?)"
        );

        (address predicted, bytes32 salt) =
            HookMiner.find(address(pad), FLAGS, type(CoilHook).creationCode, ctorArgs);
        console2.log("mined hook address:", predicted);

        uint256 fee = pad.creationFee();
        vm.startBroadcast();
        (token, positionId) = pad.createTokenV4{value: fee}(name, symbol, uri, salt, creatorRewards);
        vm.stopBroadcast();

        require(token == predicted, "deployed address != mined address");
        console2.log("token launched    :", token);
        console2.log("position id (LP)  :", positionId);
        console2.log("creation fee paid :", fee);
        console2.log("mode              :", creatorRewards ? "Creator Rewards" : "Loop Rewards");
    }
}
