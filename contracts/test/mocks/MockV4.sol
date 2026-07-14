// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "solady/src/tokens/ERC20.sol";

/// @dev Minimal stand-ins for the v4 stack so the hook's own logic (ERC20↔NFT sync, fee
///   accounting, mirror, art) can be exercised in a small compilation unit. The real pool
///   mechanics are covered separately by the fork/e2e suite (test/e2e), which runs against a
///   genuine PoolManager + PositionManager under a native solc.

/// @notice Always reports "locked" so `pokeFees()` proceeds.
contract MockPoolManager {
    function exttload(bytes32) external pure returns (bytes32) {
        return bytes32(0);
    }
}

/// @notice Permit2 shim — the hook only ever calls `approve(...)` on it.
contract MockPermit2 {
    function approve(address, address, uint160, uint48) external {}
}

/// @notice Position-manager shim. `seed()` routes through `multicall`; `pokeFees()` routes
///   through `modifyLiquidities`, at which point the mock forwards preconfigured "harvested
///   fees" (ETH + token) to the caller so the accumulator maths can be tested end to end.
contract MockPosm {
    uint256 public counter = 1;
    uint256 public feeEth;
    uint256 public feeToken;
    address public token;

    function setToken(address t) external {
        token = t;
    }

    function setFees(uint256 _feeEth, uint256 _feeToken) external {
        feeEth = _feeEth;
        feeToken = _feeToken;
    }

    function nextTokenId() external view returns (uint256) {
        return counter;
    }

    function multicall(bytes[] calldata) external payable returns (bytes[] memory results) {
        // Simulate the position NFT being minted by the pool.
        counter += 1;
        return new bytes[](0);
    }

    function modifyLiquidities(bytes calldata, uint256) external payable {
        // Forward the configured harvest to the hook (msg.sender), one-shot per configuration.
        if (feeEth > 0) {
            (bool ok,) = msg.sender.call{value: feeEth}("");
            require(ok, "mock eth send");
            feeEth = 0;
        }
        if (feeToken > 0 && token != address(0)) {
            ERC20(token).transfer(msg.sender, feeToken);
            feeToken = 0;
        }
    }

    receive() external payable {}
}
