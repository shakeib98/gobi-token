// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/gobitoken.sol";

/// @dev Full test suite for GobiToken (Sablier-derived Category A design).
/// Every test's purpose is documented directly above it.
contract GobiTokenTest is Test {
    GobiToken internal gobi;

    address internal multisig = makeAddr("multisig");
    address internal sablier = makeAddr("sablier");
    address internal minter = makeAddr("minter");
    address internal snapshotter = makeAddr("snapshotter");
    address internal alice = makeAddr("alice"); // genuine vested investor
    address internal bob = makeAddr("bob"); // genuine vested investor
    address internal whale = makeAddr("whale"); // large ordinary holder
    address internal pub1 = makeAddr("pub1");
    address internal pub2 = makeAddr("pub2");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant G = 1e18;
    uint256 internal constant INITIAL = 400_000_000e18;
    uint256 internal constant CAP = 1_200_000_000e18;
    uint256 internal TGE;

    function setUp() public {
        TGE = block.timestamp + 10 days; // inside setTgeTimestamp's valid window
        vm.startPrank(multisig);
        gobi = new GobiToken(multisig, sablier);
        gobi.grantRole(gobi.MINTER_ROLE(), minter);
        gobi.grantRole(gobi.SNAPSHOT_ROLE(), snapshotter);
        gobi.transfer(whale, 10_000 * G); // ordinary public distribution
        vm.stopPrank();
    }

    /// @dev Simulates a Sablier vesting withdrawal: mints into the Sablier
    /// address (stand-in for an already-escrowed stream), then sends from
    /// Sablier to the recipient -- the only path that credits eligibility.
    function _vestFromSablier(address to, uint256 amount) internal {
        vm.prank(minter);
        gobi.mint(sablier, amount);
        vm.prank(sablier);
        gobi.transfer(to, amount);
    }

    function _setTge() internal {
        vm.prank(multisig);
        gobi.setTgeTimestamp(TGE);
        vm.warp(TGE);
    }

    function _expireLockup() internal {
        _setTge();
        vm.warp(TGE + 180 days);
    }

    // =================================================================
    // 1. DEPLOYMENT
    // =================================================================

    /// Confirms name/symbol/decimals are set as expected.
    function test_Deploy_Metadata() public {
        assertEq(gobi.name(), "Gobi Token");
        assertEq(gobi.symbol(), "GOBI");
        assertEq(gobi.decimals(), 18);
    }

    /// Confirms the 400M launch supply mints entirely to the multisig.
    function test_Deploy_InitialSupply() public {
        GobiToken fresh = new GobiToken(multisig, sablier);
        assertEq(fresh.totalSupply(), INITIAL);
        assertEq(fresh.balanceOf(multisig), INITIAL);
    }

    /// Confirms only DEFAULT_ADMIN_ROLE and MINTER_ROLE are auto-granted
    /// at deploy -- SNAPSHOT_ROLE must be granted manually afterward.
    function test_Deploy_OnlyExpectedRolesGranted() public {
        GobiToken fresh = new GobiToken(multisig, sablier);
        assertTrue(fresh.hasRole(fresh.DEFAULT_ADMIN_ROLE(), multisig));
        assertTrue(fresh.hasRole(fresh.MINTER_ROLE(), multisig));
        assertFalse(fresh.hasRole(fresh.SNAPSHOT_ROLE(), multisig));
    }

    /// A zero multisig address must revert -- there'd be no admin at all.
    function test_Deploy_ZeroMultisigReverts() public {
        vm.expectRevert(bytes("Multisig address cannot be zero"));
        new GobiToken(address(0), sablier);
    }

    /// A zero Sablier address must revert -- without it, no wallet could
    /// ever become Category A-eligible, silently breaking compliance.
    function test_Deploy_ZeroSablierReverts() public {
        vm.expectRevert(bytes("Gobi: Sablier address cannot be zero"));
        new GobiToken(multisig, address(0));
    }

    /// Before setTgeTimestamp is ever called, the lock must be ACTIVE
    /// (fail-closed) -- an admin oversight must never leave tokens free.
    function test_Deploy_TgeUnset_LockupActive() public {
        assertEq(gobi.tgeTimestamp(), 0);
        assertTrue(gobi.lockupActive());
    }

    /// categoryATotalSupply starts at zero -- nobody is eligible yet.
    function test_Deploy_CategoryASupplyStartsZero() public {
        assertEq(gobi.categoryATotalSupply(), 0);
    }

    // =================================================================
    // 2. CORE MECHANIC: only Sablier-sourced inflow is ever eligible
    // =================================================================

    /// A genuine Sablier withdrawal credits the recipient's eligible
    /// balance by exactly the amount transferred.
    function test_Sablier_CreditsEligibleBalance() public {
        _vestFromSablier(alice, 100 * G);
        assertEq(gobi.categoryAEligibleBalance(alice), 100 * G);
        assertEq(gobi.categoryATotalSupply(), 100 * G);
        assertTrue(gobi.isCategoryA(alice));
    }

    /// An ordinary transfer (not from Sablier) must NEVER credit eligible
    /// balance, no matter the amount or recipient.
    function test_OrdinaryTransfer_NeverCredits() public {
        vm.prank(whale);
        gobi.transfer(alice, 5000 * G);
        assertEq(gobi.balanceOf(alice), 5000 * G);
        assertEq(gobi.categoryAEligibleBalance(alice), 0);
        assertFalse(gobi.isCategoryA(alice));
    }

    /// Minting must NEVER credit eligible balance -- not to an ordinary
    /// wallet, and not even to Sablier itself (which never forwards
    /// anything from a mint, only from its own outgoing transfers).
    function test_Mint_NeverCreditsEligibleBalance() public {
        vm.prank(minter);
        gobi.mint(alice, 10_000 * G);
        assertEq(gobi.categoryAEligibleBalance(alice), 0);
        vm.prank(minter);
        gobi.mint(sablier, 10_000 * G);
        assertEq(gobi.categoryAEligibleBalance(sablier), 0);
    }

    /// THE key fix under test: a wallet that already holds a huge ordinary
    /// balance, and later genuinely receives a SMALL vesting release, only
    /// has that small release counted -- never its whole pre-existing stack.
    function test_PreFundedWallet_OnlyGenuineVestCounts() public {
        _vestFromSablier(whale, 50 * G);
        assertEq(gobi.balanceOf(whale), 10_050 * G);
        assertEq(gobi.categoryAEligibleBalance(whale), 50 * G);
    }

    /// Repeated Sablier withdrawals (linear vesting releases) accumulate
    /// correctly rather than overwriting each other.
    function test_MultipleSablierWithdrawals_Accumulate() public {
        _vestFromSablier(alice, 40 * G);
        _vestFromSablier(alice, 60 * G);
        assertEq(gobi.categoryAEligibleBalance(alice), 100 * G);
        assertEq(gobi.categoryATotalSupply(), 100 * G);
    }

    /// A wallet holding a MIX of Sablier-sourced and ordinary tokens has
    /// only the Sablier portion counted as eligible -- the rest is real,
    /// spendable balance but never subsidy-eligible.
    function test_MixedBalance_OnlySablierPortionEligible() public {
        _vestFromSablier(alice, 100 * G);
        vm.prank(whale);
        gobi.transfer(alice, 500 * G);
        assertEq(gobi.balanceOf(alice), 600 * G, "full real balance");
        assertEq(gobi.categoryAEligibleBalance(alice), 100 * G, "only the genuine vest");
    }

    // =================================================================
    // 3. THE HARD LOCK
    // =================================================================

    /// While locked, an eligible wallet cannot send to a public wallet,
    /// another eligible wallet, or even itself -- no exceptions.
    function test_Lock_EligibleWallet_CannotSendAnywhere() public {
        _vestFromSablier(alice, 100 * G);
        _vestFromSablier(bob, 50 * G);
        _setTge();
        vm.startPrank(alice);
        vm.expectRevert(bytes("SFA Section 276 Lockup: Category A transfers are locked"));
        gobi.transfer(pub1, 1 * G);
        vm.expectRevert(bytes("SFA Section 276 Lockup: Category A transfers are locked"));
        gobi.transfer(bob, 1 * G);
        vm.expectRevert(bytes("SFA Section 276 Lockup: Category A transfers are locked"));
        gobi.transfer(alice, 1 * G); // self-transfer, still blocked
        vm.stopPrank();
    }

    /// transferFrom (via an approved allowance) is blocked identically to
    /// a direct transfer -- there's no allowance-based bypass.
    function test_Lock_TransferFrom_AlsoBlocked() public {
        _vestFromSablier(alice, 100 * G);
        _setTge();
        vm.prank(alice);
        gobi.approve(pub1, 50 * G);
        vm.prank(pub1);
        vm.expectRevert(bytes("SFA Section 276 Lockup: Category A transfers are locked"));
        gobi.transferFrom(alice, pub1, 50 * G);
    }

    /// Even a zero-amount transfer call from a locked eligible wallet must
    /// revert -- the check does not depend on the amount being moved.
    function test_Lock_ZeroAmountTransfer_StillBlocked() public {
        _vestFromSablier(alice, 100 * G);
        _setTge();
        vm.prank(alice);
        vm.expectRevert(bytes("SFA Section 276 Lockup: Category A transfers are locked"));
        gobi.transfer(pub1, 0);
    }

    /// Fail-closed: the lock is already enforced even before TGE is set.
    function test_Lock_ActiveBeforeTgeIsSet() public {
        _vestFromSablier(alice, 100 * G);
        vm.prank(alice);
        vm.expectRevert(bytes("SFA Section 276 Lockup: Category A transfers are locked"));
        gobi.transfer(pub1, 1 * G);
    }

    /// A wallet holding a MIX of eligible + ordinary tokens is frozen
    /// entirely -- it cannot even send the "free" (non-eligible) portion.
    function test_Lock_MixedBalance_WholeWalletFrozen() public {
        _vestFromSablier(alice, 100 * G);
        vm.prank(whale);
        gobi.transfer(alice, 500 * G);
        _setTge();
        vm.prank(alice);
        vm.expectRevert(bytes("SFA Section 276 Lockup: Category A transfers are locked"));
        gobi.transfer(pub1, 1 * G);
    }

    /// Sablier's OWN outgoing transfers (real vesting withdrawals) must
    /// NEVER be blocked -- otherwise vesting itself would break. This
    /// holds because Sablier's own address never accrues eligible balance.
    function test_Lock_SablierItself_NeverBlocked() public {
        vm.prank(minter);
        gobi.mint(sablier, 1000 * G);
        _setTge();
        vm.prank(sablier);
        gobi.transfer(alice, 1000 * G); // must succeed even while locked
        assertEq(gobi.balanceOf(alice), 1000 * G);
    }

    /// A wallet with zero eligible balance trades completely freely,
    /// regardless of whether the lock-up is active.
    function test_Lock_NonEligibleWallet_TradesFreely() public {
        _setTge();
        vm.prank(whale);
        gobi.transfer(bob, 100 * G);
        assertEq(gobi.balanceOf(bob), 100 * G);
    }

    /// Receiving into an eligible/locked wallet is never blocked -- the
    /// restriction binds senders only, never recipients.
    function test_Lock_ReceivingIntoLockedWallet_Allowed() public {
        _vestFromSablier(alice, 100 * G);
        _setTge();
        vm.prank(whale);
        gobi.transfer(alice, 50 * G);
        assertEq(gobi.balanceOf(alice), 150 * G);
    }

    // =================================================================
    // 4. DEBIT: outgoing transfer/burn draws down eligible balance
    // =================================================================

    /// Burning is exempt from the lock (destroying tokens isn't a resale)
    /// and correctly debits the eligible balance by the burned amount.
    function test_Burn_ExemptFromLock_DebitsEligible() public {
        _vestFromSablier(alice, 100 * G);
        _setTge(); // locked, but burn must still work
        vm.prank(alice);
        gobi.burn(30 * G);
        assertEq(gobi.categoryAEligibleBalance(alice), 70 * G);
        assertEq(gobi.categoryATotalSupply(), 70 * G);
    }

    /// burnFrom (via allowance) is exempt from the lock exactly like a
    /// direct burn, and debits eligible balance the same way.
    function test_BurnFrom_ExemptFromLock_DebitsEligible() public {
        _vestFromSablier(alice, 100 * G);
        _setTge();
        vm.prank(alice);
        gobi.approve(pub1, 50 * G);
        vm.prank(pub1);
        gobi.burnFrom(alice, 50 * G);
        assertEq(gobi.categoryAEligibleBalance(alice), 50 * G);
    }

    /// After the lock expires, a transfer out correctly debits the
    /// sender's eligible balance and does NOT taint the recipient.
    function test_PostExpiry_TransferDebitsSenderOnly() public {
        _vestFromSablier(alice, 100 * G);
        _expireLockup();
        vm.prank(alice);
        gobi.transfer(whale, 40 * G);
        assertEq(gobi.categoryAEligibleBalance(alice), 60 * G, "sender debited");
        assertEq(gobi.categoryAEligibleBalance(whale), 0, "recipient never gains eligibility");
    }

    /// Sending MORE than the eligible balance floors the debit at zero --
    /// it never underflows or reverts because of the eligible tracking.
    function test_DebitFloorsAtZero_NeverUnderflows() public {
        _vestFromSablier(alice, 100 * G);
        vm.prank(whale);
        gobi.transfer(alice, 500 * G); // alice now has 500 ordinary + 100 eligible
        _expireLockup();
        vm.prank(alice);
        gobi.transfer(bob, 300 * G); // more than her 100 eligible
        assertEq(gobi.categoryAEligibleBalance(alice), 0, "floored, not reverted or negative");
        assertEq(gobi.balanceOf(alice), 300 * G, "real balance still correct");
    }

    /// Sending LESS than the eligible balance debits exactly that amount,
    /// leaving the remainder still eligible.
    function test_PartialDebit_LeavesRemainderEligible() public {
        _vestFromSablier(alice, 100 * G);
        _expireLockup();
        vm.prank(alice);
        gobi.transfer(bob, 30 * G);
        assertEq(gobi.categoryAEligibleBalance(alice), 70 * G);
    }

    // =================================================================
    // 5. EXPIRY
    // =================================================================

    /// Once expired, a previously-locked eligible wallet can transfer
    /// freely to anyone.
    function test_Expiry_TradesFreely() public {
        _vestFromSablier(alice, 100 * G);
        _expireLockup();
        vm.prank(alice);
        gobi.transfer(pub1, 100 * G);
        assertEq(gobi.balanceOf(pub1), 100 * G);
    }

    /// Boundary: one second before expiry, still locked.
    function test_Expiry_OneSecondBefore_StillLocked() public {
        _vestFromSablier(alice, 100 * G);
        _setTge();
        vm.warp(TGE + 180 days - 1);
        vm.prank(alice);
        vm.expectRevert(bytes("SFA Section 276 Lockup: Category A transfers are locked"));
        gobi.transfer(pub1, 1 * G);
    }

    /// Boundary: at exactly the expiry instant, no longer locked.
    function test_Expiry_ExactBoundary_Unlocked() public {
        _vestFromSablier(alice, 100 * G);
        _setTge();
        vm.warp(TGE + 180 days);
        assertFalse(gobi.lockupActive());
        vm.prank(alice);
        gobi.transfer(pub1, 1 * G); // must succeed
    }

    // =================================================================
    // 6. HISTORICAL CHECKPOINTING
    // =================================================================

    /// A snapshot's recorded eligible balance is frozen -- later spending
    /// (after expiry) never changes what an earlier snapshot reports.
    function test_History_FrozenAtSnapshot() public {
        _vestFromSablier(alice, 100 * G);
        vm.prank(snapshotter);
        uint256 s1 = gobi.snapshot();

        _expireLockup();
        vm.prank(alice);
        gobi.transfer(pub1, 100 * G); // spends it all AFTER the snapshot

        assertEq(gobi.categoryABalanceAt(alice, s1), 100 * G, "historical value unaffected");
        assertEq(gobi.categoryAEligibleBalance(alice), 0, "live value correctly updated");
    }

    /// Multiple snapshots each correctly capture the total eligible supply
    /// as it stood at that moment, independent of each other.
    function test_History_MultipleSnapshotsIndependent() public {
        vm.prank(snapshotter);
        uint256 s1 = gobi.snapshot(); // 0 eligible

        _vestFromSablier(alice, 100 * G);
        vm.prank(snapshotter);
        uint256 s2 = gobi.snapshot(); // 100 eligible

        _vestFromSablier(bob, 50 * G);
        vm.prank(snapshotter);
        uint256 s3 = gobi.snapshot(); // 150 eligible

        assertEq(gobi.categoryATotalSupplyAt(s1), 0);
        assertEq(gobi.categoryATotalSupplyAt(s2), 100 * G);
        assertEq(gobi.categoryATotalSupplyAt(s3), 150 * G);
    }

    /// If a wallet's eligible balance never changes after a snapshot, a
    /// later query correctly falls through to the live (unchanged) value.
    function test_History_UnchangedValue_FallsThroughToLive() public {
        _vestFromSablier(alice, 100 * G);
        vm.prank(snapshotter);
        uint256 s1 = gobi.snapshot();
        assertEq(gobi.categoryABalanceAt(alice, s1), 100 * G);
        assertEq(gobi.categoryAEligibleBalance(alice), 100 * G);
    }

    /// Invariant: summing categoryABalanceAt over every wallet at a given
    /// snapshot must equal categoryATotalSupplyAt for that same snapshot.
    function test_History_ConsistentWithIndividualBalances() public {
        _vestFromSablier(alice, 100 * G);
        _vestFromSablier(bob, 50 * G);
        vm.prank(snapshotter);
        uint256 s1 = gobi.snapshot();
        uint256 sum = gobi.categoryABalanceAt(alice, s1) + gobi.categoryABalanceAt(bob, s1);
        assertEq(sum, gobi.categoryATotalSupplyAt(s1));
    }

    /// Snapshot id 0 is invalid and must revert for both historical views.
    function test_History_IdZeroReverts() public {
        vm.expectRevert(bytes("ERC20Snapshot: id is 0"));
        gobi.categoryABalanceAt(alice, 0);
        vm.expectRevert(bytes("ERC20Snapshot: id is 0"));
        gobi.categoryATotalSupplyAt(0);
    }

    /// A snapshot id that hasn't happened yet must revert for both views.
    function test_History_NonexistentSnapshotReverts() public {
        vm.expectRevert(bytes("ERC20Snapshot: nonexistent id"));
        gobi.categoryABalanceAt(alice, 99);
        vm.expectRevert(bytes("ERC20Snapshot: nonexistent id"));
        gobi.categoryATotalSupplyAt(99);
    }

    // =================================================================
    // 7. TGE TIMESTAMP VALIDATION
    // =================================================================

    /// setTgeTimestamp can only ever be called once -- a second call,
    /// even with a different value, must revert.
    function test_Tge_OneShot() public {
        vm.prank(multisig);
        gobi.setTgeTimestamp(TGE);
        vm.prank(multisig);
        vm.expectRevert(bytes("TGE timestamp already set"));
        gobi.setTgeTimestamp(TGE + 1);
    }

    /// A zero timestamp is rejected outright.
    function test_Tge_ZeroReverts() public {
        vm.prank(multisig);
        vm.expectRevert(bytes("Gobi: zero timestamp"));
        gobi.setTgeTimestamp(0);
    }

    /// Only DEFAULT_ADMIN_ROLE may call setTgeTimestamp.
    function test_Tge_OnlyAdmin() public {
        vm.prank(stranger);
        vm.expectRevert();
        gobi.setTgeTimestamp(TGE);
    }

    /// A timestamp more than 180 days in the future is rejected -- this
    /// is the guard against a milliseconds-vs-seconds data-entry mistake.
    function test_Tge_TooFarFutureReverts() public {
        vm.prank(multisig);
        vm.expectRevert(bytes("Gobi: TGE timestamp too far in the future"));
        gobi.setTgeTimestamp(block.timestamp + 181 days);
    }

    /// Boundary: exactly 180 days in the future is the last VALID value.
    function test_Tge_ExactlyAtFutureBoundary_Succeeds() public {
        vm.prank(multisig);
        gobi.setTgeTimestamp(block.timestamp + 180 days);
        assertEq(gobi.tgeTimestamp(), block.timestamp + 180 days);
    }

    /// A timestamp more than 30 days in the past is rejected.
    function test_Tge_TooFarPastReverts() public {
        vm.warp(1_800_000_000);
        vm.prank(multisig);
        vm.expectRevert(bytes("Gobi: TGE timestamp too far in the past"));
        gobi.setTgeTimestamp(block.timestamp - 31 days);
    }

    /// Boundary: exactly 30 days in the past is the last VALID value.
    function test_Tge_ExactlyAtPastBoundary_Succeeds() public {
        vm.warp(1_800_000_000);
        vm.prank(multisig);
        gobi.setTgeTimestamp(block.timestamp - 30 days);
        assertEq(gobi.tgeTimestamp(), block.timestamp - 30 days);
    }

    /// The classic real-world mistake: passing a JS millisecond timestamp
    /// where Unix seconds are expected must be rejected, not silently
    /// accepted (which would brick the lock-up open for millennia).
    function test_Tge_MillisecondMistake_Rejected() public {
        vm.warp(1_800_000_000);
        uint256 nowSeconds = block.timestamp;
        vm.prank(multisig);
        vm.expectRevert(bytes("Gobi: TGE timestamp too far in the future"));
        gobi.setTgeTimestamp(nowSeconds * 1000);
    }

    /// lockupActive() transitions exactly at TGE + 180 days, in both
    /// directions, confirming the boundary is handled correctly.
    function test_Lockup_ActiveThroughWindow() public {
        _setTge();
        assertTrue(gobi.lockupActive());
        vm.warp(TGE + 90 days);
        assertTrue(gobi.lockupActive());
        vm.warp(TGE + 180 days - 1);
        assertTrue(gobi.lockupActive());
        vm.warp(TGE + 180 days);
        assertFalse(gobi.lockupActive());
        vm.warp(TGE + 400 days);
        assertFalse(gobi.lockupActive());
    }

    // =================================================================
    // 8. MINT / BURN / SUPPLY CAP
    // =================================================================

    /// Only MINTER_ROLE may mint.
    function test_Mint_NonMinterReverts() public {
        vm.prank(stranger);
        vm.expectRevert();
        gobi.mint(stranger, 1 * G);
    }

    /// Minting exactly up to MAX_SUPPLY succeeds.
    function test_Mint_UpToExactCap() public {
        uint256 headroom = CAP - gobi.totalSupply();
        vm.prank(minter);
        gobi.mint(pub2, headroom);
        assertEq(gobi.totalSupply(), CAP);
    }

    /// Minting one wei over MAX_SUPPLY reverts.
    function test_Mint_OneWeiOverCapReverts() public {
        uint256 headroom = CAP - gobi.totalSupply();
        vm.prank(minter);
        vm.expectRevert(bytes("Mint would exceed max supply"));
        gobi.mint(pub2, headroom + 1);
    }

    /// Burning frees headroom under the cap for future minting (the cap
    /// constrains CURRENT supply, not lifetime issuance).
    function test_Mint_BurnFreesHeadroom() public {
        uint256 headroom = CAP - gobi.totalSupply();
        vm.prank(minter);
        gobi.mint(pub2, headroom);
        vm.prank(pub2);
        gobi.burn(50 * G);
        vm.prank(minter);
        gobi.mint(pub2, 50 * G);
        assertEq(gobi.totalSupply(), CAP);
    }

    /// Minting directly to an already-locked eligible wallet must succeed
    /// (mint is exempt from the lock) but must NOT itself add to eligible
    /// balance -- only a transfer FROM Sablier does that.
    function test_Mint_ToLockedWallet_SucceedsButNotEligible() public {
        _vestFromSablier(alice, 100 * G);
        _setTge();
        vm.prank(minter);
        gobi.mint(alice, 50 * G); // must not revert
        assertEq(gobi.balanceOf(alice), 150 * G);
        assertEq(gobi.categoryAEligibleBalance(alice), 100 * G, "unchanged by the mint");
    }

    /// Ordinary burn reduces balance and total supply as expected for a
    /// non-eligible wallet.
    function test_Burn_Ordinary() public {
        vm.prank(whale);
        gobi.burn(100 * G);
        assertEq(gobi.balanceOf(whale), 9_900 * G);
    }

    /// burnFrom without a sufficient allowance reverts, as standard ERC20.
    function test_BurnFrom_WithoutAllowanceReverts() public {
        vm.prank(pub1);
        vm.expectRevert();
        gobi.burnFrom(whale, 100 * G);
    }

    // =================================================================
    // 9. ROLES
    // =================================================================

    /// The admin can grant and revoke roles freely.
    function test_Roles_AdminGrantsAndRevokes() public {
        bytes32 role = gobi.MINTER_ROLE();
        vm.prank(multisig);
        gobi.grantRole(role, stranger);
        assertTrue(gobi.hasRole(role, stranger));
        vm.prank(multisig);
        gobi.revokeRole(role, stranger);
        assertFalse(gobi.hasRole(role, stranger));
    }

    /// A non-admin cannot grant any role.
    function test_Roles_NonAdminCannotGrant() public {
        bytes32 role = gobi.MINTER_ROLE();
        vm.prank(stranger);
        vm.expectRevert();
        gobi.grantRole(role, stranger);
    }

    /// Only SNAPSHOT_ROLE may call snapshot().
    function test_Snapshot_OnlyRole() public {
        vm.prank(stranger);
        vm.expectRevert();
        gobi.snapshot();
    }

    // =================================================================
    // 10. SNAPSHOT BALANCE MECHANICS (inherited ERC20Snapshot)
    // =================================================================

    /// Snapshot ids increment sequentially with each call.
    function test_Snapshot_IdsIncrement() public {
        vm.startPrank(snapshotter);
        assertEq(gobi.snapshot(), 1);
        assertEq(gobi.snapshot(), 2);
        assertEq(gobi.getCurrentSnapshotId(), 2);
        vm.stopPrank();
    }

    /// A snapshot correctly captures balances at that instant, unaffected
    /// by transfers that happen afterward.
    function test_Snapshot_CapturesBalances() public {
        vm.prank(snapshotter);
        uint256 s1 = gobi.snapshot();
        vm.prank(whale);
        gobi.transfer(pub1, 400 * G);
        assertEq(gobi.balanceOfAt(whale, s1), 10_000 * G);
        assertEq(gobi.balanceOfAt(pub1, s1), 0);
    }

    /// balanceOfAt reverts for a snapshot id that doesn't exist yet.
    function test_Snapshot_NonexistentIdReverts() public {
        vm.expectRevert(bytes("ERC20Snapshot: nonexistent id"));
        gobi.balanceOfAt(whale, 99);
    }

    // =================================================================
    // 11. FUZZ
    // =================================================================

    /// For any combination of a genuine vest and an ordinary transfer,
    /// eligible balance can never exceed the wallet's real balance.
    function testFuzz_EligibleNeverExceedsRealBalance(uint96 vestAmount, uint96 ordinaryAmount) public {
        vestAmount = uint96(bound(vestAmount, 0, 1000 * G));
        ordinaryAmount = uint96(bound(ordinaryAmount, 0, 1000 * G));
        if (vestAmount > 0) _vestFromSablier(alice, vestAmount);
        if (ordinaryAmount > 0) {
            vm.prank(whale);
            gobi.transfer(alice, ordinaryAmount);
        }
        assertLe(gobi.categoryAEligibleBalance(alice), gobi.balanceOf(alice));
    }

    /// For any point strictly inside the lock-up window, an eligible
    /// wallet's transfer must revert.
    function testFuzz_LockAlwaysBlocks_DuringWindow(uint96 amount, uint32 dt) public {
        amount = uint96(bound(amount, 1, 100 * G));
        dt = uint32(bound(dt, 0, 180 days - 1));
        _vestFromSablier(alice, 100 * G);
        _setTge();
        vm.warp(TGE + dt);
        vm.prank(alice);
        vm.expectRevert(bytes("SFA Section 276 Lockup: Category A transfers are locked"));
        gobi.transfer(pub1, amount);
    }

    /// For any point at or after expiry, transfers succeed and the debit
    /// never underflows regardless of how much is sent.
    function testFuzz_PostExpiry_DebitNeverUnderflows(uint96 sendAmount) public {
        sendAmount = uint96(bound(sendAmount, 1, 500 * G));
        _vestFromSablier(alice, 100 * G);
        vm.prank(whale);
        gobi.transfer(alice, 400 * G); // give her enough to send arbitrary amounts
        _expireLockup();
        vm.prank(alice);
        gobi.transfer(pub1, sendAmount);
        assertLe(gobi.categoryAEligibleBalance(alice), 100 * G);
    }
}
