// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// PosmTestSetup.deployPosm() (used by the e2e setUp) instantiates the v4 PositionManager and
// PositionDescriptor via `vm.getCode("<File>.sol:<Contract>")`, which only resolves when their
// artifacts are in the build. As a *consumer* of the v4 test helpers we import only the v4
// interfaces, so these two concrete contracts would never be compiled — and `vm.getCode` fails at
// runtime with "no matching artifact found". Importing them here forces Foundry to emit their
// artifacts. Compilation side-effect only; nothing here is used at runtime.
//
// (TransparentUpgradeableProxy — the third contract deployPosm gets via vm.getCode — is already
// imported by PosmTestSetup itself, so it compiles without help.)

import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {PositionDescriptor} from "@uniswap/v4-periphery/src/PositionDescriptor.sol";
