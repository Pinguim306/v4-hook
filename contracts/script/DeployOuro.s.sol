// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {OuroHookV4} from "../src/OuroHookV4.sol";

/// @notice Deploys OuroHookV4 to a CREATE2 address whose flag bits encode
///   BEFORE_SWAP + BEFORE_SWAP_RETURNS_DELTA (the native per-swap fee).
/// @dev All parameters come from the environment so the one script targets testnet and mainnet:
///     POOL_MANAGER      — v4 PoolManager
///     POSITION_MANAGER  — v4 PositionManager (POSM)
///     PERMIT2           — canonical Permit2 (0x000000000022D473030F116dDEE9F6B43aC78BA3)
///     HOOK_OWNER        — address allowed to call seed() (renounced inside seed())
///     FEE_RECIPIENT     — protocol wallet that receives the protocol cut
///     PLATFORM_TREASURY — OURO buy&burn treasury that receives the burn cut
///     TOKEN_SUPPLY      — total supply (wei), e.g. 1000000e18
///     TOKEN_NAME        — ERC-20 name
///     TOKEN_SYMBOL      — ERC-20 symbol
///     PROTOCOL_FEE_BPS  — default 50  (0.50%)
///     HOLDER_FEE_BPS    — default 30  (0.30%)
///     BURN_FEE_BPS      — default 20  (0.20%)
///   Run:
///     FOUNDRY_PROFILE=e2e forge script script/DeployOuro.s.sol:DeployOuro \
///       --rpc-url $RPC_URL --broadcast --private-key $PK
contract DeployOuro is Script {
    // Canonical CREATE2 deployer proxy (same address on every EVM chain).
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @dev All constructor inputs, gathered from the environment. Kept in one memory struct so
    ///   the deploy site holds few locals (legacy codegen goes stack-too-deep otherwise).
    struct Params {
        address poolManager;
        address posm;
        address permit2;
        address owner;
        address feeRecipient;
        address treasury;
        uint256 supply;
        string name;
        string symbol;
        OuroHookV4.FeeConfig fees;
    }

    function _read() internal view returns (Params memory p) {
        p.poolManager = vm.envAddress("POOL_MANAGER");
        p.posm = vm.envAddress("POSITION_MANAGER");
        p.permit2 = vm.envAddress("PERMIT2");
        p.owner = vm.envAddress("HOOK_OWNER");
        p.feeRecipient = vm.envAddress("FEE_RECIPIENT");
        p.treasury = vm.envAddress("PLATFORM_TREASURY");
        p.supply = vm.envUint("TOKEN_SUPPLY");
        p.name = vm.envString("TOKEN_NAME");
        p.symbol = vm.envString("TOKEN_SYMBOL");
        p.fees = OuroHookV4.FeeConfig({
            protocolBps: vm.envOr("PROTOCOL_FEE_BPS", uint256(50)),
            holderBps: vm.envOr("HOLDER_FEE_BPS", uint256(30)),
            burnBps: vm.envOr("BURN_FEE_BPS", uint256(20))
        });
    }

    function _ctorArgs(Params memory p) internal pure returns (bytes memory) {
        return abi.encode(
            IPoolManager(p.poolManager),
            p.owner,
            p.posm,
            p.permit2,
            p.feeRecipient,
            p.treasury,
            p.supply,
            p.name,
            p.symbol,
            p.fees
        );
    }

    function run() external returns (OuroHookV4 hook) {
        Params memory p = _read();

        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        (address hookAddr, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(OuroHookV4).creationCode, _ctorArgs(p));

        console2.log("Mined hook address:", hookAddr);
        console2.logBytes32(salt);

        vm.startBroadcast();
        hook = new OuroHookV4{salt: salt}(
            IPoolManager(p.poolManager),
            p.owner,
            p.posm,
            p.permit2,
            p.feeRecipient,
            p.treasury,
            p.supply,
            p.name,
            p.symbol,
            p.fees
        );
        vm.stopBroadcast();

        require(address(hook) == hookAddr, "hook address mismatch");
        console2.log("OuroHookV4 deployed:", address(hook));
        console2.log("  protocol / holder / burn bps:", p.fees.protocolBps, p.fees.holderBps, p.fees.burnBps);
    }
}
