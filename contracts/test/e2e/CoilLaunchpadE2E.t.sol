// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PosmTestSetup} from "@uniswap/v4-periphery/test/shared/PosmTestSetup.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {CoilHook} from "../../src/CoilHook.sol";
import {CoilLaunchpad} from "../../src/CoilLaunchpad.sol";

/// @dev End-to-end proof of the CoilLaunchpad (Phase B) against a live local v4 stack: the factory
///   deploys a CoilHook at a mined CREATE2 address, seeds a REAL pool through the REAL
///   PositionManager, and the resulting token skims a native protocol fee on a REAL swap. This is
///   the definitive test that a launchpad-minted token is immediately tradable and profitable.
contract CoilLaunchpadE2ETest is PosmTestSetup {
    CoilLaunchpad pad;

    int24 constant TICK_LOWER = -6000;
    int24 constant TICK_UPPER = 0;
    uint256 constant SUPPLY = 1_000_000 ether;
    uint256 constant CREATION_FEE = 0.01 ether;
    uint256 constant P_BPS = 50;
    uint256 constant H_BPS = 30;
    uint256 constant B_BPS = 20;
    uint256 constant TOTAL_BPS = 100;
    uint160 constant FLAGS = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);

    address protocolWallet = makeAddr("protocolWallet");
    address treasury = makeAddr("treasury");
    address launcher = makeAddr("launcher");
    address alice = makeAddr("alice");

    function setUp() public {
        deployFreshManagerAndRouters();
        deployPosm(manager);

        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(TICK_UPPER);
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(TICK_LOWER);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(sqrtLower, sqrtUpper, SUPPLY);

        pad = new CoilLaunchpad(
            address(this),
            IPoolManager(address(manager)),
            address(lpm),
            address(permit2),
            protocolWallet,
            treasury,
            CREATION_FEE,
            SUPPLY,
            CoilHook.FeeConfig({protocolBps: P_BPS, holderBps: H_BPS, burnBps: B_BPS}),
            CoilLaunchpad.LaunchConfig({
                tickLower: TICK_LOWER, tickUpper: TICK_UPPER, sqrtPriceX96: sqrtUpper, liquidity: liquidity
            })
        );
    }

    function _mine(string memory name, string memory symbol, address creator)
        internal
        view
        returns (bytes32 salt)
    {
        bytes memory args = abi.encode(
            IPoolManager(address(manager)),
            address(pad),
            address(lpm),
            address(permit2),
            protocolWallet,
            treasury,
            creator,
            SUPPLY,
            name,
            symbol,
            CoilHook.FeeConfig({protocolBps: P_BPS, holderBps: H_BPS, burnBps: B_BPS})
        );
        (, salt) = HookMiner.find(address(pad), FLAGS, type(CoilHook).creationCode, args);
    }

    function _launch(string memory name, string memory symbol, bool creatorRewards)
        internal
        returns (CoilHook coil)
    {
        address creator = creatorRewards ? launcher : address(0);
        bytes32 salt = _mine(name, symbol, creator);
        vm.deal(launcher, 1 ether);
        vm.prank(launcher);
        (address token,) = pad.createTokenV4{value: CREATION_FEE}(name, symbol, "ipfs://x", salt, creatorRewards);
        coil = CoilHook(payable(token));
    }

    function _key(CoilHook coil) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(coil)),
            fee: coil.POOL_FEE(),
            tickSpacing: coil.TICK_SPACING(),
            hooks: IHooks(address(coil))
        });
    }

    function _buy(CoilHook coil, address who, uint256 ethIn) internal {
        PoolKey memory key = _key(coil);
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        vm.deal(who, ethIn);
        vm.prank(who);
        swapRouter.swap{value: ethIn}(key, params, settings, "");
    }

    /// @dev Launch through the factory, then trade the minted token — the fee must land.
    function test_Launch_Then_Trade_TakesFee() public {
        uint256 protoFeeBefore = protocolWallet.balance;
        CoilHook coil = _launch("Snek", "SNEK", false);

        // Seeded on the real PoolManager, ownership renounced, creation fee paid.
        assertTrue(coil.seeded());
        assertEq(coil.owner(), address(0));
        assertEq(coil.totalSupply(), SUPPLY);
        assertEq(protocolWallet.balance - protoFeeBefore, CREATION_FEE, "creation fee paid");

        // A real buy skims the native protocol fee.
        _buy(coil, alice, 5 ether);
        uint256 feeTotal = 5 ether * TOTAL_BPS / 10_000;
        assertEq(coil.protocolAccruedETH(), feeTotal * P_BPS / TOTAL_BPS, "protocol fee taken on buy");
        assertGt(coil.balanceOf(alice), 0, "alice received tokens");

        // Sweep the protocol cut to the wallet.
        uint256 before = protocolWallet.balance;
        coil.sweepProtocol();
        assertEq(protocolWallet.balance - before, feeTotal * P_BPS / TOTAL_BPS, "protocol cut swept");
    }

    /// @dev Creator-Rewards launch: the holder slice is booked to the launcher's creator bucket.
    function test_Launch_CreatorRewards() public {
        CoilHook coil = _launch("Coily", "COILY", true);
        assertEq(coil.creator(), launcher);

        _buy(coil, alice, 4 ether); // alice holds, but holder slice goes to the creator bucket
        assertGt(coil.creatorAccruedETH(), 0, "creator earns the holder slice");
        assertEq(coil.accPerShareETH(), 0, "no holder dividend accumulation in creator mode");

        uint256 before = launcher.balance;
        coil.sweepCreator();
        assertGt(launcher.balance, before, "creator swept their cut");
    }
}
