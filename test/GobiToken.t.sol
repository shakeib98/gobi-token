// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/gobitoken.sol";

/// @dev Exhaustive unit tests for GobiToken covering: ERC-20 basics, supply
/// cap, minting, burning, roles, ERC20Snapshot machinery, every scenario of
/// the SFA §276 Transfer Restriction Registry (lock-up, whitelist, taint,
/// expiry), and the Category A historical checkpointing
/// (isCategoryAAt / categoryATotalSupplyAt) that backs the yield subsidy.
contract GobiTokenTest is Test {
    GobiToken internal gobi;

    address internal multisig = makeAddr("multisig");
    address internal compliance = makeAddr("compliance");
    address internal snapshotter = makeAddr("snapshotter");
    address internal minter = makeAddr("minter");
    address internal alice = makeAddr("alice"); // Category A investor
    address internal bob = makeAddr("bob"); // Category A investor
    address internal accr1 = makeAddr("accr1"); // accredited, not CatA
    address internal accr2 = makeAddr("accr2"); // accredited, not CatA
    address internal pub1 = makeAddr("pub1"); // public buyer
    address internal pub2 = makeAddr("pub2"); // public buyer
    address internal dex = makeAddr("dex"); // public venue
    address internal stranger = makeAddr("stranger"); // no roles, no tokens

    uint256 internal constant G = 1e18;
    uint256 internal constant INITIAL = 400_000_000e18;
    uint256 internal constant CAP = 1_200_000_000e18;
    uint256 internal constant TGE = 1_800_000_000; // arbitrary future ts

    function setUp() public {
        vm.startPrank(multisig);
        gobi = new GobiToken(multisig);
        gobi.grantRole(gobi.COMPLIANCE_ROLE(), compliance);
        gobi.grantRole(gobi.SNAPSHOT_ROLE(), snapshotter);
        gobi.grantRole(gobi.MINTER_ROLE(), minter);
        gobi.transfer(alice, 1000 * G);
        gobi.transfer(bob, 500 * G);
        gobi.transfer(pub1, 1000 * G);
        gobi.transfer(accr1, 200 * G);
        vm.stopPrank();

        vm.startPrank(compliance);
        gobi.setCategoryA(alice, true);
        gobi.setCategoryA(bob, true);
        gobi.setAccreditationStatus(accr1, true);
        gobi.setAccreditationStatus(accr2, true);
        gobi.setAccreditationStatus(alice, true);
        gobi.setAccreditationStatus(bob, true);
        vm.stopPrank();
    }

    function _setTge() internal {
        vm.warp(TGE);
        vm.prank(multisig);
        gobi.setTgeTimestamp(TGE);
    }

    function _expireLockup() internal {
        _setTge();
        vm.warp(TGE + 180 days);
    }

    // =================================================================
    // 1. Deployment
    // =================================================================

    function test_Deploy_Metadata() public {
        assertEq(gobi.name(), "Gobi Token");
        assertEq(gobi.symbol(), "GOBI");
        assertEq(gobi.decimals(), 18);
    }

    function test_Deploy_InitialSupplyToMultisig() public {
        GobiToken fresh = new GobiToken(multisig);
        assertEq(fresh.totalSupply(), INITIAL);
        assertEq(fresh.balanceOf(multisig), INITIAL);
    }

    function test_Deploy_RolesGranted() public {
        assertTrue(gobi.hasRole(gobi.DEFAULT_ADMIN_ROLE(), multisig));
        assertTrue(gobi.hasRole(gobi.MINTER_ROLE(), multisig));
        GobiToken fresh = new GobiToken(multisig);
        assertFalse(fresh.hasRole(fresh.COMPLIANCE_ROLE(), multisig));
        assertFalse(fresh.hasRole(fresh.SNAPSHOT_ROLE(), multisig));
    }

    function test_Deploy_ZeroMultisigReverts() public {
        vm.expectRevert(bytes("Multisig address cannot be zero"));
        new GobiToken(address(0));
    }

    function test_Deploy_TgeUnset_LockupActive() public {
        assertEq(gobi.tgeTimestamp(), 0);
        assertTrue(gobi.lockupActive());
    }

    function test_Deploy_CategoryASupplyStartsZero() public {
        GobiToken fresh = new GobiToken(multisig);
        assertEq(fresh.categoryATotalSupply(), 0);
    }

    // =================================================================
    // 2. Minting & supply cap
    // =================================================================

    function test_Mint_ByMinter() public {
        vm.prank(minter);
        gobi.mint(pub2, 100 * G);
        assertEq(gobi.balanceOf(pub2), 100 * G);
        assertEq(gobi.totalSupply(), INITIAL + 100 * G);
    }

    function test_Mint_NonMinterReverts() public {
        vm.prank(stranger);
        vm.expectRevert();
        gobi.mint(stranger, 1 * G);
    }

    function test_Mint_UpToExactCap() public {
        uint256 headroom = CAP - gobi.totalSupply();
        vm.prank(minter);
        gobi.mint(pub2, headroom);
        assertEq(gobi.totalSupply(), CAP);
    }

    function test_Mint_OneWeiOverCapReverts() public {
        uint256 headroom = CAP - gobi.totalSupply();
        vm.prank(minter);
        vm.expectRevert(bytes("Mint would exceed max supply"));
        gobi.mint(pub2, headroom + 1);
    }

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

    function test_Mint_ToCategoryA_DuringLockup() public {
        _setTge();
        vm.prank(minter);
        gobi.mint(alice, 10 * G); // from == 0 exempt from restriction
        assertEq(gobi.balanceOf(alice), 1010 * G);
    }

    function test_Mint_DoesNotTaintRecipient() public {
        _setTge();
        vm.prank(minter);
        gobi.mint(pub2, 10 * G);
        assertFalse(gobi.isCategoryA(pub2));
    }

    function test_Mint_ToCategoryAWallet_IncreasesCategoryASupply() public {
        // minting is exempt from the RESTRICTION check but still moves
        // balance into a CatA wallet, so the supply counter must track it
        uint256 before = gobi.categoryATotalSupply();
        vm.prank(minter);
        gobi.mint(alice, 10 * G);
        assertEq(gobi.categoryATotalSupply(), before + 10 * G);
    }

    // =================================================================
    // 3. Burning
    // =================================================================

    function test_Burn_Own() public {
        vm.prank(pub1);
        gobi.burn(100 * G);
        assertEq(gobi.balanceOf(pub1), 900 * G);
        assertEq(gobi.totalSupply(), INITIAL - 100 * G);
    }

    function test_Burn_CategoryA_DuringLockup() public {
        _setTge();
        vm.prank(alice);
        gobi.burn(100 * G); // to == 0 exempt from restriction
        assertEq(gobi.balanceOf(alice), 900 * G);
    }

    function test_Burn_CategoryAWallet_DecreasesCategoryASupply() public {
        uint256 before = gobi.categoryATotalSupply();
        vm.prank(alice);
        gobi.burn(50 * G);
        assertEq(gobi.categoryATotalSupply(), before - 50 * G);
    }

    function test_BurnFrom_WithAllowance() public {
        vm.prank(pub1);
        gobi.approve(pub2, 100 * G);
        vm.prank(pub2);
        gobi.burnFrom(pub1, 100 * G);
        assertEq(gobi.balanceOf(pub1), 900 * G);
    }

    function test_BurnFrom_WithoutAllowanceReverts() public {
        vm.prank(pub2);
        vm.expectRevert();
        gobi.burnFrom(pub1, 100 * G);
    }

    // =================================================================
    // 4. Roles / access control
    // =================================================================

    function test_Roles_AdminGrantsAndRevokes() public {
        bytes32 role = gobi.COMPLIANCE_ROLE();
        vm.prank(multisig);
        gobi.grantRole(role, stranger);
        assertTrue(gobi.hasRole(role, stranger));
        vm.prank(multisig);
        gobi.revokeRole(role, stranger);
        assertFalse(gobi.hasRole(role, stranger));
    }

    function test_Roles_NonAdminCannotGrant() public {
        bytes32 role = gobi.COMPLIANCE_ROLE();
        vm.prank(stranger);
        vm.expectRevert();
        gobi.grantRole(role, stranger);
    }

    function test_Roles_AdminWithoutComplianceRoleBlocked() public {
        vm.startPrank(multisig);
        vm.expectRevert();
        gobi.setCategoryA(pub1, true);
        vm.expectRevert();
        gobi.setAccreditationStatus(pub1, true);
        vm.stopPrank();
    }

    // =================================================================
    // 5. Snapshots (ERC20Snapshot balance machinery)
    // =================================================================

    function test_Snapshot_OnlyRole() public {
        vm.prank(stranger);
        vm.expectRevert();
        gobi.snapshot();
    }

    function test_Snapshot_IdsIncrement() public {
        vm.startPrank(snapshotter);
        assertEq(gobi.snapshot(), 1);
        assertEq(gobi.snapshot(), 2);
        assertEq(gobi.getCurrentSnapshotId(), 2);
        vm.stopPrank();
    }

    function test_Snapshot_EmitsEvent() public {
        vm.expectEmit(true, false, false, false, address(gobi));
        emit GobiToken.SnapshotTaken(1);
        vm.prank(snapshotter);
        gobi.snapshot();
    }

    function test_Snapshot_CapturesBalances() public {
        vm.prank(snapshotter);
        uint256 s1 = gobi.snapshot();
        vm.prank(pub1);
        gobi.transfer(pub2, 400 * G);
        vm.prank(snapshotter);
        uint256 s2 = gobi.snapshot();

        assertEq(gobi.balanceOfAt(pub1, s1), 1000 * G);
        assertEq(gobi.balanceOfAt(pub2, s1), 0);
        assertEq(gobi.balanceOfAt(pub1, s2), 600 * G);
        assertEq(gobi.balanceOfAt(pub2, s2), 400 * G);
    }

    function test_Snapshot_HistoricalValuesImmutable() public {
        vm.prank(snapshotter);
        uint256 s1 = gobi.snapshot();
        vm.prank(pub1);
        gobi.transfer(pub2, 999 * G);
        assertEq(gobi.balanceOfAt(pub1, s1), 1000 * G);
        assertEq(gobi.totalSupplyAt(s1), INITIAL);
    }

    function test_Snapshot_ReflectsMintAndBurn() public {
        vm.prank(snapshotter);
        uint256 s1 = gobi.snapshot();
        vm.prank(minter);
        gobi.mint(pub2, 100 * G);
        vm.prank(pub1);
        gobi.burn(50 * G);
        vm.prank(snapshotter);
        uint256 s2 = gobi.snapshot();

        assertEq(gobi.totalSupplyAt(s1), INITIAL);
        assertEq(gobi.totalSupplyAt(s2), INITIAL + 100 * G - 50 * G);
    }

    function test_Snapshot_NonexistentIdReverts() public {
        vm.expectRevert(bytes("ERC20Snapshot: nonexistent id"));
        gobi.balanceOfAt(pub1, 99);
        vm.expectRevert(bytes("ERC20Snapshot: nonexistent id"));
        gobi.totalSupplyAt(99);
    }

    function test_Snapshot_IdZeroReverts() public {
        vm.expectRevert(bytes("ERC20Snapshot: id is 0"));
        gobi.balanceOfAt(pub1, 0);
    }

    function test_Snapshot_WorksDuringLockupWithRestrictedTransfers() public {
        _setTge();
        vm.prank(alice);
        gobi.transfer(accr1, 100 * G);
        vm.prank(snapshotter);
        uint256 s = gobi.snapshot();
        assertEq(gobi.balanceOfAt(alice, s), 900 * G);
        assertEq(gobi.balanceOfAt(accr1, s), 300 * G);
        assertEq(gobi.totalSupplyAt(s), INITIAL);
    }

    // =================================================================
    // 6. TGE timestamp & lockup clock
    // =================================================================

    function test_Tge_AdminOnly() public {
        vm.prank(compliance);
        vm.expectRevert();
        gobi.setTgeTimestamp(TGE);
        vm.prank(stranger);
        vm.expectRevert();
        gobi.setTgeTimestamp(TGE);
    }

    function test_Tge_ZeroReverts() public {
        vm.prank(multisig);
        vm.expectRevert(bytes("Gobi: zero timestamp"));
        gobi.setTgeTimestamp(0);
    }

    function test_Tge_OneShot() public {
        vm.warp(TGE);
        vm.prank(multisig);
        gobi.setTgeTimestamp(TGE);
        vm.prank(multisig);
        vm.expectRevert(bytes("TGE timestamp already set"));
        gobi.setTgeTimestamp(TGE + 1);
    }

    function test_Tge_EmitsEvent() public {
        vm.warp(TGE);
        vm.expectEmit(false, false, false, true, address(gobi));
        emit GobiToken.TgeTimestampSet(TGE);
        vm.prank(multisig);
        gobi.setTgeTimestamp(TGE);
    }

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
    // 7. Compliance setters
    // =================================================================

    function test_SetCategoryA_RoleGated() public {
        vm.prank(stranger);
        vm.expectRevert();
        gobi.setCategoryA(pub1, true);
    }

    function test_SetCategoryA_ZeroAddressReverts() public {
        vm.prank(compliance);
        vm.expectRevert(bytes("Gobi: zero address"));
        gobi.setCategoryA(address(0), true);
    }

    function test_SetCategoryA_ToggleBothWays() public {
        vm.startPrank(compliance);
        gobi.setCategoryA(pub1, true);
        assertTrue(gobi.isCategoryA(pub1));
        gobi.setCategoryA(pub1, false);
        assertFalse(gobi.isCategoryA(pub1));
        vm.stopPrank();
    }

    function test_SetCategoryA_EmitsEvent() public {
        vm.expectEmit(true, false, false, true, address(gobi));
        emit GobiToken.CategoryASet(pub1, true);
        vm.prank(compliance);
        gobi.setCategoryA(pub1, true);
    }

    function test_SetCategoryA_RedundantSetIsNoop() public {
        // alice already CatA; setting true again must not double-count supply
        uint256 before = gobi.categoryATotalSupply();
        vm.prank(compliance);
        gobi.setCategoryA(alice, true);
        assertEq(gobi.categoryATotalSupply(), before);
    }

    function test_SetAccreditation_RoleGated() public {
        vm.prank(stranger);
        vm.expectRevert();
        gobi.setAccreditationStatus(stranger, true);
    }

    function test_SetAccreditation_ZeroAddressReverts() public {
        vm.prank(compliance);
        vm.expectRevert(bytes("Gobi: zero address"));
        gobi.setAccreditationStatus(address(0), true);
    }

    function test_SetAccreditation_EmitsEvent() public {
        vm.expectEmit(true, false, false, true, address(gobi));
        emit GobiToken.AccreditationSet(pub1, true);
        vm.prank(compliance);
        gobi.setAccreditationStatus(pub1, true);
    }

    function test_Batch_Accreditation() public {
        address[] memory list = new address[](3);
        list[0] = makeAddr("i1");
        list[1] = makeAddr("i2");
        list[2] = makeAddr("i3");
        vm.prank(compliance);
        gobi.setAccreditationStatusBatch(list, true);
        for (uint256 i = 0; i < 3; i++) {
            assertTrue(gobi.isAccredited(list[i]));
        }
        vm.prank(compliance);
        gobi.setAccreditationStatusBatch(list, false);
        for (uint256 i = 0; i < 3; i++) {
            assertFalse(gobi.isAccredited(list[i]));
        }
    }

    function test_Batch_CategoryA() public {
        address[] memory list = new address[](2);
        list[0] = makeAddr("p1");
        list[1] = makeAddr("p2");
        vm.prank(compliance);
        gobi.setCategoryABatch(list, true);
        assertTrue(gobi.isCategoryA(list[0]));
        assertTrue(gobi.isCategoryA(list[1]));
    }

    function test_Batch_RoleGated() public {
        address[] memory list = new address[](1);
        list[0] = pub1;
        vm.startPrank(stranger);
        vm.expectRevert();
        gobi.setCategoryABatch(list, true);
        vm.expectRevert();
        gobi.setAccreditationStatusBatch(list, true);
        vm.stopPrank();
    }

    function test_Batch_ZeroAddressInListReverts() public {
        address[] memory list = new address[](2);
        list[0] = pub1;
        list[1] = address(0);
        vm.prank(compliance);
        vm.expectRevert(bytes("Gobi: zero address"));
        gobi.setCategoryABatch(list, true);
        assertFalse(gobi.isCategoryA(pub1)); // atomic: partial write reverted
    }

    function test_Batch_EmptyArrayNoop() public {
        address[] memory list = new address[](0);
        vm.prank(compliance);
        gobi.setCategoryABatch(list, true);
    }

    // =================================================================
    // 8. Transfer restrictions — during lock-up
    // =================================================================

    function test_Restrict_CatA_ToAccredited_Allowed() public {
        _setTge();
        vm.prank(alice);
        gobi.transfer(accr1, 100 * G);
        assertEq(gobi.balanceOf(accr1), 300 * G);
    }

    function test_Restrict_CatA_ToCatA_Accredited_Allowed() public {
        _setTge();
        vm.prank(alice);
        gobi.transfer(bob, 100 * G);
        assertEq(gobi.balanceOf(bob), 600 * G);
    }

    function test_Restrict_CatA_ToPublic_Reverts() public {
        _setTge();
        vm.prank(alice);
        vm.expectRevert(bytes("SFA Section 276 Lockup: Recipient must be an Accredited Investor"));
        gobi.transfer(pub1, 100 * G);
    }

    function test_Restrict_CatA_ToDex_Reverts() public {
        _setTge();
        vm.prank(alice);
        vm.expectRevert(bytes("SFA Section 276 Lockup: Recipient must be an Accredited Investor"));
        gobi.transfer(dex, 100 * G);
    }

    function test_Restrict_BeforeTgeSet_AlsoBlocked() public {
        vm.prank(alice);
        vm.expectRevert(bytes("SFA Section 276 Lockup: Recipient must be an Accredited Investor"));
        gobi.transfer(pub1, 100 * G);
    }

    function test_Restrict_TransferFrom_AlsoEnforced() public {
        _setTge();
        vm.prank(alice);
        gobi.approve(pub1, 100 * G);
        vm.prank(pub1);
        vm.expectRevert(bytes("SFA Section 276 Lockup: Recipient must be an Accredited Investor"));
        gobi.transferFrom(alice, pub1, 100 * G);
        vm.prank(pub1);
        gobi.transferFrom(alice, accr1, 100 * G);
        assertEq(gobi.balanceOf(accr1), 300 * G);
    }

    function test_Restrict_ZeroAmountTransfer_StillChecked() public {
        _setTge();
        vm.prank(alice);
        vm.expectRevert(bytes("SFA Section 276 Lockup: Recipient must be an Accredited Investor"));
        gobi.transfer(pub1, 0);
    }

    function test_Restrict_SelfTransfer_RequiresOwnAccreditation() public {
        _setTge();
        vm.prank(alice);
        gobi.transfer(alice, 1 * G); // alice is accredited -> ok
        vm.prank(compliance);
        gobi.setAccreditationStatus(alice, false);
        vm.prank(alice);
        vm.expectRevert(bytes("SFA Section 276 Lockup: Recipient must be an Accredited Investor"));
        gobi.transfer(alice, 1 * G);
    }

    function test_Free_PublicToAnywhere() public {
        _setTge();
        vm.startPrank(pub1);
        gobi.transfer(dex, 100 * G);
        gobi.transfer(pub2, 100 * G);
        gobi.transfer(alice, 100 * G);
        vm.stopPrank();
        assertEq(gobi.balanceOf(dex), 100 * G);
        assertEq(gobi.balanceOf(pub2), 100 * G);
        assertEq(gobi.balanceOf(alice), 1100 * G);
    }

    function test_Free_AccreditedNonCatA_ToAnywhere() public {
        _setTge();
        vm.prank(accr1);
        gobi.transfer(dex, 50 * G);
        assertEq(gobi.balanceOf(dex), 50 * G);
    }

    function test_Restrict_RevokedAccreditationBlocksImmediately() public {
        _setTge();
        vm.prank(compliance);
        gobi.setAccreditationStatus(accr1, false);
        vm.prank(alice);
        vm.expectRevert(bytes("SFA Section 276 Lockup: Recipient must be an Accredited Investor"));
        gobi.transfer(accr1, 10 * G);
    }

    function test_Restrict_UnflaggedByCompliance_TradesFreely() public {
        _setTge();
        vm.prank(compliance);
        gobi.setCategoryA(alice, false);
        vm.prank(alice);
        gobi.transfer(dex, 100 * G);
        assertEq(gobi.balanceOf(dex), 100 * G);
    }

    // =================================================================
    // 9. Taint propagation
    // =================================================================

    function test_Taint_RecipientMarked_DuringLockup() public {
        _setTge();
        assertFalse(gobi.isCategoryA(accr1));
        vm.prank(alice);
        gobi.transfer(accr1, 100 * G);
        assertTrue(gobi.isCategoryA(accr1));
    }

    function test_Taint_EmitsEvent() public {
        _setTge();
        vm.expectEmit(true, false, false, true, address(gobi));
        emit GobiToken.CategoryASet(accr1, true);
        vm.prank(alice);
        gobi.transfer(accr1, 100 * G);
    }

    function test_Taint_TaintedWalletIsRestricted() public {
        _setTge();
        vm.prank(alice);
        gobi.transfer(accr1, 100 * G);
        vm.prank(accr1);
        vm.expectRevert(bytes("SFA Section 276 Lockup: Recipient must be an Accredited Investor"));
        gobi.transfer(dex, 10 * G);
        vm.prank(accr1);
        vm.expectRevert(bytes("SFA Section 276 Lockup: Recipient must be an Accredited Investor"));
        gobi.transfer(pub1, 200 * G); // ENTIRE balance restricted, incl. pre-existing
    }

    function test_Taint_ChainThroughMultipleAccredited() public {
        _setTge();
        vm.prank(alice);
        gobi.transfer(accr1, 100 * G);
        vm.prank(accr1);
        gobi.transfer(accr2, 100 * G);
        assertTrue(gobi.isCategoryA(accr2));
        vm.prank(accr2);
        vm.expectRevert(bytes("SFA Section 276 Lockup: Recipient must be an Accredited Investor"));
        gobi.transfer(dex, 100 * G);
    }

    function test_Taint_AlreadyCatA_StateUnchanged() public {
        _setTge();
        vm.prank(alice);
        gobi.transfer(bob, 100 * G);
        assertTrue(gobi.isCategoryA(bob));
    }

    function test_Taint_PublicSenderNeverTaints() public {
        _setTge();
        vm.prank(pub1);
        gobi.transfer(pub2, 100 * G);
        assertFalse(gobi.isCategoryA(pub2));
    }

    function test_Taint_NotAfterExpiry() public {
        _expireLockup();
        vm.prank(alice);
        gobi.transfer(pub1, 100 * G);
        assertFalse(gobi.isCategoryA(pub1));
    }

    // =================================================================
    // 10. Expiry behavior
    // =================================================================

    function test_Expiry_CatA_TradesFreely() public {
        _expireLockup();
        vm.startPrank(alice);
        gobi.transfer(dex, 100 * G);
        gobi.transfer(pub1, 100 * G);
        vm.stopPrank();
        assertEq(gobi.balanceOf(dex), 100 * G);
    }

    function test_Expiry_FlagRemainsButInert() public {
        _expireLockup();
        assertTrue(gobi.isCategoryA(alice));
        vm.prank(alice);
        gobi.transfer(dex, 100 * G);
        assertEq(gobi.balanceOf(dex), 100 * G);
    }

    function test_Expiry_AccreditationIrrelevant() public {
        _expireLockup();
        vm.prank(compliance);
        gobi.setAccreditationStatus(accr1, false);
        vm.prank(alice);
        gobi.transfer(accr1, 10 * G);
        assertEq(gobi.balanceOf(accr1), 210 * G);
    }

    // =================================================================
    // 11. Category A live supply tracking (categoryATotalSupply)
    // =================================================================

    function test_CatASupply_InitialFromSetup() public {
        // alice 1000 + bob 500 flagged in setUp
        assertEq(gobi.categoryATotalSupply(), 1500 * G);
    }

    function test_CatASupply_IncreasesOnFlag() public {
        uint256 before = gobi.categoryATotalSupply();
        vm.prank(compliance);
        gobi.setCategoryA(pub1, true);
        assertEq(gobi.categoryATotalSupply(), before + 1000 * G);
    }

    function test_CatASupply_DecreasesOnUnflag() public {
        uint256 before = gobi.categoryATotalSupply();
        vm.prank(compliance);
        gobi.setCategoryA(bob, false);
        assertEq(gobi.categoryATotalSupply(), before - 500 * G);
    }

    function test_CatASupply_UnchangedOnCatAToCatATransfer() public {
        uint256 before = gobi.categoryATotalSupply();
        _setTge();
        vm.prank(alice);
        gobi.transfer(bob, 50 * G);
        assertEq(gobi.categoryATotalSupply(), before); // moved within CatA set
    }

    function test_CatASupply_IncreasesOnPublicToCatATransfer() public {
        uint256 before = gobi.categoryATotalSupply();
        _setTge();
        vm.prank(pub1);
        gobi.transfer(alice, 100 * G);
        assertEq(gobi.categoryATotalSupply(), before + 100 * G);
    }

    function test_CatASupply_DecreasesOnCatAToPublicTransfer_PostExpiry() public {
        uint256 before = gobi.categoryATotalSupply();
        _expireLockup();
        vm.prank(alice);
        gobi.transfer(pub1, 100 * G);
        assertEq(gobi.categoryATotalSupply(), before - 100 * G);
    }

    function test_CatASupply_TaintAddsRecipientWholeBalance() public {
        _setTge();
        uint256 before = gobi.categoryATotalSupply();
        // accr1 holds 200 pre-existing; alice sends 10, accr1 gets tainted
        vm.prank(alice);
        gobi.transfer(accr1, 10 * G);
        // -10 (left alice) + 210 (accr1's whole new balance) = +200 net
        assertEq(gobi.categoryATotalSupply(), before + 200 * G);
    }

    function test_CatASupply_TracksMintAndBurn() public {
        uint256 before = gobi.categoryATotalSupply();
        vm.prank(minter);
        gobi.mint(alice, 40 * G);
        assertEq(gobi.categoryATotalSupply(), before + 40 * G);
        vm.prank(alice);
        gobi.burn(40 * G);
        assertEq(gobi.categoryATotalSupply(), before);
    }

    function test_CatASupply_UnaffectedByNonCatATransfers() public {
        uint256 before = gobi.categoryATotalSupply();
        vm.prank(pub1);
        gobi.transfer(pub2, 500 * G);
        assertEq(gobi.categoryATotalSupply(), before);
    }

    // =================================================================
    // 12. Historical views: isCategoryAAt / categoryATotalSupplyAt
    // =================================================================

    function test_History_FlagFrozenAtSnapshot_UnaffectedByLaterTaint() public {
        bytes32 snapRole = gobi.SNAPSHOT_ROLE();
        vm.prank(multisig);
        gobi.grantRole(snapRole, multisig);
        _setTge();
        vm.prank(multisig);
        uint256 s1 = gobi.snapshot();

        // taint accr1 AFTER the snapshot
        vm.prank(alice);
        gobi.transfer(accr1, 10 * G);

        assertFalse(gobi.isCategoryAAt(accr1, s1), "accr1 was NOT CatA at s1");
        assertTrue(gobi.isCategoryA(accr1), "accr1 IS CatA now (live)");
        assertTrue(gobi.isCategoryAAt(alice, s1), "alice was CatA at s1");
    }

    function test_History_FlagFrozenAtSnapshot_UnaffectedByLaterUnflag() public {
        bytes32 snapRole = gobi.SNAPSHOT_ROLE();
        vm.prank(multisig);
        gobi.grantRole(snapRole, multisig);
        vm.prank(multisig);
        uint256 s1 = gobi.snapshot();

        vm.prank(compliance);
        gobi.setCategoryA(alice, false); // AFTER the snapshot

        assertTrue(gobi.isCategoryAAt(alice, s1), "alice was CatA at s1");
        assertFalse(gobi.isCategoryA(alice), "alice is NOT CatA now (live)");
    }

    function test_History_MultipleSnapshotsIndependent() public {
        bytes32 snapRole = gobi.SNAPSHOT_ROLE();
        vm.prank(multisig);
        gobi.grantRole(snapRole, multisig);

        vm.startPrank(multisig);
        uint256 s1 = gobi.snapshot(); // alice, bob CatA
        vm.stopPrank();

        vm.prank(compliance);
        gobi.setCategoryA(alice, false);

        vm.prank(multisig);
        uint256 s2 = gobi.snapshot(); // alice no longer CatA

        vm.prank(compliance);
        gobi.setCategoryA(alice, true); // re-flagged

        vm.prank(multisig);
        uint256 s3 = gobi.snapshot(); // alice CatA again

        assertTrue(gobi.isCategoryAAt(alice, s1));
        assertFalse(gobi.isCategoryAAt(alice, s2));
        assertTrue(gobi.isCategoryAAt(alice, s3));
        assertTrue(gobi.isCategoryA(alice)); // live matches s3
    }

    function test_History_UnchangedFlagFallsThroughToLive() public {
        // bob's flag never changes after s1 -> no checkpoint entries exist,
        // so isCategoryAAt must fall through to current isCategoryA
        bytes32 snapRole = gobi.SNAPSHOT_ROLE();
        vm.prank(multisig);
        gobi.grantRole(snapRole, multisig);
        vm.prank(multisig);
        uint256 s1 = gobi.snapshot();
        assertTrue(gobi.isCategoryAAt(bob, s1));
        assertTrue(gobi.isCategoryA(bob));
    }

    function test_History_SupplyFrozenAtSnapshot() public {
        bytes32 snapRole = gobi.SNAPSHOT_ROLE();
        vm.prank(multisig);
        gobi.grantRole(snapRole, multisig);
        _setTge();
        vm.prank(multisig);
        uint256 s1 = gobi.snapshot();

        vm.prank(alice);
        gobi.transfer(accr1, 10 * G); // taint changes live supply by +200

        assertEq(gobi.categoryATotalSupplyAt(s1), 1500 * G, "historical unchanged");
        assertEq(gobi.categoryATotalSupply(), 1700 * G, "live updated");
    }

    function test_History_SupplyAcrossMultipleSnapshots() public {
        bytes32 snapRole = gobi.SNAPSHOT_ROLE();
        vm.prank(multisig);
        gobi.grantRole(snapRole, multisig);

        vm.prank(multisig);
        uint256 s1 = gobi.snapshot(); // 1500

        vm.prank(compliance);
        gobi.setCategoryA(pub1, true); // +1000

        vm.prank(multisig);
        uint256 s2 = gobi.snapshot(); // 2500

        vm.prank(compliance);
        gobi.setCategoryA(bob, false); // -500

        vm.prank(multisig);
        uint256 s3 = gobi.snapshot(); // 2000

        assertEq(gobi.categoryATotalSupplyAt(s1), 1500 * G);
        assertEq(gobi.categoryATotalSupplyAt(s2), 2500 * G);
        assertEq(gobi.categoryATotalSupplyAt(s3), 2000 * G);
        assertEq(gobi.categoryATotalSupply(), 2000 * G);
    }

    function test_History_NonexistentSnapshotReverts() public {
        vm.expectRevert(bytes("ERC20Snapshot: nonexistent id"));
        gobi.isCategoryAAt(alice, 99);
        vm.expectRevert(bytes("ERC20Snapshot: nonexistent id"));
        gobi.categoryATotalSupplyAt(99);
    }

    function test_History_IdZeroReverts() public {
        vm.expectRevert(bytes("ERC20Snapshot: id is 0"));
        gobi.isCategoryAAt(alice, 0);
        vm.expectRevert(bytes("ERC20Snapshot: id is 0"));
        gobi.categoryATotalSupplyAt(0);
    }

    function test_History_ConsistentWithBalanceSum() public {
        // invariant: sum of balanceOfAt over CatA-at-snapshot wallets ==
        // categoryATotalSupplyAt, for a known closed set
        bytes32 snapRole = gobi.SNAPSHOT_ROLE();
        vm.prank(multisig);
        gobi.grantRole(snapRole, multisig);
        vm.prank(multisig);
        uint256 s1 = gobi.snapshot();

        uint256 sum = 0;
        address[5] memory wallets = [alice, bob, accr1, accr2, pub1];
        for (uint256 i = 0; i < 5; i++) {
            if (gobi.isCategoryAAt(wallets[i], s1)) {
                sum += gobi.balanceOfAt(wallets[i], s1);
            }
        }
        assertEq(sum, gobi.categoryATotalSupplyAt(s1));
    }

    // THE scenario: legal transfer taints a wallet with a pre-existing,
    // already-snapshotted balance; verifies isCategoryAAt correctly says
    // "no" for the earlier snapshot even though live state says "yes".
    function test_History_PreExistingBalanceWallet_TaintedAfterSnapshot() public {
        bytes32 snapRole = gobi.SNAPSHOT_ROLE();
        vm.prank(multisig);
        gobi.grantRole(snapRole, multisig);
        _setTge();

        // accr1 already holds 200 tokens as a plain accredited (non-CatA) wallet
        assertFalse(gobi.isCategoryA(accr1));
        vm.prank(multisig);
        uint256 s1 = gobi.snapshot(); // accr1 balance=200, NOT CatA at s1

        // legal transfer taints accr1 AFTER the snapshot
        vm.prank(alice);
        gobi.transfer(accr1, 1 * G);
        assertTrue(gobi.isCategoryA(accr1), "accr1 is CatA now");

        // the historical question for epoch s1 must still be "no"
        assertFalse(gobi.isCategoryAAt(accr1, s1));
        assertEq(gobi.balanceOfAt(accr1, s1), 200 * G, "balance at s1 unaffected");
    }

    // =================================================================
    // 13. Fuzz
    // =================================================================

    function testFuzz_PublicTransfersUnaffected(uint96 amount) public {
        amount = uint96(bound(amount, 0, 1000 * G));
        _setTge();
        vm.prank(pub1);
        gobi.transfer(pub2, amount);
        assertEq(gobi.balanceOf(pub2), amount);
        assertFalse(gobi.isCategoryA(pub2));
    }

    function testFuzz_CatAToPublicAlwaysReverts_DuringLockup(uint96 amount, uint32 dt) public {
        amount = uint96(bound(amount, 0, 1000 * G));
        dt = uint32(bound(dt, 0, 180 days - 1));
        _setTge();
        vm.warp(TGE + dt);
        vm.prank(alice);
        vm.expectRevert(bytes("SFA Section 276 Lockup: Recipient must be an Accredited Investor"));
        gobi.transfer(pub1, amount);
    }

    function testFuzz_CatAToAccreditedAlwaysWorks_DuringLockup(uint96 amount) public {
        amount = uint96(bound(amount, 0, 1000 * G));
        _setTge();
        vm.prank(alice);
        gobi.transfer(accr1, amount);
        assertEq(gobi.balanceOf(accr1), 200 * G + amount);
    }

    function testFuzz_CategoryASupplyNeverUnderflows(uint96 unflagAmt) public {
        unflagAmt; // unused; unflag exactly what exists
        uint256 before = gobi.categoryATotalSupply();
        vm.prank(compliance);
        gobi.setCategoryA(alice, false);
        assertEq(gobi.categoryATotalSupply(), before - 1000 * G);
        vm.prank(compliance);
        gobi.setCategoryA(alice, true);
        assertEq(gobi.categoryATotalSupply(), before);
    }

    function testFuzz_HistoricalSupplyNeverExceedsCurrentAfterOnlyIncreases(uint96 amt) public {
        amt = uint96(bound(amt, 1, 500 * G));
        bytes32 snapRole = gobi.SNAPSHOT_ROLE();
        vm.prank(multisig);
        gobi.grantRole(snapRole, multisig);
        vm.prank(multisig);
        uint256 s1 = gobi.snapshot();
        uint256 histBefore = gobi.categoryATotalSupplyAt(s1);

        vm.prank(pub1);
        gobi.transfer(alice, amt); // only ever increases CatA supply here

        assertEq(gobi.categoryATotalSupplyAt(s1), histBefore, "past snapshot immutable");
        assertGe(gobi.categoryATotalSupply(), histBefore);
    }
}
