// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {PositionDescriptor} from "@uniswap/v4-periphery/src/PositionDescriptor.sol";

/// @dev PosmTestSetup.deployPosm() (used by every e2e setUp) instantiates the v4 PositionManager
///   and PositionDescriptor via `vm.getCode("<File>.sol:<Contract>")`, which only resolves when
///   their artifacts are emitted to the build. As a *consumer* of the v4 test helpers we import
///   only the interfaces, so Foundry would never emit these concrete contracts and `vm.getCode`
///   fails at runtime with "no matching artifact found".
///
///   A bare import isn't enough — Foundry won't emit an unreferenced dependency's artifact.
///   Referencing `type(T).creationCode` forces the full contract to be compiled AND its artifact
///   written. Nothing here runs; it exists purely for that build side-effect.
///
///   (TransparentUpgradeableProxy — the third contract deployPosm fetches via vm.getCode — is
///   already imported by PosmTestSetup itself, so it is emitted without help.)
contract ForceArtifacts {
    function force() external pure returns (uint256) {
        return type(PositionManager).creationCode.length + type(PositionDescriptor).creationCode.length;
    }
}
