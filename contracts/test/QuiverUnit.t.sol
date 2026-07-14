// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {QuiverHook} from "../src/QuiverHook.sol";
import {QuiverMirror} from "../src/QuiverMirror.sol";
import {MockPoolManager, MockPermit2, MockPosm} from "./mocks/MockV4.sol";

/// @dev Logic-level coverage of the Quiver hook against lightweight v4 mocks: ERC20↔NFT
///   realignment, the MasterChef-style fee accumulator, the ERC-721 mirror, and on-chain art.
///   The genuine pool/swap path is covered by test/e2e (native solc, real PoolManager).
contract QuiverUnitTest is Test {
    QuiverHook hook;
    QuiverMirror mirror;
    MockPoolManager pm;
    MockPosm posm;
    MockPermit2 permit2;

    // Address whose low 14 bits encode exactly AFTER_SWAP_FLAG (bit 6), all others clear.
    address constant HOOK_ADDR = address(uint160(0xCAfe000000000000000000000000000000000040));

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public {
        pm = new MockPoolManager();
        posm = new MockPosm();
        permit2 = new MockPermit2();

        deployCodeTo(
            "QuiverHook.sol:QuiverHook",
            abi.encode(IPoolManager(address(pm)), address(this), address(posm), address(permit2)),
            HOOK_ADDR
        );
        hook = QuiverHook(payable(HOOK_ADDR));
        mirror = hook.mirror();
        posm.setToken(address(hook));

        // In the mocked world `seed()` performs no real liquidity mint, so the whole supply
        // stays in the hook and we hand it out by pranking the hook — this exercises exactly
        // the same _afterTokenTransfer realignment path a real buy would.
        hook.seed(0, -6000, 0, 0);
    }

    /// @dev Give `who` `amount` QUIVER from the hook's treasury (mints arrows via realignment).
    function _fund(address who, uint256 amount) internal {
        vm.prank(address(hook));
        hook.transfer(who, amount);
    }

    /*                         BASICS                          */

    function test_Metadata() public view {
        assertEq(hook.name(), "Quiver");
        assertEq(hook.symbol(), "QUIVER");
        assertEq(hook.SUPPLY(), 4663 ether);
        assertEq(hook.totalSupply(), 4663 ether);
        assertEq(mirror.name(), "Quiver-LP");
        assertEq(mirror.symbol(), "QUIVER-LP");
    }

    function test_HookPermissions_OnlyAfterSwap() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.afterSwap);
        assertFalse(p.beforeSwap);
        assertFalse(p.afterInitialize);
    }

    function test_Seed_RenouncesOwnership() public view {
        assertTrue(hook.seeded());
        assertEq(hook.owner(), address(0));
    }

    function test_Seed_Twice_Reverts() public {
        vm.expectRevert(); // ownership renounced → onlyOwner reverts
        hook.seed(0, -6000, 0, 0);
    }

    /*                    ERC20 ↔ NFT SYNC                     */

    function test_Fund_MintsArrows() public {
        _fund(alice, 5 ether);
        assertEq(hook.nftBalanceOf(alice), 5);
        assertEq(hook.totalShares(), 5);
        uint256[] memory ids = hook.ownedTokensOf(alice);
        assertEq(ids.length, 5);
        for (uint256 i = 0; i < ids.length; i++) {
            assertEq(mirror.ownerOf(ids[i]), alice);
        }
    }

    function test_FractionalHolding_NoArrow() public {
        _fund(alice, 2_500_000_000_000_000_000); // 2.5 tokens → 2 arrows
        assertEq(hook.nftBalanceOf(alice), 2);
    }

    function test_PartialSell_BurnsArrow() public {
        _fund(alice, 5 ether);
        // send 1.5 tokens away → alice drops to 3 whole → loses 2 arrows
        vm.prank(alice);
        hook.transfer(bob, 1_500_000_000_000_000_000);
        assertEq(hook.nftBalanceOf(alice), 3);
        assertEq(hook.nftBalanceOf(bob), 1);
        assertEq(hook.totalShares(), 4);
    }

    function test_WholeTransfer_MovesArrows() public {
        _fund(alice, 5 ether);
        vm.prank(alice);
        hook.transfer(bob, 2 ether);
        assertEq(hook.nftBalanceOf(alice), 3);
        assertEq(hook.nftBalanceOf(bob), 2);
        assertEq(hook.totalShares(), 5);
    }

    function test_Burn_IsPermanent_SupplyCeiling() public {
        _fund(alice, 10 ether);
        assertEq(hook.totalShares(), 10);
        // fractional churn destroys arrows for good
        vm.prank(alice);
        hook.transfer(bob, 500_000_000_000_000_000); // 0.5 → alice 9 whole, one arrow burned
        assertEq(hook.totalShares(), 9);
        assertEq(hook.nftBalanceOf(alice), 9);
        assertEq(hook.nftBalanceOf(bob), 0); // 0.5 tokens, no whole
    }

    /*                    FEE DISTRIBUTION                     */

    function _harvest(uint256 ethAmt, uint256 tokenAmt) internal {
        vm.deal(address(posm), address(posm).balance + ethAmt);
        if (tokenAmt > 0) _fund(address(posm), tokenAmt); // give posm QUIVER to forward as fees
        posm.setFees(ethAmt, tokenAmt);
        hook.pokeFees();
    }

    function test_Fees_SplitProRata() public {
        _fund(alice, 3 ether); // 3 arrows
        _fund(bob, 1 ether); // 1 arrow
        assertEq(hook.totalShares(), 4);

        _harvest(4 ether, 0); // 4 ETH across 4 shares → 1 ETH each

        uint256[] memory aIds = hook.ownedTokensOf(alice);
        uint256[] memory bIds = hook.ownedTokensOf(bob);
        (uint256 aOwed,) = hook.pendingFees(aIds[0]);
        (uint256 bOwed,) = hook.pendingFees(bIds[0]);
        assertApproxEqAbs(aOwed, 1 ether, 1e6);
        assertApproxEqAbs(bOwed, 1 ether, 1e6);

        uint256 balBefore = alice.balance;
        vm.prank(alice);
        hook.claim(aIds[0]);
        assertApproxEqAbs(alice.balance - balBefore, 1 ether, 1e6);

        (uint256 aAfter,) = hook.pendingFees(aIds[0]);
        assertEq(aAfter, 0);
    }

    function test_Fees_TokenSide() public {
        _fund(alice, 2 ether);
        uint256[] memory ids = hook.ownedTokensOf(alice);
        _harvest(0, 2 ether); // 2 QUIVER across 2 shares → 1 each

        (, uint256 owedTok) = hook.pendingFees(ids[0]);
        assertApproxEqAbs(owedTok, 1 ether, 1e6);

        uint256 tokBefore = hook.balanceOf(alice);
        vm.prank(alice);
        hook.claim(ids[0]);
        assertApproxEqAbs(hook.balanceOf(alice) - tokBefore, 1 ether, 1e6);
    }

    function test_Fees_NewArrowDoesNotDilutePast() public {
        _fund(alice, 1 ether); // 1 arrow
        uint256 aId = hook.ownedTokensOf(alice)[0];
        _harvest(1 ether, 0); // alice's single arrow owed ~1 ETH

        _fund(bob, 1 ether); // bob's arrow enters AFTER the harvest
        uint256 bId = hook.ownedTokensOf(bob)[0];

        (uint256 aOwed,) = hook.pendingFees(aId);
        (uint256 bOwed,) = hook.pendingFees(bId);
        assertApproxEqAbs(aOwed, 1 ether, 1e6);
        assertEq(bOwed, 0, "late arrow owes nothing for past fees");
    }

    function test_Burn_CreditsPendingBeforeLoss() public {
        _fund(alice, 2 ether); // 2 arrows
        _harvest(2 ether, 0); // ~1 ETH owed per arrow

        // Sell a fraction so one arrow burns; its accrued fee must survive as pending.
        vm.prank(alice);
        hook.transfer(bob, 500_000_000_000_000_000); // 0.5 → alice 1 whole, one arrow burned
        assertEq(hook.nftBalanceOf(alice), 1);

        uint256 pend = hook.pendingETH(alice);
        assertApproxEqAbs(pend, 1 ether, 1e6);

        uint256 balBefore = alice.balance;
        vm.prank(alice);
        hook.withdrawPending();
        assertApproxEqAbs(alice.balance - balBefore, 1 ether, 1e6);
    }

    /*                    MIRROR / ERC721                      */

    function test_Mirror_TransferMovesTokenAndArrow() public {
        _fund(alice, 4 ether);
        uint256 id = hook.ownedTokensOf(alice)[0];
        uint256 balBefore = hook.balanceOf(alice);
        vm.prank(alice);
        mirror.transferFrom(alice, bob, id);
        assertEq(mirror.ownerOf(id), bob);
        assertEq(hook.balanceOf(alice), balBefore - hook.UNIT());
        assertEq(hook.nftBalanceOf(bob), 1);
    }

    function test_Mirror_SelfTransfer_Reverts() public {
        _fund(alice, 2 ether);
        uint256 id = hook.ownedTokensOf(alice)[0];
        vm.prank(alice);
        vm.expectRevert(QuiverHook.SelfTransferDisallowed.selector);
        mirror.transferFrom(alice, alice, id);
    }

    function test_Mirror_ApproveAndOperator() public {
        _fund(alice, 2 ether);
        uint256 id = hook.ownedTokensOf(alice)[0];

        vm.prank(alice);
        mirror.approve(carol, id);
        assertEq(mirror.getApproved(id), carol);
        vm.prank(carol);
        mirror.transferFrom(alice, bob, id);
        assertEq(mirror.ownerOf(id), bob);

        _fund(alice, 1 ether);
        uint256 id2 = hook.ownedTokensOf(alice)[0];
        vm.prank(alice);
        mirror.setApprovalForAll(carol, true);
        assertTrue(mirror.isApprovedForAll(alice, carol));
        vm.prank(carol);
        mirror.transferFrom(alice, bob, id2);
        assertEq(mirror.ownerOf(id2), bob);
    }

    function test_Mirror_Unauthorized_Reverts() public {
        _fund(alice, 2 ether);
        uint256 id = hook.ownedTokensOf(alice)[0];
        vm.prank(carol);
        vm.expectRevert(QuiverHook.NotOwnerOrApproved.selector);
        mirror.transferFrom(alice, bob, id);
    }

    function test_Mirror_SupportsInterface() public view {
        assertTrue(mirror.supportsInterface(0x01ffc9a7));
        assertTrue(mirror.supportsInterface(0x80ac58cd));
        assertTrue(mirror.supportsInterface(0x5b5e139f));
        assertFalse(mirror.supportsInterface(0xdeadbeef));
    }

    /*                          ART                           */

    function test_Art_TokenURI_Prefix() public {
        _fund(alice, 1 ether);
        uint256 id = hook.ownedTokensOf(alice)[0];
        string memory uri = mirror.tokenURI(id);
        bytes memory u = bytes(uri);
        bytes memory prefix = bytes("data:application/json;base64,");
        assertGt(u.length, prefix.length);
        for (uint256 i = 0; i < prefix.length; i++) {
            assertEq(u[i], prefix[i]);
        }
    }

    function test_Art_SeedDeterministicAndDistinct() public {
        _fund(alice, 1 ether);
        _fund(bob, 1 ether);
        uint256 a = hook.ownedTokensOf(alice)[0];
        uint256 b = hook.ownedTokensOf(bob)[0];
        assertEq(hook.seedOf(a), hook.seedOf(a));
        assertTrue(hook.seedOf(a) != hook.seedOf(b));
    }

    function test_TokenURI_UnknownId_Reverts() public {
        vm.expectRevert(QuiverHook.InvalidTokenId.selector);
        hook.nftTokenURI(123456);
    }

    /*                       INVARIANT                         */

    function testFuzz_SharesEqualLiveArrows(uint256 a, uint256 b, uint256 move) public {
        a = bound(a, 1 ether, 50 ether);
        b = bound(b, 1 ether, 50 ether);
        _fund(alice, a);
        _fund(bob, b);
        move = bound(move, 0, hook.balanceOf(alice));
        vm.prank(alice);
        hook.transfer(carol, move);
        assertEq(
            hook.totalShares(), hook.nftBalanceOf(alice) + hook.nftBalanceOf(bob) + hook.nftBalanceOf(carol)
        );
    }

    receive() external payable {}
}
