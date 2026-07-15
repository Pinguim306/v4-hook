// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {CoilHook} from "../src/CoilHook.sol";
import {CoilLaunchpad} from "../src/CoilLaunchpad.sol";
import {MockPoolManager, MockPermit2, MockPosm} from "./mocks/MockV4.sol";

/// @dev Logic-level coverage of the CoilLaunchpad factory against v4 mocks: it deploys a CoilHook
///   at a mined (flag-valid) CREATE2 address, seeds it, renounces, records the market and takes
///   the creation fee. The real pool/seed/swap mechanics are covered by test/e2e (native solc).
contract CoilLaunchpadUnitTest is Test {
    CoilLaunchpad pad;
    MockPoolManager pm;
    MockPosm posm;
    MockPermit2 permit2;

    address owner = makeAddr("owner");
    address protocolWallet = makeAddr("protocolWallet");
    address treasury = makeAddr("treasury");
    address launcher = makeAddr("launcher");

    uint256 constant CREATION_FEE = 0.01 ether;
    uint256 constant SUPPLY = 1_000_000 ether;
    uint256 constant P_BPS = 50;
    uint256 constant H_BPS = 30;
    uint256 constant B_BPS = 20;
    int24 constant TICK_LOWER = -6000;
    int24 constant TICK_UPPER = 0;

    uint160 constant FLAGS = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);

    function setUp() public {
        pm = new MockPoolManager();
        posm = new MockPosm();
        permit2 = new MockPermit2();

        CoilHook.FeeConfig memory fees =
            CoilHook.FeeConfig({protocolBps: P_BPS, holderBps: H_BPS, burnBps: B_BPS});

        // Off-chain pricing is opaque to this mock suite — MockPosm.multicall ignores the seed
        // params — so plausible constants suffice here (sqrtPriceX96 at tick 0 = 2**96). The real
        // pricing is exercised in the e2e suite against a live PoolManager. See test/e2e.
        CoilLaunchpad.LaunchConfig memory launch = CoilLaunchpad.LaunchConfig({
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            sqrtPriceX96: 79228162514264337593543950336, // TickMath.getSqrtPriceAtTick(0)
            liquidity: uint128(1e24)
        });

        pad = new CoilLaunchpad(
            owner, IPoolManager(address(pm)), address(posm), address(permit2),
            protocolWallet, treasury, CREATION_FEE, SUPPLY, fees, launch
        );
    }

    /// @dev Reproduce the launchpad's exact constructor args so HookMiner finds a matching salt.
    function _mine(string memory name, string memory symbol, address creator)
        internal
        view
        returns (bytes32 salt, address predicted)
    {
        bytes memory args = abi.encode(
            IPoolManager(address(pm)),
            address(pad), // owner = the launchpad
            address(posm),
            address(permit2),
            protocolWallet,
            treasury,
            creator,
            SUPPLY,
            name,
            symbol,
            CoilHook.FeeConfig({protocolBps: P_BPS, holderBps: H_BPS, burnBps: B_BPS})
        );
        (predicted, salt) = HookMiner.find(address(pad), FLAGS, type(CoilHook).creationCode, args);
    }

    function test_Config() public view {
        assertEq(pad.LAUNCHPAD_VERSION(), 3);
        assertEq(pad.feeRecipient(), protocolWallet);
        assertEq(pad.platformTreasury(), treasury);
        assertEq(pad.creationFee(), CREATION_FEE);
        assertEq(pad.tokenSupply(), SUPPLY);
    }

    function test_CreateV4_LoopRewards() public {
        (bytes32 salt, address predicted) = _mine("Snek", "SNEK", address(0));

        uint256 protoBefore = protocolWallet.balance;
        vm.deal(launcher, 1 ether);
        vm.prank(launcher);
        (address token, uint256 positionId) =
            pad.createTokenV4{value: CREATION_FEE}("Snek", "SNEK", "ipfs://x", salt, false);

        assertEq(token, predicted, "hook landed at the mined address");
        assertEq(uint160(token) & Hooks.ALL_HOOK_MASK, FLAGS, "address encodes the hook flags");
        assertTrue(positionId > 0);

        CoilHook hook = CoilHook(payable(token));
        assertEq(hook.name(), "Snek");
        assertEq(hook.symbol(), "SNEK");
        assertEq(hook.totalSupply(), SUPPLY);
        assertTrue(hook.seeded(), "pool seeded");
        assertEq(hook.owner(), address(0), "ownership renounced");
        assertEq(hook.feeRecipient(), protocolWallet);
        assertEq(hook.platformTreasury(), treasury);
        assertEq(hook.creator(), address(0), "Loop Rewards -> no creator");

        // Market recorded, creation fee paid to the protocol wallet.
        assertEq(pad.marketsCount(), 1);
        assertEq(pad.marketIndexByToken(token), 1);
        assertEq(protocolWallet.balance - protoBefore, CREATION_FEE, "creation fee to protocol");
    }

    function test_CreateV4_CreatorRewards() public {
        // Creator Rewards → creator == the launching wallet, baked into the mined address.
        (bytes32 salt, address predicted) = _mine("Coily", "COILY", launcher);

        vm.deal(launcher, 1 ether);
        vm.prank(launcher);
        (address token,) = pad.createTokenV4{value: CREATION_FEE}("Coily", "COILY", "ipfs://y", salt, true);

        assertEq(token, predicted);
        CoilHook hook = CoilHook(payable(token));
        assertEq(hook.creator(), launcher, "creator = launcher");
        assertTrue(hook.isExcluded(launcher), "creator excluded from dividends");

        CoilLaunchpad.Market memory m = _market(0);
        assertTrue(m.creatorRewards);
        assertEq(m.creator, launcher);
    }

    function test_CreateV4_RefundsExcess() public {
        (bytes32 salt,) = _mine("Ref", "REF", address(0));
        vm.deal(launcher, 1 ether);
        uint256 before = launcher.balance;
        vm.prank(launcher);
        pad.createTokenV4{value: 0.5 ether}("Ref", "REF", "ipfs://z", salt, false);
        // Spent exactly the creation fee; the rest refunded.
        assertEq(before - launcher.balance, CREATION_FEE, "only the creation fee was spent");
    }

    function test_CreateV4_InsufficientFee_Reverts() public {
        (bytes32 salt,) = _mine("Low", "LOW", address(0));
        vm.deal(launcher, 1 ether);
        vm.prank(launcher);
        vm.expectRevert(CoilLaunchpad.InsufficientCreationFee.selector);
        pad.createTokenV4{value: CREATION_FEE - 1}("Low", "LOW", "ipfs://q", salt, false);
    }

    function test_CreateV4_WrongSalt_Reverts() public {
        // A salt that does not land on a flag-valid address → the hook's own permission check
        // reverts, so the whole launch reverts (fails safely).
        vm.deal(launcher, 1 ether);
        vm.prank(launcher);
        vm.expectRevert();
        pad.createTokenV4{value: CREATION_FEE}("Bad", "BAD", "ipfs://b", bytes32(uint256(1)), false);
    }

    function _market(uint256 i) internal view returns (CoilLaunchpad.Market memory m) {
        (
            address token,
            address creator,
            bool creatorRewards,
            string memory name,
            string memory symbol,
            string memory metadataURI,
            uint256 createdAt
        ) = pad.markets(i);
        m = CoilLaunchpad.Market(token, creator, creatorRewards, name, symbol, metadataURI, createdAt);
    }

    receive() external payable {}
}
