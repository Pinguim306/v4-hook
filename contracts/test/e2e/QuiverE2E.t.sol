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

import {QuiverHook} from "../../src/QuiverHook.sol";
import {QuiverMirror} from "../../src/QuiverMirror.sol";

/// @dev End-to-end + unit coverage for the Quiver hook against a live local v4 stack
///   (PoolManager + PositionManager + Permit2 from PosmTestSetup).
contract QuiverE2ETest is PosmTestSetup {
    QuiverHook hook;
    QuiverMirror mirror;

    // Hook must live at an address whose low 14 bits encode exactly AFTER_SWAP_FLAG.
    // cafe...0040 → bit 6 set, all other hook flags clear.
    address constant HOOK_ADDR = address(uint160(0xCAfe000000000000000000000000000000000040));

    int24 constant TICK_LOWER = -6000;
    int24 constant TICK_UPPER = 0; // launch price sits at the upper bound → one-sided token1
    uint160 sqrtPriceX96;
    uint128 seedLiquidity;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public {
        deployFreshManagerAndRouters();
        deployAndApprovePosm(manager);

        // Deploy the hook at the flag-encoded address (constructor validates the bits).
        deployCodeTo(
            "QuiverHook.sol:QuiverHook",
            abi.encode(IPoolManager(address(manager)), address(this), address(lpm), address(permit2)),
            HOOK_ADDR
        );
        hook = QuiverHook(payable(HOOK_ADDR));
        mirror = hook.mirror();

        // Launch price at the upper tick so the whole supply is provided as token1 only.
        sqrtPriceX96 = TickMath.getSqrtPriceAtTick(TICK_UPPER);
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(TICK_LOWER);
        seedLiquidity = LiquidityAmounts.getLiquidityForAmount1(sqrtLower, sqrtPriceX96, hook.SUPPLY());
    }

    function _seed() internal {
        hook.seed(sqrtPriceX96, TICK_LOWER, TICK_UPPER, seedLiquidity);
    }

    function _key() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(hook)),
            fee: hook.POOL_FEE(),
            tickSpacing: hook.TICK_SPACING(),
            hooks: IHooks(address(hook))
        });
    }

    /// @dev Buy `ethIn` worth of QUIVER (swap ETH→token, zeroForOne). Returns to `who`.
    function _buy(address who, uint256 ethIn) internal {
        vm.deal(who, ethIn);
        vm.prank(who);
        swapRouter.swap{value: ethIn}(
            _key(),
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(ethIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /*                         BASICS                          */

    function test_Metadata() public view {
        assertEq(hook.name(), "Quiver");
        assertEq(hook.symbol(), "QUIVER");
        assertEq(hook.SUPPLY(), 4663 ether);
        assertEq(hook.totalSupply(), 4663 ether);
        assertEq(hook.balanceOf(address(hook)), 4663 ether);
        assertEq(mirror.name(), "Quiver-LP");
        assertEq(mirror.symbol(), "QUIVER-LP");
    }

    function test_HookPermissions_OnlyAfterSwap() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.afterSwap);
        assertFalse(p.beforeSwap);
        assertFalse(p.beforeInitialize);
        assertFalse(p.afterInitialize);
    }

    function test_Seed_MintsPositionAndRenounces() public {
        assertEq(hook.owner(), address(this));
        _seed();
        assertTrue(hook.seeded());
        assertGt(hook.hookPositionTokenId(), 0);
        // Fair-launch guarantee: ownership renounced after seeding.
        assertEq(hook.owner(), address(0));
    }

    function test_Seed_Twice_Reverts() public {
        _seed();
        // ownership was renounced, so a second call reverts on the owner check first.
        vm.expectRevert();
        _seed();
    }

    /*                    ERC20 ↔ NFT SYNC                     */

    function test_Buy_MintsArrowsToBuyer() public {
        _seed();
        _buy(alice, 5 ether);

        uint256 whole = hook.balanceOf(alice) / hook.UNIT();
        assertGt(whole, 0, "alice should hold whole tokens");
        assertEq(hook.nftBalanceOf(alice), whole, "arrow count tracks whole-token balance");
        assertEq(hook.totalShares(), whole);

        // owned set is consistent
        uint256[] memory ids = hook.ownedTokensOf(alice);
        assertEq(ids.length, whole);
        for (uint256 i = 0; i < ids.length; i++) {
            assertEq(mirror.ownerOf(ids[i]), alice);
        }
    }

    function test_PartialSell_BurnsArrow() public {
        _seed();
        _buy(alice, 5 ether);
        uint256 wholeBefore = hook.nftBalanceOf(alice);
        assertGt(wholeBefore, 1);

        // Move a fractional amount out → at least one whole token disappears → one arrow burns.
        uint256 sendFrac = hook.balanceOf(alice) - (wholeBefore - 1) * hook.UNIT() + 1;
        vm.prank(alice);
        hook.transfer(bob, sendFrac);

        assertLt(hook.nftBalanceOf(alice), wholeBefore, "alice lost an arrow");
        assertEq(hook.nftBalanceOf(alice), hook.balanceOf(alice) / hook.UNIT());
        assertEq(hook.nftBalanceOf(bob), hook.balanceOf(bob) / hook.UNIT());
        // total shares always equals sum of live arrows
        assertEq(hook.totalShares(), hook.nftBalanceOf(alice) + hook.nftBalanceOf(bob));
    }

    function test_WholeTransfer_MovesArrows() public {
        _seed();
        _buy(alice, 5 ether);
        uint256 aliceWhole = hook.nftBalanceOf(alice);

        vm.prank(alice);
        hook.transfer(bob, 2 ether); // two whole tokens

        assertEq(hook.nftBalanceOf(alice), aliceWhole - 2);
        assertEq(hook.nftBalanceOf(bob), 2);
        assertEq(hook.totalShares(), aliceWhole);
    }

    /*                    FEE DISTRIBUTION                     */

    function test_Fees_AccrueAndClaim() public {
        _seed();
        _buy(alice, 10 ether); // alice becomes a holder with arrows

        uint256[] memory ids = hook.ownedTokensOf(alice);
        assertGt(ids.length, 0);

        // Generate swap fees: bob trades in both directions.
        _buy(bob, 3 ether);
        uint256 bobBal = hook.balanceOf(bob);
        vm.prank(bob);
        hook.approve(address(swapRouter), bobBal);
        // sell part of bob's QUIVER back for ETH to churn fees the other way
        vm.prank(bob);
        swapRouter.swap(
            _key(),
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(bobBal / 2),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        hook.pokeFees();
        (uint256 owedEth, uint256 owedQuiver) = hook.pendingFees(ids[0]);
        assertTrue(owedEth > 0 || owedQuiver > 0, "fees should accrue to an arrow");

        uint256 ethBefore = alice.balance;
        uint256 quiverBefore = hook.balanceOf(alice);
        vm.prank(alice);
        hook.claim(ids[0]);
        assertGe(alice.balance, ethBefore);
        assertGe(hook.balanceOf(alice), quiverBefore);

        // claimed arrow now owes ~nothing until more fees accrue
        (uint256 afterEth, uint256 afterQuiver) = hook.pendingFees(ids[0]);
        assertEq(afterEth, 0);
        assertEq(afterQuiver, 0);
    }

    function test_ClaimMany_SkipsBurned() public {
        _seed();
        _buy(alice, 6 ether);
        uint256[] memory ids = hook.ownedTokensOf(alice);
        _buy(bob, 2 ether);
        hook.pokeFees();

        // Should not revert even if a listed id was burned / not owned.
        uint256[] memory withGhost = new uint256[](ids.length + 1);
        for (uint256 i = 0; i < ids.length; i++) {
            withGhost[i] = ids[i];
        }
        withGhost[ids.length] = 999999; // non-existent
        vm.prank(alice);
        hook.claimMany(withGhost);
    }

    /*                    MIRROR / ERC721                      */

    function test_Mirror_TransferMovesTokenAndArrow() public {
        _seed();
        _buy(alice, 4 ether);
        uint256[] memory ids = hook.ownedTokensOf(alice);
        uint256 id = ids[0];

        uint256 aliceBalBefore = hook.balanceOf(alice);
        vm.prank(alice);
        mirror.transferFrom(alice, bob, id);

        assertEq(mirror.ownerOf(id), bob);
        // exactly one UNIT of the ERC20 followed the arrow
        assertEq(hook.balanceOf(alice), aliceBalBefore - hook.UNIT());
        assertEq(hook.nftBalanceOf(bob), 1);
    }

    function test_Mirror_SelfTransfer_Reverts() public {
        _seed();
        _buy(alice, 3 ether);
        uint256 id = hook.ownedTokensOf(alice)[0];
        vm.prank(alice);
        vm.expectRevert(QuiverHook.SelfTransferDisallowed.selector);
        mirror.transferFrom(alice, alice, id);
    }

    function test_Mirror_ApproveAndTransfer() public {
        _seed();
        _buy(alice, 3 ether);
        uint256 id = hook.ownedTokensOf(alice)[0];

        vm.prank(alice);
        mirror.approve(carol, id);
        assertEq(mirror.getApproved(id), carol);

        vm.prank(carol);
        mirror.transferFrom(alice, bob, id);
        assertEq(mirror.ownerOf(id), bob);
    }

    function test_Mirror_UnauthorizedTransfer_Reverts() public {
        _seed();
        _buy(alice, 3 ether);
        uint256 id = hook.ownedTokensOf(alice)[0];
        vm.prank(carol);
        vm.expectRevert(QuiverHook.NotOwnerOrApproved.selector);
        mirror.transferFrom(alice, bob, id);
    }

    function test_Mirror_SupportsInterface() public view {
        assertTrue(mirror.supportsInterface(0x01ffc9a7)); // ERC165
        assertTrue(mirror.supportsInterface(0x80ac58cd)); // ERC721
        assertTrue(mirror.supportsInterface(0x5b5e139f)); // ERC721Metadata
        assertFalse(mirror.supportsInterface(0xdeadbeef));
    }

    /*                          ART                           */

    function test_Art_TokenURI_IsDataJson() public {
        _seed();
        _buy(alice, 2 ether);
        uint256 id = hook.ownedTokensOf(alice)[0];
        string memory uri = mirror.tokenURI(id);
        assertTrue(bytes(uri).length > 0);
        // starts with data:application/json;base64,
        bytes memory prefix = bytes("data:application/json;base64,");
        bytes memory u = bytes(uri);
        for (uint256 i = 0; i < prefix.length; i++) {
            assertEq(u[i], prefix[i]);
        }
    }

    function test_Art_SeedDeterministic() public {
        _seed();
        _buy(alice, 2 ether);
        uint256 id = hook.ownedTokensOf(alice)[0];
        assertEq(hook.seedOf(id), hook.seedOf(id));
        // different id → different seed (overwhelmingly)
        _buy(bob, 2 ether);
        uint256 idB = hook.ownedTokensOf(bob)[0];
        assertTrue(hook.seedOf(id) != hook.seedOf(idB));
    }

    function test_TokenURI_UnknownId_Reverts() public {
        _seed();
        vm.expectRevert(QuiverHook.InvalidTokenId.selector);
        hook.nftTokenURI(123456);
    }

    /*                       INVARIANTS                        */

    function test_Invariant_SharesEqualArrows_AfterChurn() public {
        _seed();
        _buy(alice, 7 ether);
        _buy(bob, 5 ether);
        vm.prank(alice);
        hook.transfer(carol, 1_500_000_000_000_000_000); // 1.5 tokens
        assertEq(
            hook.totalShares(), hook.nftBalanceOf(alice) + hook.nftBalanceOf(bob) + hook.nftBalanceOf(carol)
        );
    }

    receive() external payable {}
}
