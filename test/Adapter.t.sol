// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "openzeppelin/token/ERC20/ERC20.sol";
import "../src/adapter/adapter.sol";
import "../src/gobitoken.sol";

contract AdapterMockUSDT is ERC20 {
    constructor() ERC20("Tether USD", "USDT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract AdapterMockForeign is ERC20 {
    constructor() ERC20("Foreign", "FRN") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Malicious USDT that tries to re-enter the Adapter on every
/// transfer, simulating a compromised or ERC-777-style token.
contract ReentrantMockUSDT is ERC20 {
    constructor() ERC20("Evil USDT", "eUSDT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    address public attackTarget;
    uint8 public attackMode; // 1 = claimWallet, 2 = sweepExcess
    uint256[] public attackIds;
    bool public reentered;

    function armClaimReentry(address target, uint256[] calldata ids) external {
        attackTarget = target;
        attackMode = 1;
        attackIds = ids;
    }

    function armSweepReentry(address target) external {
        attackTarget = target;
        attackMode = 2;
    }

    function _tryReenter() internal {
        if (attackMode == 0 || reentered) return;
        reentered = true;
        if (attackMode == 1) {
            (bool ok,) = attackTarget.call(abi.encodeWithSignature("claimWallet(uint256[])", attackIds));
            ok;
        } else if (attackMode == 2) {
            (bool ok,) = attackTarget.call(abi.encodeWithSignature("sweepExcess(address)", address(this)));
            ok;
        }
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool ok = super.transfer(to, amount);
        _tryReenter();
        return ok;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool ok = super.transferFrom(from, to, amount);
        _tryReenter();
        return ok;
    }
}

/// @dev USDT-like token whose transfer/transferFrom always return false,
/// simulating a non-compliant ERC20. SafeERC20 must revert on this.
contract FalseReturningMockUSDT is ERC20 {
    constructor() ERC20("False USDT", "fUSDT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function transfer(address, uint256) public pure override returns (bool) {
        return false;
    }

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        return false;
    }
}

/// @dev Full Adapter test suite. Every test documents the scenario it
/// proves directly above it. Base yield always uses a holder's FULL
/// balance; the JORC subsidy uses ONLY the Category A-eligible
/// (Sablier-sourced) portion of that balance.
contract AdapterTest is Test {
    Adapter internal adapter;
    GobiToken internal gobi;
    AdapterMockUSDT internal usdt;

    address internal admin = makeAddr("admin");
    address internal distributor = makeAddr("distributor");
    address internal sablier = makeAddr("sablier");
    address internal alice = makeAddr("alice"); // genuine vested investor
    address internal bob = makeAddr("bob"); // genuine vested investor
    address internal carol = makeAddr("carol"); // ordinary public holder
    address internal rescuer = makeAddr("rescuer");
    address internal dust = makeAddr("dust");
    address internal treasury = makeAddr("treasury");

    uint256 internal constant G = 1e18;
    uint256 internal constant U = 1e6;
    uint256 internal TGE;

    function setUp() public {
        TGE = block.timestamp + 10 days;
        vm.startPrank(admin);
        gobi = new GobiToken(admin, sablier);
        usdt = new AdapterMockUSDT();
        adapter = new Adapter(admin, address(usdt), address(gobi));
        gobi.grantRole(gobi.SNAPSHOT_ROLE(), address(adapter));
        gobi.grantRole(gobi.MINTER_ROLE(), admin);
        adapter.grantRole(adapter.DEPOSITOR_ROLE(), distributor);
        gobi.setTgeTimestamp(TGE);

        gobi.transfer(carol, 800 * G); // ordinary public distribution
        adapter.addExclusion(admin); // admin still holds the multisig bulk
        vm.stopPrank();

        _vestFromSablier(alice, 100 * G);
        _vestFromSablier(bob, 100 * G);

        vm.warp(TGE); // inside the lock-up window
        usdt.mint(distributor, 10_000_000 * U);
        vm.prank(distributor);
        usdt.approve(address(adapter), type(uint256).max);
    }

    /// @dev Simulates a genuine Sablier vesting withdrawal.
    function _vestFromSablier(address to, uint256 amount) internal {
        vm.prank(admin);
        gobi.mint(sablier, amount);
        vm.prank(sablier);
        gobi.transfer(to, amount);
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = a;
    }

    function _ids2(uint256 a, uint256 b) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](2);
        ids[0] = a;
        ids[1] = b;
    }

    function _claim(address who, uint256 id) internal {
        vm.prank(who);
        adapter.claimWallet(_ids(id));
    }

    function _deposit(uint256 amount, uint256 subsidy, string memory cid) internal {
        vm.prank(distributor);
        adapter.depositYield(amount, subsidy, cid);
    }

    // =================================================================
    // 1. DEPLOYMENT & WIRING
    // =================================================================

    /// Basic wiring: yieldAsset and gobiToken point to the right contracts.
    function test_Deploy_Wiring() public view {
        assertEq(address(adapter.yieldAsset()), address(usdt));
        assertEq(address(adapter.gobiToken()), address(gobi));
    }

    /// Zero-address constructor arguments must all revert.
    function test_Deploy_ZeroAddressReverts() public {
        vm.startPrank(admin);
        vm.expectRevert(bytes("Adapter: Admin zero address"));
        new Adapter(address(0), address(usdt), address(gobi));
        vm.expectRevert(bytes("Adapter: Yield asset zero address"));
        new Adapter(admin, address(0), address(gobi));
        vm.expectRevert(bytes("Adapter: Gobi zero address"));
        new Adapter(admin, address(usdt), address(0));
        vm.stopPrank();
    }

    /// SNAPSHOT_ROLE must be on the ADAPTER itself, not the distributor --
    /// the Adapter is msg.sender when it calls snapshot() during deposit.
    function test_Deploy_SnapshotRoleMustBeOnAdapter() public {
        bytes32 snapRole = gobi.SNAPSHOT_ROLE();
        vm.prank(admin);
        gobi.revokeRole(snapRole, address(adapter));
        vm.prank(distributor);
        vm.expectRevert();
        adapter.depositYield(1000 * U, 0, "cid");
    }

    // =================================================================
    // 2. EXCLUSION MANAGEMENT
    // =================================================================

    /// Ordinary add/remove exclusion works for non-Sablier addresses.
    function test_Exclusion_AddAndRemove() public {
        vm.prank(admin);
        adapter.addExclusion(carol);
        assertTrue(adapter.isExcluded(carol));
        vm.prank(admin);
        adapter.removeExclusion(carol);
        assertFalse(adapter.isExcluded(carol));
    }

    function test_Exclusion_AddZeroAddressReverts() public {
        vm.prank(admin);
        vm.expectRevert(bytes("Adapter: Target zero address"));
        adapter.addExclusion(address(0));
    }

    function test_Exclusion_RemoveNotExcludedReverts() public {
        vm.prank(admin);
        vm.expectRevert(bytes("Adapter: Not excluded"));
        adapter.removeExclusion(carol);
    }

    function test_Exclusion_OnlyAdmin() public {
        vm.prank(distributor);
        vm.expectRevert();
        adapter.addExclusion(carol);
    }

    // =================================================================
    // 3. DEPOSIT — denominators (base = full balance, subsidy = eligible only)
    // =================================================================

    /// Base denominator = total supply minus EXCLUDED FULL balances.
    /// Subsidy denominator = total eligible supply minus excluded
    /// ELIGIBLE amounts only (not full balances) of excluded wallets.
    function test_Deposit_ComputesBothDenominatorsCorrectly() public {
        _deposit(1000 * U, 0, "cid0");
        (, uint256 amt, uint256 sub, uint256 denom, uint256 catADenom,,) = adapter.epochs(0);
        assertEq(amt, 1000 * U);
        assertEq(sub, 0);
        assertEq(denom, 1000 * G, "alice100+bob100+carol800");
        assertEq(catADenom, 200 * G, "alice100+bob100 eligible only");
    }

    /// A wallet that's part of the EXCLUDED set but ALSO genuinely
    /// received some Sablier tokens (e.g. treasury receiving a stream)
    /// has that eligible AMOUNT subtracted out of the subsidy pool --
    /// same as any excluded wallet, not added to it.
    function test_Deposit_ExcludedWalletWithGenuineVest_OnlyEligiblePortionRemoved() public {
        vm.prank(admin);
        adapter.addExclusion(carol);
        _vestFromSablier(carol, 30 * G); // carol also gets a small genuine vest
        _deposit(1000 * U, 0, "cid0");
        (,,, uint256 denom, uint256 catADenom,,) = adapter.epochs(0);
        // base denom: alice100+bob100 (carol now excluded, her 830 removed entirely)
        assertEq(denom, 200 * G);
        // subsidy denom: global total (alice100+bob100+carol30=230) minus
        // carol's excluded eligible amount (30) = 200 -- NOT added, subtracted
        assertEq(catADenom, 200 * G);
    }

    function test_Deposit_RejectsZeroAmount() public {
        vm.prank(distributor);
        vm.expectRevert(bytes("Adapter: Deposit must exceed zero"));
        adapter.depositYield(0, 0, "cid");
    }

    function test_Deposit_RejectsEmptyIpfsHash() public {
        vm.prank(distributor);
        vm.expectRevert(bytes("Adapter: IPFS hash cannot be empty"));
        adapter.depositYield(1000 * U, 0, "");
    }

    function test_Deposit_OnlyDepositor() public {
        vm.prank(carol);
        vm.expectRevert();
        adapter.depositYield(1000 * U, 0, "cid");
    }

    /// A subsidy epoch requires SOME eligible CatA supply to exist, or the
    /// funds would be permanently stranded with no possible claimant.
    function test_Deposit_NonzeroSubsidyRevertsWithNoEligibleCatA() public {
        vm.startPrank(admin);
        GobiToken freshGobi = new GobiToken(admin, sablier);
        Adapter freshAdapter = new Adapter(admin, address(usdt), address(freshGobi));
        freshGobi.grantRole(freshGobi.SNAPSHOT_ROLE(), address(freshAdapter));
        freshAdapter.grantRole(freshAdapter.DEPOSITOR_ROLE(), distributor);
        freshGobi.transfer(carol, 100 * G); // give base supply a nonzero eligible amount
        freshAdapter.addExclusion(admin);
        vm.stopPrank();
        vm.prank(distributor);
        usdt.approve(address(freshAdapter), type(uint256).max); // approve THIS adapter specifically
        vm.prank(distributor);
        vm.expectRevert(bytes("Adapter: No eligible CategoryA supply"));
        freshAdapter.depositYield(1000 * U, 500 * U, "cid0");
    }

    function test_Deposit_ZeroSubsidyNeverRequiresCatASupply() public {
        vm.startPrank(admin);
        GobiToken freshGobi = new GobiToken(admin, sablier);
        Adapter freshAdapter = new Adapter(admin, address(usdt), address(freshGobi));
        freshGobi.grantRole(freshGobi.SNAPSHOT_ROLE(), address(freshAdapter));
        freshAdapter.grantRole(freshAdapter.DEPOSITOR_ROLE(), distributor);
        freshGobi.transfer(carol, 100 * G);
        freshAdapter.addExclusion(admin);
        vm.stopPrank();
        vm.prank(distributor);
        usdt.approve(address(freshAdapter), type(uint256).max); // the missing line
        vm.prank(distributor);
        freshAdapter.depositYield(1000 * U, 0, "cid0"); // should not revert
    }

    function test_Deposit_PullsExactAmountPlusSubsidy() public {
        _deposit(1000 * U, 500 * U, "cid0");
        assertEq(usdt.balanceOf(address(adapter)), 1500 * U);
        assertEq(adapter.totalDeposited(), 1500 * U);
    }

    function test_Deposit_MultipleEpochsIncrementId() public {
        _deposit(100 * U, 0, "a");
        _deposit(200 * U, 0, "b");
        assertEq(adapter.currentEpochId(), 2);
    }

    function test_Deposit_EmitsEvent() public {
        vm.expectEmit(true, false, false, true, address(adapter));
        emit Adapter.YieldDeposited(0, 1000 * U, 500 * U, 1, 1000 * G, 200 * G, "cid0");
        _deposit(1000 * U, 500 * U, "cid0");
    }

    // =================================================================
    // 4. CLAIM — base yield (full balance, regardless of source)
    // =================================================================

    /// Base yield uses FULL balance -- ordinary public holders and
    /// Sablier-derived investors are treated identically here.
    function test_Claim_BaseYield_UsesFullBalance() public {
        _deposit(1000 * U, 0, "cid0");
        uint256 expAlice = (1000 * U * 100 * G) / (1000 * G);
        uint256 expCarol = (1000 * U * 800 * G) / (1000 * G);
        assertEq(adapter.claimableWallet(0, alice), expAlice);
        assertEq(adapter.claimableWallet(0, carol), expCarol);
        _claim(alice, 0);
        _claim(carol, 0);
        assertEq(usdt.balanceOf(alice), expAlice);
        assertEq(usdt.balanceOf(carol), expCarol);
    }

    function test_Claim_ZeroBalanceGetsNothing() public {
        _deposit(1000 * U, 0, "cid0");
        vm.prank(rescuer);
        vm.expectRevert(bytes("Adapter: No claimable yield available"));
        adapter.claimWallet(_ids(0));
    }

    function test_Claim_NoDoubleClaim() public {
        _deposit(1000 * U, 0, "cid0");
        vm.startPrank(alice);
        adapter.claimWallet(_ids(0));
        vm.expectRevert(bytes("Adapter: No claimable yield available"));
        adapter.claimWallet(_ids(0));
        vm.stopPrank();
    }

    /// Passing the SAME epoch id multiple times in one call must not pay
    /// out more than once -- the claimedWallet flag is checked per-id
    /// inside the loop, so the second/third occurrence is silently skipped.
    function test_Claim_DuplicateEpochIdInSingleCall_NoDoublePayout() public {
        _deposit(1000 * U, 0, "cid0");
        uint256[] memory ids = new uint256[](3);
        ids[0] = 0;
        ids[1] = 0;
        ids[2] = 0;
        uint256 expected = (1000 * U * 100 * G) / (1000 * G);
        vm.prank(alice);
        adapter.claimWallet(ids);
        assertEq(usdt.balanceOf(alice), expected, "paid exactly once despite 3x duplicate id");
    }

    function test_Claim_ExcludedWalletCannotClaim() public {
        _deposit(1000 * U, 0, "cid0");
        vm.prank(admin);
        vm.expectRevert(bytes("Adapter: No claimable yield available"));
        adapter.claimWallet(_ids(0));
    }

    function test_Claim_NonExistentEpochReverts() public {
        _deposit(1000 * U, 0, "cid0");
        vm.prank(alice);
        vm.expectRevert(bytes("Adapter: Non-existent epoch"));
        adapter.claimWallet(_ids(99));
    }

    function test_Claim_MultipleEpochsInOneCall() public {
        _deposit(1000 * U, 0, "cid0");
        _deposit(500 * U, 0, "cid1");
        uint256 exp0 = (1000 * U * 100 * G) / (1000 * G);
        uint256 exp1 = (500 * U * 100 * G) / (1000 * G);
        vm.prank(alice);
        adapter.claimWallet(_ids2(0, 1));
        assertEq(usdt.balanceOf(alice), exp0 + exp1);
    }

    function test_Invariant_ClaimsNeverExceedDeposit() public {
        _deposit(1000 * U, 0, "cid0");
        _claim(alice, 0);
        _claim(bob, 0);
        _claim(carol, 0);
        uint256 paid = usdt.balanceOf(alice) + usdt.balanceOf(bob) + usdt.balanceOf(carol);
        assertLe(paid, 1000 * U);
        assertLt(1000 * U - paid, 5, "only integer-division dust remains");
    }

    // =================================================================
    // 5. CLAIM — subsidy (Category A-eligible amount only)
    // =================================================================

    /// The subsidy pays ONLY on the eligible (Sablier-sourced) amount --
    /// carol, an ordinary public holder, gets base yield but zero subsidy.
    function test_Claim_Subsidy_OnlyEligibleWalletsReceiveIt() public {
        _deposit(1000 * U, 500 * U, "cid0");
        uint256 aliceBase = (1000 * U * 100 * G) / (1000 * G);
        uint256 aliceSub = (500 * U * 100 * G) / (200 * G);
        assertEq(adapter.claimableWallet(0, alice), aliceBase + aliceSub);
        uint256 carolBase = (1000 * U * 800 * G) / (1000 * G);
        assertEq(adapter.claimableWallet(0, carol), carolBase, "no subsidy for carol");
    }

    function test_Claim_Subsidy_FullyDistributed_NoStranding() public {
        _deposit(1000 * U, 500 * U, "cid0");
        _claim(alice, 0);
        _claim(bob, 0);
        _claim(carol, 0);
        uint256 paid = usdt.balanceOf(alice) + usdt.balanceOf(bob) + usdt.balanceOf(carol);
        assertLe(paid, 1500 * U);
        assertLt(1500 * U - paid, 5, "subsidy fully distributed, only dust remains");
    }

    /// THE central scenario: alice holds 800 tokens from Sablier (genuine
    /// vest) plus 200 from an ordinary transfer. Her FULL 1000 earns base
    /// yield; only her 800 eligible tokens draw subsidy.
    function test_Claim_MixedBalance_SplitsCorrectly() public {
        _vestFromSablier(alice, 700 * G); // alice: 100(setUp)+700 = 800 eligible
        vm.prank(carol);
        gobi.transfer(alice, 200 * G); // + 200 ordinary, non-eligible
        assertEq(gobi.balanceOf(alice), 1000 * G);
        assertEq(gobi.categoryAEligibleBalance(alice), 800 * G);

        // eligible CatA supply now: alice800 + bob100 = 900
        // base supply now: alice1000 + bob100 + carol600(sent 200 away) = 1700
        _deposit(900 * U, 900 * U, "cid0");
        (,,, uint256 denom, uint256 catADenom,,) = adapter.epochs(0);
        assertEq(denom, 1700 * G);
        assertEq(catADenom, 900 * G);

        uint256 aliceBase = (900 * U * 1000 * G) / denom; // full 1000 balance
        uint256 aliceSub = (900 * U * 800 * G) / catADenom; // only 800 eligible
        assertEq(adapter.claimableWallet(0, alice), aliceBase + aliceSub);

        _claim(alice, 0);
        _claim(bob, 0);
        _claim(carol, 0);
        uint256 paid = usdt.balanceOf(alice) + usdt.balanceOf(bob) + usdt.balanceOf(carol);
        assertLe(paid, 1800 * U, "solvent: base+subsidy claims never exceed deposit");
    }

    /// Dust-sized eligible balance: a wallet with 1 wei of genuine vested
    /// tokens gets a subsidy that rounds to zero -- must be skipped
    /// gracefully, not revert the whole claim.
    function test_Claim_DustEligibleBalance_RoundsToZeroGracefully() public {
        _vestFromSablier(dust, 1); // 1 wei of genuine vesting
        _deposit(1000 * U, 500 * U, "cid0");
        assertEq(adapter.claimableWallet(0, dust), 0);
        vm.prank(dust);
        vm.expectRevert(bytes("Adapter: No claimable yield available"));
        adapter.claimWallet(_ids(0));
    }

    // =================================================================
    // 6. LOCKED TOKENS STILL EARN BASE YIELD
    // =================================================================

    /// A wallet holding locked, eligible tokens (cannot currently transfer
    /// them) still earns full base yield on them -- the lock is purely a
    /// resale restriction, never a yield-eligibility restriction.
    function test_LockedTokens_StillEarnBaseYield() public {
        assertTrue(gobi.lockupActive());
        vm.prank(alice);
        vm.expectRevert(bytes("SFA Section 276 Lockup: Category A transfers are locked"));
        gobi.transfer(carol, 1 * G); // confirm she's genuinely locked right now

        _deposit(1000 * U, 0, "cid0");
        uint256 expected = (1000 * U * 100 * G) / (1000 * G);
        assertEq(adapter.claimableWallet(0, alice), expected, "locked tokens earn full base yield");
        _claim(alice, 0);
        assertEq(usdt.balanceOf(alice), expected);

        // still locked after claiming -- claiming never lifts the restriction
        vm.prank(alice);
        vm.expectRevert(bytes("SFA Section 276 Lockup: Category A transfers are locked"));
        gobi.transfer(carol, 1 * G);
    }

    // =================================================================
    // 7. HISTORICAL FREEZE
    // =================================================================

    /// Spending eligible balance AFTER a subsidy epoch is funded must not
    /// change what that past epoch pays -- the Adapter reads the eligible
    /// AMOUNT as of the epoch's own snapshot, never the live value.
    function test_SnapshotFrozen_SpendingAfterDepositDoesntAffectPastEpoch() public {
        _deposit(1000 * U, 500 * U, "cid0"); // alice=100 eligible at this snapshot
        vm.warp(TGE + 180 days); // expire so alice CAN spend
        vm.prank(alice);
        gobi.transfer(carol, 100 * G); // spends all her eligible balance AFTER the deposit

        uint256 aliceSub = (500 * U * 100 * G) / (200 * G);
        uint256 aliceBase = (1000 * U * 100 * G) / (1000 * G);
        assertEq(adapter.claimableWallet(0, alice), aliceBase + aliceSub, "epoch 0 unaffected by later spending");
    }

    /// A wallet that RECEIVES a genuine vest AFTER an epoch was funded
    /// gets no retroactive subsidy for that already-closed epoch.
    function test_SnapshotFrozen_LaterVestDoesntRetroactivelyQualify() public {
        _deposit(1000 * U, 500 * U, "cid0"); // carol has zero eligible balance here
        _vestFromSablier(carol, 50 * G); // she genuinely vests AFTER the deposit
        uint256 carolBase = (1000 * U * 800 * G) / (1000 * G);
        assertEq(adapter.claimableWallet(0, carol), carolBase, "no retroactive subsidy for epoch 0");
    }

    // =================================================================
    // 8. EXCLUSION FREEZE ACROSS EPOCHS
    // =================================================================

    function test_Freeze_UnexcludedCannotClaimPastEpoch() public {
        _deposit(1000 * U, 0, "cid0");
        vm.prank(admin);
        adapter.removeExclusion(admin);
        vm.prank(admin);
        vm.expectRevert(bytes("Adapter: No claimable yield available"));
        adapter.claimWallet(_ids(0));
    }

    function test_Freeze_IncludedAffectsOnlyFutureEpochs() public {
        _deposit(1000 * U, 0, "cid0");
        vm.prank(admin);
        adapter.removeExclusion(admin);
        _deposit(1000 * U, 0, "cid1");
        assertTrue(adapter.claimableWallet(1, admin) > 0);
        assertEq(adapter.claimableWallet(0, admin), 0);
    }

    // =================================================================
    // 9. RECOVERY: sweepExcess / rescueToken
    // =================================================================

    function test_Sweep_RevertsRightAfterDeposit() public {
        _deposit(1000 * U, 0, "cid0");
        vm.prank(admin);
        vm.expectRevert(bytes("Adapter: No excess to sweep"));
        adapter.sweepExcess(rescuer);
    }

    function test_Sweep_RevertsWhileAnyoneOwed() public {
        _deposit(1000 * U, 0, "cid0");
        _claim(alice, 0);
        vm.prank(admin);
        vm.expectRevert(bytes("Adapter: No excess to sweep"));
        adapter.sweepExcess(rescuer);
    }

    function test_Sweep_RecoversDirectlySentFunds() public {
        _deposit(1000 * U, 0, "cid0");
        usdt.mint(address(adapter), 250 * U);
        vm.prank(admin);
        adapter.sweepExcess(rescuer);
        assertEq(usdt.balanceOf(rescuer), 250 * U);
        assertEq(usdt.balanceOf(address(adapter)), 1000 * U, "owed balance untouched");
    }

    function test_Sweep_CannotBeCalledTwiceToDrain() public {
        _deposit(1000 * U, 0, "cid0");
        usdt.mint(address(adapter), 100 * U);
        vm.prank(admin);
        adapter.sweepExcess(rescuer);
        vm.prank(admin);
        vm.expectRevert(bytes("Adapter: No excess to sweep"));
        adapter.sweepExcess(rescuer);
    }

    function test_Sweep_OnlyAdmin() public {
        _deposit(1000 * U, 0, "cid0");
        usdt.mint(address(adapter), 10 * U);
        vm.prank(distributor);
        vm.expectRevert();
        adapter.sweepExcess(rescuer);
    }

    function test_Rescue_BlockedFromYieldAsset() public {
        vm.prank(admin);
        vm.expectRevert(bytes("Adapter: Use sweepExcess"));
        adapter.rescueToken(address(usdt), rescuer, 1);
    }

    function test_Rescue_RecoversForeignToken() public {
        AdapterMockForeign frn = new AdapterMockForeign();
        frn.mint(address(adapter), 5 ether);
        vm.prank(admin);
        adapter.rescueToken(address(frn), rescuer, 5 ether);
        assertEq(frn.balanceOf(rescuer), 5 ether);
    }

    function test_Rescue_OnlyAdmin() public {
        AdapterMockForeign frn = new AdapterMockForeign();
        frn.mint(address(adapter), 1 ether);
        vm.prank(distributor);
        vm.expectRevert();
        adapter.rescueToken(address(frn), rescuer, 1 ether);
    }

    // =================================================================
    // 10. VIEWS
    // =================================================================

    function test_Liability_TracksAcrossDepositsAndClaims() public {
        assertEq(adapter.outstandingLiability(), 0);
        _deposit(1000 * U, 500 * U, "cid0");
        assertEq(adapter.outstandingLiability(), 1500 * U);
        _claim(alice, 0);
        assertEq(adapter.outstandingLiability(), 1500 * U - usdt.balanceOf(alice));
    }

    function test_ClaimableView_MatchesActualClaim_AcrossMultipleEpochs() public {
        _deposit(1000 * U, 300 * U, "cid0");
        _deposit(2000 * U, 400 * U, "cid1");
        uint256 predicted = adapter.claimableWallet(0, alice) + adapter.claimableWallet(1, alice);
        vm.prank(alice);
        adapter.claimWallet(_ids2(0, 1));
        assertEq(usdt.balanceOf(alice), predicted);
    }

    // =================================================================
    // 11. CLAIM WINDOW / RECLAIM
    // =================================================================

    /// Default claim window is 365 days.
    function test_ClaimWindow_DefaultIsOneYear() public view {
        assertEq(adapter.claimWindow(), 365 days);
    }

    /// Admin can update the window.
    function test_ClaimWindow_AdminCanUpdate() public {
        vm.prank(admin);
        adapter.setClaimWindow(180 days);
        assertEq(adapter.claimWindow(), 180 days);
    }

    /// Non-admin cannot update the window.
    function test_ClaimWindow_OnlyAdmin() public {
        vm.prank(distributor);
        vm.expectRevert();
        adapter.setClaimWindow(180 days);
    }

    /// Cannot set the window below the 30-day floor.
    function test_ClaimWindow_CannotGoBelowFloor() public {
        vm.prank(admin);
        vm.expectRevert(bytes("Adapter: Claim window too short"));
        adapter.setClaimWindow(29 days);
    }

    /// Exactly the floor value is allowed.
    function test_ClaimWindow_ExactlyAtFloor_Succeeds() public {
        vm.prank(admin);
        adapter.setClaimWindow(30 days);
        assertEq(adapter.claimWindow(), 30 days);
    }

    /// Cannot reclaim before the deadline has passed.
    function test_Reclaim_RevertsBeforeDeadline() public {
        _deposit(1000 * U, 0, "cid0");
        vm.prank(admin);
        vm.expectRevert(bytes("Adapter: Claim window still open"));
        adapter.reclaimExpired(0, treasury);
    }

    /// The core scenario: a wallet that never claims (dead wallet, lost
    /// key, DEX pool) has its share correctly returned to treasury once
    /// the window passes, without touching what others are still owed.
    function test_Reclaim_DeadWalletShareReturnsToTreasury() public {
        _deposit(1000 * U, 0, "cid0");
        _claim(bob, 0); // bob claims his share
        _claim(carol, 0); // carol claims hers
        // alice NEVER claims -- simulating a lost key / dead wallet

        uint256 aliceShare = (1000 * U * 100 * G) / (1000 * G);
        uint256 claimedSoFar = usdt.balanceOf(bob) + usdt.balanceOf(carol);
        uint256 expectedUnclaimed = 1000 * U - claimedSoFar;
        assertEq(expectedUnclaimed, aliceShare, "only alice's share remains unclaimed");

        vm.warp(adapter.epochDeadline(0)); // exactly at the soft deadline

        vm.prank(admin);
        adapter.reclaimExpired(0, treasury);
        assertEq(usdt.balanceOf(treasury), expectedUnclaimed, "exactly alice's unclaimed share, nothing more");
    }

    /// Soft deadline: a legitimate claimant can STILL claim after the
    /// nominal deadline has passed, right up until reclaim actually fires.
    function test_Reclaim_SoftDeadline_LateClaimStillWorksBeforeReclaim() public {
        _deposit(1000 * U, 0, "cid0");
        vm.warp(adapter.epochDeadline(0) + 10 days); // well past the nominal deadline

        // alice can still claim -- reclaim hasn't been triggered yet
        uint256 expected = (1000 * U * 100 * G) / (1000 * G);
        _claim(alice, 0);
        assertEq(usdt.balanceOf(alice), expected);
    }

    /// Once reclaimed, a late claimant can no longer claim that epoch --
    /// the money has already left the contract.
    function test_Reclaim_ClosesEpochToFurtherClaims() public {
        _deposit(1000 * U, 0, "cid0");
        _claim(bob, 0);
        _claim(carol, 0);
        vm.warp(adapter.epochDeadline(0));
        vm.prank(admin);
        adapter.reclaimExpired(0, treasury);

        // alice arrives too late -- epoch is now closed
        assertEq(adapter.claimableWallet(0, alice), 0);
        vm.prank(alice);
        vm.expectRevert(bytes("Adapter: No claimable yield available"));
        adapter.claimWallet(_ids(0));
    }

    /// Reclaiming reduces totalDeposited/outstandingLiability so the
    /// contract's accounting doesn't stay permanently inflated by money
    /// that will never be claimed.
    function test_Reclaim_ReducesOutstandingLiability() public {
        _deposit(1000 * U, 0, "cid0");
        _claim(bob, 0);
        _claim(carol, 0);
        uint256 aliceShare = (1000 * U * 100 * G) / (1000 * G);
        assertEq(adapter.outstandingLiability(), aliceShare);

        vm.warp(adapter.epochDeadline(0));
        vm.prank(admin);
        adapter.reclaimExpired(0, treasury);
        assertEq(adapter.outstandingLiability(), 0);
    }

    /// Cannot reclaim the same epoch twice.
    function test_Reclaim_CannotBeCalledTwice() public {
        _deposit(1000 * U, 0, "cid0");
        vm.warp(adapter.epochDeadline(0));
        vm.prank(admin);
        adapter.reclaimExpired(0, treasury);
        vm.prank(admin);
        vm.expectRevert(bytes("Adapter: Already reclaimed"));
        adapter.reclaimExpired(0, treasury);
    }

    /// If everyone already claimed, there's nothing left to reclaim.
    function test_Reclaim_RevertsIfNothingUnclaimed() public {
        _deposit(1000 * U, 0, "cid0");
        _claim(alice, 0);
        _claim(bob, 0);
        _claim(carol, 0);
        vm.warp(adapter.epochDeadline(0));
        vm.prank(admin);
        vm.expectRevert(bytes("Adapter: Nothing unclaimed for this epoch"));
        adapter.reclaimExpired(0, treasury);
    }

    /// Only admin can reclaim.
    function test_Reclaim_OnlyAdmin() public {
        _deposit(1000 * U, 0, "cid0");
        vm.warp(adapter.epochDeadline(0));
        vm.prank(distributor);
        vm.expectRevert();
        adapter.reclaimExpired(0, treasury);
    }

    /// Reclaim rejects the zero address as recipient.
    function test_Reclaim_RevertsZeroRecipient() public {
        _deposit(1000 * U, 0, "cid0");
        vm.warp(adapter.epochDeadline(0));
        vm.prank(admin);
        vm.expectRevert(bytes("Adapter: Recipient zero address"));
        adapter.reclaimExpired(0, address(0));
    }

    /// Reclaiming one epoch doesn't touch a different, still-open epoch.
    function test_Reclaim_OnlyAffectsTheSpecifiedEpoch() public {
        _deposit(1000 * U, 0, "cid0");
        _deposit(500 * U, 0, "cid1");
        vm.warp(adapter.epochDeadline(0));
        vm.prank(admin);
        adapter.reclaimExpired(0, treasury);

        // epoch 1 is untouched and still claimable
        assertGt(adapter.claimableWallet(1, alice), 0);
        _claim(alice, 1);
        assertGt(usdt.balanceOf(alice), 0);
    }

    /// Emits the event with the correct amount.
    function test_Reclaim_EmitsEvent() public {
        _deposit(1000 * U, 0, "cid0");
        vm.warp(adapter.epochDeadline(0));
        vm.expectEmit(true, true, false, true, address(adapter));
        emit Adapter.ExpiredReclaimed(0, treasury, 1000 * U);
        vm.prank(admin);
        adapter.reclaimExpired(0, treasury);
    }

    /// Subsidy portion of an unclaimed share is also correctly reclaimed,
    /// not just the base yield.
    function test_Reclaim_IncludesUnclaimedSubsidy() public {
        _deposit(1000 * U, 500 * U, "cid0");
        _claim(bob, 0);
        _claim(carol, 0);
        uint256 aliceExpected = (1000 * U * 100 * G) / (1000 * G) + (500 * U * 100 * G) / (200 * G);
        vm.warp(adapter.epochDeadline(0));
        vm.prank(admin);
        adapter.reclaimExpired(0, treasury);
        assertEq(usdt.balanceOf(treasury), aliceExpected);
    }

    // =================================================================
    // 12. REENTRANCY / MALICIOUS TOKEN ATTACKS
    // =================================================================

    /// A malicious yieldAsset that tries to re-enter claimWallet mid-payout
    /// must be blocked by nonReentrant -- the claimant is paid exactly once.
    function test_Attack_ReentrantClaimWallet_BlockedByGuard() public {
        vm.startPrank(admin);
        GobiToken tok = new GobiToken(admin, sablier);
        ReentrantMockUSDT evil = new ReentrantMockUSDT();
        Adapter atk = new Adapter(admin, address(evil), address(tok));
        tok.grantRole(tok.SNAPSHOT_ROLE(), address(atk));
        atk.grantRole(atk.DEPOSITOR_ROLE(), distributor);
        tok.transfer(alice, 100 * G);
        atk.addExclusion(admin);
        vm.stopPrank();
        evil.mint(distributor, 1_000_000 * U);
        vm.prank(distributor);
        evil.approve(address(atk), type(uint256).max);
        vm.prank(distributor);
        atk.depositYield(1000 * U, 0, "cid0");

        uint256[] memory ids = _ids(0);
        evil.armClaimReentry(address(atk), ids);
        vm.prank(alice);
        atk.claimWallet(ids);
        uint256 expected = (1000 * U * 100 * G) / (100 * G);
        assertEq(evil.balanceOf(alice), expected, "paid exactly once despite reentry attempt");
    }

    /// Same guard, proven against sweepExcess: a reentrant call during the
    /// sweep transfer must not allow a second sweep in the same transaction.
    function test_Attack_ReentrantSweepExcess_BlockedByGuard() public {
        vm.startPrank(admin);
        GobiToken tok = new GobiToken(admin, sablier);
        ReentrantMockUSDT evil = new ReentrantMockUSDT();
        Adapter atk = new Adapter(admin, address(evil), address(tok));
        tok.grantRole(tok.SNAPSHOT_ROLE(), address(atk));
        atk.grantRole(atk.DEPOSITOR_ROLE(), distributor);
        tok.transfer(alice, 100 * G);
        atk.addExclusion(admin);
        vm.stopPrank();
        evil.mint(distributor, 1_000_000 * U);
        vm.prank(distributor);
        evil.approve(address(atk), type(uint256).max);
        vm.prank(distributor);
        atk.depositYield(1000 * U, 0, "cid0");
        evil.mint(address(atk), 50 * U);
        evil.armSweepReentry(address(atk));

        vm.prank(admin);
        atk.sweepExcess(rescuer);
        assertEq(evil.balanceOf(rescuer), 50 * U, "swept exactly once, not double-drained");
    }

    /// A non-compliant ERC20 (returns false instead of reverting) must
    /// cause depositYield to revert via SafeERC20 -- never silently
    /// record a deposit that was never actually paid in.
    function test_Attack_NonCompliantTokenReturningFalse_DepositReverts() public {
        vm.startPrank(admin);
        GobiToken tok = new GobiToken(admin, sablier);
        FalseReturningMockUSDT bad = new FalseReturningMockUSDT();
        Adapter atk = new Adapter(admin, address(bad), address(tok));
        tok.grantRole(tok.SNAPSHOT_ROLE(), address(atk));
        atk.grantRole(atk.DEPOSITOR_ROLE(), distributor);
        tok.transfer(alice, 100 * G);
        vm.stopPrank();
        bad.mint(distributor, 1000 * U);
        vm.prank(distributor);
        bad.approve(address(atk), type(uint256).max);
        vm.prank(distributor);
        vm.expectRevert();
        atk.depositYield(1000 * U, 0, "cid0");
        assertEq(atk.currentEpochId(), 0, "no phantom epoch created");
        assertEq(atk.totalDeposited(), 0, "no phantom liability recorded");
    }

    // =================================================================
    // 13. FUZZ
    // =================================================================

    /// For any base+subsidy amounts, total claims across all holders can
    /// never exceed what was actually deposited.
    function testFuzz_ClaimsNeverExceedDeposit(uint96 amount, uint96 subsidy) public {
        amount = uint96(bound(amount, 1, 1_000_000 * U));
        subsidy = uint96(bound(subsidy, 0, 1_000_000 * U));
        usdt.mint(distributor, uint256(amount) + subsidy);
        _deposit(amount, subsidy, "fuzz");
        uint256 id = adapter.currentEpochId() - 1;
        address[3] memory who = [alice, bob, carol];
        uint256 paid = 0;
        for (uint256 i = 0; i < 3; i++) {
            uint256 c = adapter.claimableWallet(id, who[i]);
            if (c > 0) {
                _claim(who[i], id);
                paid += c;
            }
        }
        assertLe(paid, uint256(amount) + subsidy);
    }

    /// For any split between eligible (Sablier) and ordinary balance in
    /// alice's wallet, her eligible amount never exceeds her real balance,
    /// and her subsidy claim is always bounded by the subsidy pool.
    function testFuzz_MixedBalance_SubsidyNeverExceedsEligibleShare(uint96 vestAmt, uint96 ordinaryAmt) public {
        vestAmt = uint96(bound(vestAmt, 0, 500 * G));
        ordinaryAmt = uint96(bound(ordinaryAmt, 0, 500 * G));
        if (vestAmt > 0) _vestFromSablier(alice, vestAmt);
        if (ordinaryAmt > 0) {
            vm.prank(carol);
            gobi.transfer(alice, ordinaryAmt);
        }
        assertLe(gobi.categoryAEligibleBalance(alice), gobi.balanceOf(alice));

        _deposit(1000 * U, 500 * U, "fuzz");
        uint256 claimable = adapter.claimableWallet(adapter.currentEpochId() - 1, alice);
        // sanity: her claim can never exceed base(all her balance) + subsidy(entire pool)
        assertLe(claimable, 1500 * U);
    }
}
