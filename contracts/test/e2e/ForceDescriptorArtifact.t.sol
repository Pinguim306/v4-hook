// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PositionDescriptor} from "@uniswap/v4-periphery/src/PositionDescriptor.sol";

/// @dev Emits the PositionDescriptor artifact for the vm.getCode loads in PosmTestSetup and the
///   Arc stack deploy script. See ForcePosmArtifact.t.sol for why this must be a standalone
///   compilation-unit root: PositionDescriptor.sol is restricted to 1 optimizer run (upstream's
///   own setting, to fit EIP-170) and cannot share a unit with PositionManager (500 runs).
contract ForceDescriptorArtifactTest is Test {
    function test_DescriptorArtifactEmitted() public pure {
        assertGt(type(PositionDescriptor).creationCode.length, 0, "PositionDescriptor artifact emitted");
    }
}
