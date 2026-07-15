// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {CoilHook} from "../src/CoilHook.sol";
import {MockPoolManager, MockPermit2, MockPosm} from "./mocks/MockV4.sol";

/// @dev Test-only subclass exposing the internal fee split so the accumulator maths can be
///   exercised against v4 mocks (no live PoolManager). The genuine swap → beforeSwap → take →
///   split path is covered by test/e2e (native solc, real PoolManager + real swaps).
contract CoilHookHarness is CoilHook {
    constructor(
        IPoolManager pm,
        address owner_,
        address posm_,
        address permit2_,
        address feeRecipient_,
        address treasury_,
        address creator_,
        uint256 supply_,
        string memory name_,
        string memory symbol_,
        FeeConfig memory fees_
    ) CoilHook(pm, owner_, posm_, permit2_, feeRecipient_, treasury_, creator_, supply_, name_, symbol_, fees_) {}

    /// @dev Simulate a swap fee already taken into the hook: for ETH, `vm.deal` the hook first;
    ///   for the token, the hook already custodies SUPPLY. Then split it exactly as `_beforeSwap`
    ///   would after `poolManager.take`.
    function harnessDistribute(bool isEth, uint256 feeTotal) external {
        _distribute(isEth, feeTotal);
    }
}

/// @dev Logic-level coverage of the CoilHook fee engine: the fixed protocol/holders/burn
///   waterfall, the balance-keyed dividend accumulator, per-holder claim, and the permissionless
///   protocol/treasury sweeps.
contract CoilHookUnitTest is Test {
    CoilHookHarness hook;
    MockPoolManager pm;
    MockPosm posm;
    MockPermit2 permit2;

    // Low 14 bits must encode BEFORE_SWAP (bit 7) + BEFORE_SWAP_RETURNS_DELTA (bit 3) = 0x88.
    address constant HOOK_ADDR = address(uint160(0xCAfE000000000000000000000000000000000088));

    address protocolWallet = makeAddr("protocolWallet"); // feeRecipient (protocol wallet)
    address treasury = makeAddr("treasury"); // COIL buy&burn
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    uint256 constant SUPPLY = 1_000_000 ether;
    // 0.50% / 0.30% / 0.20% → 1% total, the split the user chose.
    uint256 constant P_BPS = 50;
    uint256 constant H_BPS = 30;
    uint256 constant B_BPS = 20;

    function setUp() public {
        pm = new MockPoolManager();
        posm = new MockPosm();
        permit2 = new MockPermit2();

        CoilHook.FeeConfig memory fees = CoilHook.FeeConfig({protocolBps: P_BPS, holderBps: H_BPS, burnBps: B_BPS});
        deployCodeTo(
            "CoilHookUnit.t.sol:CoilHookHarness",
            abi.encode(
                IPoolManager(address(pm)),
                address(this),
                address(posm),
                address(permit2),
                protocolWallet,
                treasury,
                address(0), // Loop Rewards (holder slice → accumulator)
                SUPPLY,
                "Coil Token",
                "COIL-T",
                fees
            ),
            HOOK_ADDR
        );
        hook = CoilHookHarness(payable(HOOK_ADDR));
    }

    /// @dev Hand `who` `amount` of the token from the hook's treasury (the same excluded→holder
    ///   path a real buy takes: circulating rises, `who` becomes an eligible holder).
    function _fund(address who, uint256 amount) internal {
        vm.prank(address(hook));
        hook.transfer(who, amount);
    }

    /*                         BASICS                          */

    function test_Metadata() public view {
        assertEq(hook.name(), "Coil Token");
        assertEq(hook.symbol(), "COIL-T");
        assertEq(hook.SUPPLY(), SUPPLY);
        assertEq(hook.totalSupply(), SUPPLY);
        assertEq(hook.balanceOf(address(hook)), SUPPLY);
        assertEq(hook.POOL_FEE(), 0, "pool LP fee is 0 - all capture via the hook");
    }

    function test_HookPermissions_BeforeSwapReturnsDelta() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeSwap);
        assertTrue(p.beforeSwapReturnDelta);
        assertFalse(p.afterSwap);
        assertFalse(p.afterInitialize);
    }

    function test_FeeConfig_Fixed() public view {
        assertEq(hook.PROTOCOL_FEE_BPS(), P_BPS);
        assertEq(hook.HOLDER_FEE_BPS(), H_BPS);
        assertEq(hook.BURN_FEE_BPS(), B_BPS);
        assertEq(hook.TOTAL_FEE_BPS(), P_BPS + H_BPS + B_BPS);
        assertEq(hook.feeRecipient(), protocolWallet);
        assertEq(hook.platformTreasury(), treasury);
    }

    /*                    CONSTRUCTOR GUARDS                   */

    // A second valid-flags address so the constructor clears the address-flag check and we can
    // observe the fee-config guard itself (0x88 in the low 14 bits, like HOOK_ADDR).
    address constant HOOK_ADDR2 = address(uint160(0xBEef000000000000000000000000000000000088));

    function _deployWithFees(CoilHook.FeeConfig memory fees) internal {
        deployCodeTo(
            "CoilHookUnit.t.sol:CoilHookHarness",
            abi.encode(
                IPoolManager(address(pm)), address(this), address(posm), address(permit2),
                protocolWallet, treasury, address(0), SUPPLY, "x", "x", fees
            ),
            HOOK_ADDR2
        );
    }

    function test_Constructor_RejectsZeroFee() public {
        CoilHook.FeeConfig memory zero = CoilHook.FeeConfig({protocolBps: 0, holderBps: 0, burnBps: 0});
        vm.expectRevert(CoilHook.InvalidFeeConfig.selector);
        _deployWithFees(zero);
    }

    function test_Constructor_RejectsPredatoryFee() public {
        // 6% > MAX_TOTAL_FEE_BPS (5%)
        CoilHook.FeeConfig memory big = CoilHook.FeeConfig({protocolBps: 600, holderBps: 0, burnBps: 0});
        vm.expectRevert(CoilHook.InvalidFeeConfig.selector);
        _deployWithFees(big);
    }

    /*                    FEE WATERFALL                        */

    function test_Split_ProtocolHoldersBurn() public {
        _fund(alice, 100_000 ether); // sole holder → gets 100% of the holder cut
        assertEq(hook.circulating(), 100_000 ether);

        // Simulate a token-side fee (a sell): 1000 tokens skimmed into the hook.
        uint256 fee = 1000 ether;
        hook.harnessDistribute(false, fee);

        // 0.50/0.30/0.20 of the 1% pot → half protocol, ~a third holders, a fifth burn.
        assertEq(hook.protocolAccruedTOKEN(), fee * P_BPS / (P_BPS + H_BPS + B_BPS), "protocol cut");
        assertEq(hook.treasuryAccruedTOKEN(), fee * B_BPS / (P_BPS + H_BPS + B_BPS), "burn cut");

        (, uint256 owedTok) = hook.pendingOf(alice);
        assertApproxEqAbs(owedTok, fee * H_BPS / (P_BPS + H_BPS + B_BPS), 1e6, "holder cut");
    }

    function test_Split_EthSide() public {
        _fund(alice, 100_000 ether);
        uint256 fee = 10 ether;
        vm.deal(address(hook), fee); // ETH the pool would have handed over on a buy
        hook.harnessDistribute(true, fee);

        assertEq(hook.protocolAccruedETH(), fee * P_BPS / (P_BPS + H_BPS + B_BPS));
        assertEq(hook.treasuryAccruedETH(), fee * B_BPS / (P_BPS + H_BPS + B_BPS));
        (uint256 owedEth,) = hook.pendingOf(alice);
        assertApproxEqAbs(owedEth, fee * H_BPS / (P_BPS + H_BPS + B_BPS), 1e6);
    }

    function test_Holders_SplitProRata() public {
        _fund(alice, 30_000 ether); // 75%
        _fund(bob, 10_000 ether); //   25%
        assertEq(hook.circulating(), 40_000 ether);

        uint256 fee = 4000 ether;
        hook.harnessDistribute(false, fee);
        uint256 holderPot = fee * H_BPS / (P_BPS + H_BPS + B_BPS);

        (, uint256 aOwed) = hook.pendingOf(alice);
        (, uint256 bOwed) = hook.pendingOf(bob);
        assertApproxEqAbs(aOwed, holderPot * 3 / 4, 1e6, "alice 75%");
        assertApproxEqAbs(bOwed, holderPot * 1 / 4, 1e6, "bob 25%");
    }

    function test_Holders_LateBuyerDoesNotSharePastFees() public {
        _fund(alice, 10_000 ether);
        hook.harnessDistribute(false, 1000 ether); // only alice is a holder here

        _fund(bob, 10_000 ether); // bob arrives AFTER the fee
        (, uint256 bOwed) = hook.pendingOf(bob);
        assertEq(bOwed, 0, "late holder owes nothing for past fees");

        // A second fee is now split between the two equal holders.
        hook.harnessDistribute(false, 1000 ether);
        (, uint256 bOwed2) = hook.pendingOf(bob);
        uint256 holderPot = (1000 ether) * H_BPS / (P_BPS + H_BPS + B_BPS);
        assertApproxEqAbs(bOwed2, holderPot / 2, 1e6, "bob shares only the second fee");
    }

    function test_FirstBuyRoutesHolderCutToTreasury() public {
        // No holders yet (circulating == 0) → the holder slice falls back to the treasury.
        assertEq(hook.circulating(), 0);
        uint256 fee = 1000 ether;
        hook.harnessDistribute(false, fee);

        uint256 protocolCut = fee * P_BPS / (P_BPS + H_BPS + B_BPS);
        uint256 burnCut = fee * B_BPS / (P_BPS + H_BPS + B_BPS);
        uint256 holderCut = fee - protocolCut - burnCut;
        assertEq(hook.protocolAccruedTOKEN(), protocolCut);
        assertEq(hook.treasuryAccruedTOKEN(), burnCut + holderCut, "holder cut redirected to treasury");
        assertEq(hook.accPerShareTOKEN(), 0);
    }

    /*                    CLAIM / SWEEP                        */

    function test_Claim_PaysAndResets() public {
        _fund(alice, 50_000 ether);
        vm.deal(address(hook), 5 ether);
        hook.harnessDistribute(true, 5 ether); // ETH dividends
        hook.harnessDistribute(false, 5000 ether); // token dividends

        (uint256 owedEth, uint256 owedTok) = hook.pendingOf(alice);
        assertGt(owedEth, 0);
        assertGt(owedTok, 0);

        uint256 ethBefore = alice.balance;
        uint256 tokBefore = hook.balanceOf(alice);
        vm.prank(alice);
        hook.claim();
        assertApproxEqAbs(alice.balance - ethBefore, owedEth, 1e6);
        assertApproxEqAbs(hook.balanceOf(alice) - tokBefore, owedTok, 1e6);

        (uint256 afterEth, uint256 afterTok) = hook.pendingOf(alice);
        assertEq(afterEth, 0);
        assertEq(afterTok, 0);
    }

    function test_SweepProtocol_ToRecipient_Permissionless() public {
        _fund(alice, 10_000 ether);
        vm.deal(address(hook), 2 ether);
        hook.harnessDistribute(true, 2 ether);
        hook.harnessDistribute(false, 2000 ether);

        uint256 accruedEth = hook.protocolAccruedETH();
        uint256 accruedTok = hook.protocolAccruedTOKEN();
        assertGt(accruedEth, 0);
        assertGt(accruedTok, 0);

        uint256 ethBefore = protocolWallet.balance;
        uint256 tokBefore = hook.balanceOf(protocolWallet);
        // Anyone can trigger; funds can only go to the fixed feeRecipient.
        vm.prank(carol);
        hook.sweepProtocol();
        assertEq(protocolWallet.balance - ethBefore, accruedEth);
        assertEq(hook.balanceOf(protocolWallet) - tokBefore, accruedTok);
        assertEq(hook.protocolAccruedETH(), 0);
        assertEq(hook.protocolAccruedTOKEN(), 0);
    }

    function test_SweepTreasury_ToTreasury() public {
        _fund(alice, 10_000 ether);
        vm.deal(address(hook), 3 ether);
        hook.harnessDistribute(true, 3 ether);

        uint256 accrued = hook.treasuryAccruedETH();
        assertGt(accrued, 0);
        uint256 before = treasury.balance;
        hook.sweepTreasury();
        assertEq(treasury.balance - before, accrued);
        assertEq(hook.treasuryAccruedETH(), 0);
    }

    /*                    CREATOR REWARDS MODE                */

    address creatorWallet = makeAddr("creatorWallet");

    /// @dev Deploy a Creator-Rewards harness (creator != 0) at the second flag-valid address.
    function _deployCreatorMode() internal returns (CoilHookHarness h) {
        CoilHook.FeeConfig memory fees =
            CoilHook.FeeConfig({protocolBps: P_BPS, holderBps: H_BPS, burnBps: B_BPS});
        deployCodeTo(
            "CoilHookUnit.t.sol:CoilHookHarness",
            abi.encode(
                IPoolManager(address(pm)), address(this), address(posm), address(permit2),
                protocolWallet, treasury, creatorWallet, SUPPLY, "Coil Token", "COIL-T", fees
            ),
            HOOK_ADDR2
        );
        h = CoilHookHarness(payable(HOOK_ADDR2));
    }

    function test_CreatorRewards_HolderSliceGoesToCreator() public {
        CoilHookHarness h = _deployCreatorMode();
        assertEq(h.creator(), creatorWallet);
        assertTrue(h.isExcluded(creatorWallet), "creator excluded from dividends");

        // Give a real holder some tokens, then skim a token-side fee.
        vm.prank(address(h));
        h.transfer(alice, 100_000 ether);
        uint256 fee = 1000 ether;
        h.harnessDistribute(false, fee);

        uint256 pot = P_BPS + H_BPS + B_BPS;
        // Holder slice is redirected to the creator bucket; the accumulator never moves, so the
        // real holder earns nothing from the holder slice.
        assertEq(h.creatorAccruedTOKEN(), fee * H_BPS / pot, "holder slice -> creator");
        assertEq(h.accPerShareTOKEN(), 0, "no dividend accumulation in creator mode");
        (, uint256 aliceOwed) = h.pendingOf(alice);
        assertEq(aliceOwed, 0, "holders earn nothing from the holder slice in creator mode");

        // Creator sweeps their cut.
        uint256 before = h.balanceOf(creatorWallet);
        h.sweepCreator();
        assertEq(h.balanceOf(creatorWallet) - before, fee * H_BPS / pot, "creator swept the slice");
        assertEq(h.creatorAccruedTOKEN(), 0);
    }

    /*                    ACCOUNTING INVARIANT                 */

    function test_Invariant_CirculatingTracksHolders() public {
        _fund(alice, 20_000 ether);
        _fund(bob, 5_000 ether);
        vm.prank(alice);
        hook.transfer(carol, 4_000 ether);
        // Excluded addresses (hook, pool, protocolWallet, treasury) never count; the three EOAs do.
        assertEq(
            hook.circulating(),
            hook.balanceOf(alice) + hook.balanceOf(bob) + hook.balanceOf(carol)
        );
    }

    function testFuzz_NoDividendDust_ExceedsPot(uint256 a, uint256 b, uint256 fee) public {
        a = bound(a, 1 ether, 100_000 ether);
        b = bound(b, 1 ether, 100_000 ether);
        fee = bound(fee, 1 ether, 10_000 ether);
        _fund(alice, a);
        _fund(bob, b);
        hook.harnessDistribute(false, fee);
        // The contract gives holders the REMAINDER (fee - protocol - burn), so rounding dust
        // lands with holders, not lost. The sum of holder claims never exceeds that remainder.
        uint256 pot = P_BPS + H_BPS + B_BPS;
        uint256 holderPot = fee - (fee * P_BPS / pot) - (fee * B_BPS / pot);
        (, uint256 aOwed) = hook.pendingOf(alice);
        (, uint256 bOwed) = hook.pendingOf(bob);
        // Per-share accumulator rounding only ever leaves dust in the hook; holders never
        // over-draw the holder pot.
        assertLe(aOwed + bOwed, holderPot);
    }

    receive() external payable {}
}
