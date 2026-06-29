// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "openzeppelin/token/ERC20/ERC20.sol";
import "../src/adapter/adapter.sol";
import "../src/gobitoken.sol"; // real production token

contract MockUSDT is ERC20 {
    constructor() ERC20("Tether USD", "USDT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

// Arbitrary foreign token for rescueToken tests
contract MockForeign is ERC20 {
    constructor() ERC20("Foreign", "FRN") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract AdapterTest is Test {
    Adapter internal adapter;
    GobiToken internal gobi;
    MockUSDT internal usdt;

    address internal admin = makeAddr("admin");
    address internal distributor = makeAddr("distributor");
    address internal holderA = makeAddr("holderA");
    address internal holderB = makeAddr("holderB");
    address internal treasury = makeAddr("treasury");
    address internal sablier = makeAddr("sablier");
    address internal rescuer = makeAddr("rescuer");

    uint256 internal constant G = 1e18;
    uint256 internal constant USDT_UNIT = 1e6;

    bytes32 internal SNAPSHOT_ROLE;
    bytes32 internal DEPOSITOR_ROLE;
    bytes32 internal DEFAULT_ADMIN_ROLE_ = 0x00;

    function setUp() public {
        vm.startPrank(admin);
        gobi = new GobiToken(admin);
        usdt = new MockUSDT();
        adapter = new Adapter(admin, address(usdt), address(gobi), sablier);

        SNAPSHOT_ROLE = gobi.SNAPSHOT_ROLE();
        DEPOSITOR_ROLE = adapter.DEPOSITOR_ROLE();

        gobi.grantRole(SNAPSHOT_ROLE, address(adapter)); // adapter takes snapshots
        adapter.grantRole(DEPOSITOR_ROLE, distributor);

        gobi.transfer(holderA, 100 * G);
        gobi.transfer(holderB, 200 * G);
        gobi.transfer(treasury, 700 * G);

        adapter.addExclusion(admin); // multisig holds the bulk
        adapter.addExclusion(treasury);
        vm.stopPrank();

        usdt.mint(distributor, 1_000_000 * USDT_UNIT);
        vm.prank(distributor);
        usdt.approve(address(adapter), type(uint256).max);
    }

    // --- helpers ---
    function _deposit(uint256 amount, string memory cid) internal {
        vm.prank(distributor);
        adapter.depositYield(amount, cid);
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = a;
    }

    function _claim(address who, uint256 id) internal {
        vm.prank(who);
        adapter.claimWallet(_ids(id));
    }

    // ===== Deployment / wiring =====

    function test_DeploymentState() public {
        assertEq(address(adapter.yieldAsset()), address(usdt));
        assertEq(address(adapter.gobiToken()), address(gobi));
        assertTrue(adapter.hasRole(DEFAULT_ADMIN_ROLE_, admin));
        assertTrue(adapter.isExcluded(sablier));
        assertEq(adapter.currentEpochId(), 0);
    }

    function test_SnapshotRoleMustBeOnAdapter() public {
        vm.startPrank(admin);
        gobi.revokeRole(SNAPSHOT_ROLE, address(adapter));
        gobi.grantRole(SNAPSHOT_ROLE, distributor);
        vm.stopPrank();
        vm.prank(distributor);
        vm.expectRevert();
        adapter.depositYield(1000 * USDT_UNIT, "cid");
        vm.prank(admin);
        gobi.grantRole(SNAPSHOT_ROLE, address(adapter));
        _deposit(1000 * USDT_UNIT, "cid");
        assertEq(adapter.currentEpochId(), 1);
    }

    // ===== Deposit: derived denominator + exclusion freeze =====

    function test_DepositDerivesDenominator() public {
        _deposit(1000 * USDT_UNIT, "cid0");
        (, uint256 amt, uint256 denom,) = adapter.epochs(0);
        assertEq(denom, 300 * G);
        assertEq(amt, 1000 * USDT_UNIT);
    }

    function test_DepositFreezesExclusion() public {
        _deposit(1000 * USDT_UNIT, "cid0");
        assertTrue(adapter.epochExcluded(0, treasury));
        assertTrue(adapter.epochExcluded(0, admin));
        assertTrue(adapter.epochExcluded(0, sablier));
        assertFalse(adapter.epochExcluded(0, holderA));
    }

    function test_OnlyDepositorCanDeposit() public {
        vm.prank(holderA);
        vm.expectRevert();
        adapter.depositYield(1000 * USDT_UNIT, "cid");
    }

    function test_DepositRejectsZeroAndEmptyCid() public {
        vm.startPrank(distributor);
        vm.expectRevert(bytes("Adapter: Deposit must exceed zero"));
        adapter.depositYield(0, "cid");
        vm.expectRevert(bytes("Adapter: IPFS hash cannot be empty"));
        adapter.depositYield(1000 * USDT_UNIT, "");
        vm.stopPrank();
    }

    // ===== Claims: math + solvency invariant =====

    function test_ClaimPayoutMath() public {
        _deposit(1000 * USDT_UNIT, "cid0");
        uint256 expA = (1000 * USDT_UNIT * 100 * G) / (300 * G);
        uint256 expB = (1000 * USDT_UNIT * 200 * G) / (300 * G);
        assertEq(adapter.claimableWallet(0, holderA), expA);
        _claim(holderA, 0);
        _claim(holderB, 0);
        assertEq(usdt.balanceOf(holderA), expA);
        assertEq(usdt.balanceOf(holderB), expB);
    }

    function test_Invariant_ClaimsNeverExceedDeposit() public {
        uint256 amount = 1000 * USDT_UNIT;
        _deposit(amount, "cid0");
        _claim(holderA, 0);
        _claim(holderB, 0);
        uint256 paidOut = usdt.balanceOf(holderA) + usdt.balanceOf(holderB);
        assertLe(paidOut, amount);
        assertEq(usdt.balanceOf(address(adapter)), amount - paidOut);
        assertLt(amount - paidOut, 1 * USDT_UNIT);
    }

    function test_ZeroBalanceHolderGetsNothing() public {
        _deposit(1000 * USDT_UNIT, "cid0");
        assertEq(adapter.claimableWallet(0, rescuer), 0);
        vm.prank(rescuer);
        vm.expectRevert(bytes("Adapter: No claimable yield available"));
        adapter.claimWallet(_ids(0));
    }

    function test_NoDoubleClaim() public {
        _deposit(1000 * USDT_UNIT, "cid0");
        vm.startPrank(holderA);
        adapter.claimWallet(_ids(0));
        vm.expectRevert(bytes("Adapter: No claimable yield available"));
        adapter.claimWallet(_ids(0));
        vm.stopPrank();
    }

    function test_EmptyArrayReverts() public {
        _deposit(1000 * USDT_UNIT, "cid0");
        uint256[] memory empty = new uint256[](0);
        vm.prank(holderA);
        vm.expectRevert(bytes("Adapter: No claimable yield available"));
        adapter.claimWallet(empty);
    }

    function test_NonExistentEpochReverts() public {
        _deposit(1000 * USDT_UNIT, "cid0");
        vm.prank(holderA);
        vm.expectRevert(bytes("Adapter: Non-existent epoch"));
        adapter.claimWallet(_ids(99));
    }

    function test_ClaimMultipleEpochsAtOnce() public {
        _deposit(1000 * USDT_UNIT, "cid0");
        _deposit(500 * USDT_UNIT, "cid1");
        uint256[] memory ids = new uint256[](2);
        ids[0] = 0;
        ids[1] = 1;
        uint256 exp0 = (1000 * USDT_UNIT * 100 * G) / (300 * G);
        uint256 exp1 = (500 * USDT_UNIT * 100 * G) / (300 * G);
        vm.prank(holderA);
        adapter.claimWallet(ids);
        assertEq(usdt.balanceOf(holderA), exp0 + exp1);
    }

    // ===== Exclusion freeze across epochs =====

    function test_Freeze_UnexcludedCannotClaimPastEpoch() public {
        _deposit(1000 * USDT_UNIT, "cid0");
        vm.prank(admin);
        adapter.removeExclusion(treasury);
        assertFalse(adapter.isExcluded(treasury));
        assertEq(adapter.claimableWallet(0, treasury), 0);
        vm.prank(treasury);
        vm.expectRevert(bytes("Adapter: No claimable yield available"));
        adapter.claimWallet(_ids(0));
    }

    function test_Freeze_IncludedInFutureEpoch() public {
        _deposit(1000 * USDT_UNIT, "cid0");
        vm.prank(admin);
        adapter.removeExclusion(treasury);
        _deposit(1000 * USDT_UNIT, "cid1");
        (,, uint256 denom1,) = adapter.epochs(1);
        assertEq(denom1, 1000 * G);
        uint256 expT = (1000 * USDT_UNIT * 700 * G) / (1000 * G);
        vm.prank(treasury);
        adapter.claimWallet(_ids(1));
        assertEq(usdt.balanceOf(treasury), expT);
    }

    function test_AddExclusion_Guards() public {
        vm.startPrank(admin);
        vm.expectRevert(bytes("Adapter: Already excluded"));
        adapter.addExclusion(treasury);
        vm.expectRevert(bytes("Adapter: Target zero address"));
        adapter.addExclusion(address(0));
        vm.stopPrank();
        vm.prank(holderA);
        vm.expectRevert();
        adapter.addExclusion(holderB);
    }

    function test_RemoveExclusion_NotExcludedReverts() public {
        vm.prank(admin);
        vm.expectRevert(bytes("Adapter: Not excluded"));
        adapter.removeExclusion(holderA);
    }

    // ===== outstandingLiability accounting =====

    function test_Liability_StartsZero() public {
        assertEq(adapter.outstandingLiability(), 0);
        assertEq(adapter.totalDeposited(), 0);
        assertEq(adapter.totalClaimed(), 0);
    }

    function test_Liability_RisesOnDeposit() public {
        _deposit(1000 * USDT_UNIT, "cid0");
        assertEq(adapter.totalDeposited(), 1000 * USDT_UNIT);
        assertEq(adapter.outstandingLiability(), 1000 * USDT_UNIT);
    }

    function test_Liability_FallsOnClaim() public {
        _deposit(1000 * USDT_UNIT, "cid0");
        _claim(holderA, 0);
        uint256 paidA = usdt.balanceOf(holderA);
        assertEq(adapter.totalClaimed(), paidA);
        assertEq(adapter.outstandingLiability(), 1000 * USDT_UNIT - paidA);
    }

    function test_Liability_AccumulatesAcrossEpochs() public {
        _deposit(1000 * USDT_UNIT, "cid0");
        _deposit(500 * USDT_UNIT, "cid1");
        assertEq(adapter.totalDeposited(), 1500 * USDT_UNIT);
        assertEq(adapter.outstandingLiability(), 1500 * USDT_UNIT);
    }

    // ===== sweepExcess (safe recovery, no drain) =====

    function test_Sweep_RevertsRightAfterDeposit() public {
        _deposit(1000 * USDT_UNIT, "cid0"); // balance == outstanding
        vm.prank(admin);
        vm.expectRevert(bytes("Adapter: No excess to sweep"));
        adapter.sweepExcess(rescuer);
    }

    function test_Sweep_RevertsWhileAnyoneIsOwed() public {
        _deposit(1000 * USDT_UNIT, "cid0");
        _claim(holderA, 0); // holderB still owed
        vm.prank(admin);
        vm.expectRevert(bytes("Adapter: No excess to sweep"));
        adapter.sweepExcess(rescuer);
    }

    function test_Sweep_RevertsOnEmptyContract() public {
        vm.prank(admin);
        vm.expectRevert(bytes("Adapter: No excess to sweep"));
        adapter.sweepExcess(rescuer);
    }

    function test_Sweep_RecoversDirectlySentFunds() public {
        _deposit(1000 * USDT_UNIT, "cid0");
        usdt.mint(address(adapter), 250 * USDT_UNIT); // stray transfer = pure excess
        uint256 before = usdt.balanceOf(rescuer);
        vm.prank(admin);
        adapter.sweepExcess(rescuer);
        assertEq(usdt.balanceOf(rescuer) - before, 250 * USDT_UNIT);
        assertEq(usdt.balanceOf(address(adapter)), 1000 * USDT_UNIT); // owed untouched
    }

    function test_Sweep_OnlyExcessNotOwed_AfterClaims() public {
        _deposit(1000 * USDT_UNIT, "cid0");
        _claim(holderA, 0);
        _claim(holderB, 0);
        usdt.mint(address(adapter), 40 * USDT_UNIT);
        uint256 before = usdt.balanceOf(rescuer);
        vm.prank(admin);
        adapter.sweepExcess(rescuer);
        assertEq(usdt.balanceOf(rescuer) - before, 40 * USDT_UNIT); // dust stays locked
    }

    function test_Sweep_CannotBeCalledTwiceToDrain() public {
        _deposit(1000 * USDT_UNIT, "cid0");
        usdt.mint(address(adapter), 100 * USDT_UNIT);
        vm.prank(admin);
        adapter.sweepExcess(rescuer);
        vm.prank(admin);
        vm.expectRevert(bytes("Adapter: No excess to sweep"));
        adapter.sweepExcess(rescuer);
    }

    function test_Sweep_RevertsZeroRecipient() public {
        _deposit(1000 * USDT_UNIT, "cid0");
        usdt.mint(address(adapter), 10 * USDT_UNIT);
        vm.prank(admin);
        vm.expectRevert(bytes("Adapter: Recipient zero address"));
        adapter.sweepExcess(address(0));
    }

    function test_Sweep_OnlyAdmin() public {
        _deposit(1000 * USDT_UNIT, "cid0");
        usdt.mint(address(adapter), 10 * USDT_UNIT);
        vm.prank(distributor);
        vm.expectRevert();
        adapter.sweepExcess(rescuer);
    }

    function test_Sweep_EmitsEvent() public {
        _deposit(1000 * USDT_UNIT, "cid0");
        usdt.mint(address(adapter), 77 * USDT_UNIT);
        vm.expectEmit(true, false, false, true, address(adapter));
        emit Adapter.ExcessSwept(rescuer, 77 * USDT_UNIT);
        vm.prank(admin);
        adapter.sweepExcess(rescuer);
    }

    // ===== rescueToken (foreign tokens only) =====

    function test_Rescue_RecoversForeignToken() public {
        MockForeign frn = new MockForeign();
        frn.mint(address(adapter), 123 ether);
        vm.prank(admin);
        adapter.rescueToken(address(frn), rescuer, 123 ether);
        assertEq(frn.balanceOf(rescuer), 123 ether);
        assertEq(frn.balanceOf(address(adapter)), 0);
    }

    function test_Rescue_PartialAmount() public {
        MockForeign frn = new MockForeign();
        frn.mint(address(adapter), 100 ether);
        vm.prank(admin);
        adapter.rescueToken(address(frn), rescuer, 30 ether);
        assertEq(frn.balanceOf(rescuer), 30 ether);
        assertEq(frn.balanceOf(address(adapter)), 70 ether);
    }

    function test_Rescue_BlockedFromYieldAsset() public {
        _deposit(1000 * USDT_UNIT, "cid0");
        vm.prank(admin);
        vm.expectRevert(bytes("Adapter: Use sweepExcess"));
        adapter.rescueToken(address(usdt), rescuer, 1);
    }

    function test_Rescue_RevertsZeroRecipient() public {
        MockForeign frn = new MockForeign();
        frn.mint(address(adapter), 1 ether);
        vm.prank(admin);
        vm.expectRevert(bytes("Adapter: Recipient zero address"));
        adapter.rescueToken(address(frn), address(0), 1 ether);
    }

    function test_Rescue_RevertsZeroAmount() public {
        MockForeign frn = new MockForeign();
        frn.mint(address(adapter), 1 ether);
        vm.prank(admin);
        vm.expectRevert(bytes("Adapter: Amount must exceed zero"));
        adapter.rescueToken(address(frn), rescuer, 0);
    }

    function test_Rescue_OnlyAdmin() public {
        MockForeign frn = new MockForeign();
        frn.mint(address(adapter), 1 ether);
        vm.prank(distributor);
        vm.expectRevert();
        adapter.rescueToken(address(frn), rescuer, 1 ether);
    }

    function test_Rescue_EmitsEvent() public {
        MockForeign frn = new MockForeign();
        frn.mint(address(adapter), 5 ether);
        vm.expectEmit(true, true, false, true, address(adapter));
        emit Adapter.TokenRescued(address(frn), rescuer, 5 ether);
        vm.prank(admin);
        adapter.rescueToken(address(frn), rescuer, 5 ether);
    }

    // ===== Fuzz =====

    function testFuzz_ClaimsNeverExceedDeposit(uint96 amount, uint96 balA, uint96 balB) public {
        amount = uint96(bound(amount, 1, 1_000_000 * USDT_UNIT));
        balA = uint96(bound(balA, 1, 100_000 * G));
        balB = uint96(bound(balB, 1, 100_000 * G));
        address fa = makeAddr("fa");
        address fb = makeAddr("fb");
        vm.startPrank(admin);
        gobi.transfer(fa, balA);
        gobi.transfer(fb, balB);
        vm.stopPrank();
        usdt.mint(distributor, amount);
        _deposit(amount, "fuzz");
        uint256 id = adapter.currentEpochId() - 1;
        uint256 before = usdt.balanceOf(address(adapter));
        if (adapter.claimableWallet(id, fa) > 0) {
            vm.prank(fa);
            adapter.claimWallet(_ids(id));
        }
        if (adapter.claimableWallet(id, fb) > 0) {
            vm.prank(fb);
            adapter.claimWallet(_ids(id));
        }
        uint256 paid = before - usdt.balanceOf(address(adapter));
        assertLe(paid, amount);
    }

    function testFuzz_Sweep_NeverTakesOwed(uint96 deposit, uint96 stray) public {
        deposit = uint96(bound(deposit, 1, 500_000 * USDT_UNIT));
        stray = uint96(bound(stray, 0, 500_000 * USDT_UNIT));
        usdt.mint(distributor, deposit);
        vm.prank(distributor);
        adapter.depositYield(deposit, "fuzz");
        if (stray > 0) usdt.mint(address(adapter), stray);
        uint256 owed = adapter.outstandingLiability();
        if (stray == 0) {
            vm.prank(admin);
            vm.expectRevert(bytes("Adapter: No excess to sweep"));
            adapter.sweepExcess(rescuer);
        } else {
            vm.prank(admin);
            adapter.sweepExcess(rescuer);
            assertEq(usdt.balanceOf(rescuer), stray, "swept exactly the stray amount");
        }
        assertGe(usdt.balanceOf(address(adapter)), owed);
    }
}
