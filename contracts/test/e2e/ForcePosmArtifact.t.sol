// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";

/// @dev PosmTestSetup.deployPosm() (QuiverE2E's setUp) and the Arc stack deploy script load
///   the v4 PositionManager via `vm.getCode("PositionManager.sol:PositionManager")`, which only
///   resolves when the artifact is emitted to the build. Nothing else may import the concrete
///   contract: PositionManager.sol carries a 500-optimizer-runs compilation restriction
///   (mirroring upstream, to fit EIP-170), so it must sit in its own compilation unit — this
///   file's only job is to be that unit's root. It is a real test so `forge test`'s sparse
///   compilation never drops it. Its sibling, ForceDescriptorArtifact, does the same for
///   PositionDescriptor (1 run) — the two restrictions are unsatisfiable in a single unit.
contract ForcePosmArtifactTest is Test {
    function test_PosmArtifactEmitted() public pure {
        assertGt(type(PositionManager).creationCode.length, 0, "PositionManager artifact emitted");
    }
}
