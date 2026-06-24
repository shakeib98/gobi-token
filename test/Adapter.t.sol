// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "openzeppelin/token/ERC20/ERC20.sol";
import "../src/adapter/adapter.sol";
import "../src/gobitoken.sol"; // Using your actual production token import

// --- Remaining Mock Configurations for USDT ---
contract MockUSDT is ERC20 {
    constructor() ERC20("Tether USD", "USDT") {}

    function decimals() public pure override returns (uint8) {
        return 6; // Standardizes USDT decimals
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// --- Main Test Suite ---
contract AdapterTest is Test {
    Adapter public adapter;
    GobiToken public gobiToken; // Typed to your actual production contract
    MockUSDT public usdt;

    // Accounts
    address public admin = address(0x1);
    address public depositor = address(0x2);
    address public sablier = address(0x3);
    address public alice = address(0x4);
    address public bob = address(0x5);
    address public charlie = address(0x6);
    address public treasuryWallet = address(0x7);

    // Baseline Constants
    uint256 constant BASE_YIELD_BEARING_SUPPLY = 270_000_000 * 10 ** 18;
    uint256 constant TREASURY_POOL_LIMIT = 130_000_000 * 10 ** 18;

    function setUp() public {
        // 1. Deploy Core Assets
        usdt = new MockUSDT();

        // Deploy your actual GobiToken contract
        gobiToken = new GobiToken(admin);

        // 2. Deploy Target System Adapter
        adapter = new Adapter(
            admin,
            address(usdt),
            address(gobiToken),
            sablier
        );

        // 3. Distribute Initial Gobi Circulating Balances
        vm.startPrank(admin);
        gobiToken.mint(alice, 100_000_000 * 10 ** 18); // 100M GOBI
        gobiToken.mint(bob, 80_000_000 * 10 ** 18); // 80M GOBI
        gobiToken.mint(charlie, 20_000_000 * 10 ** 18); // 20M GOBI

        // Link internal Snapshot authorization engine to our Adapter contract instance
        gobiToken.grantRole(gobiToken.SNAPSHOT_ROLE(), address(adapter));

        // Authorize specialized Depositor role
        adapter.grantRole(adapter.DEPOSITOR_ROLE(), depositor);
        vm.stopPrank();

        // 4. Provision Depositor Liquidity Pools ($1M USDT)
        usdt.mint(depositor, 1_000_000 * 10 ** 6);
    }

    // ==========================================
    // DEPLOYMENT & INITIALIZATION SCENARIOS
    // ==========================================

    function test_InitializationState() public view {
        assertEq(adapter.currentEpochId(), 0);
        assertEq(adapter.yieldBearingSupply(), BASE_YIELD_BEARING_SUPPLY);
        assertTrue(adapter.hasRole(adapter.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(adapter.hasRole(adapter.DEPOSITOR_ROLE(), admin));
    }

    function test_ConstructorRevertsOnZeroAddresses() public {
        vm.expectRevert("Adapter: Admin zero address");
        new Adapter(address(0), address(usdt), address(gobiToken), sablier);

        vm.expectRevert("Adapter: Yield asset zero address");
        new Adapter(admin, address(0), address(gobiToken), sablier);

        vm.expectRevert("Adapter: Gobi zero address");
        new Adapter(admin, address(usdt), address(0), sablier);

        vm.expectRevert("Adapter: Sablier zero address");
        new Adapter(admin, address(usdt), address(gobiToken), address(0));
    }

    // ==========================================
    // SYSTEM EXCLUSION MANAGEMENT SCENARIOS
    // ==========================================

    function test_AdminCanToggleExclusionStatus() public {
        assertFalse(adapter.isExcluded(alice));

        vm.prank(admin);
        adapter.setExclusionStatus(alice, true);
        assertTrue(adapter.isExcluded(alice));

        vm.prank(admin);
        adapter.setExclusionStatus(alice, false);
        assertFalse(adapter.isExcluded(alice));
    }

    function test_ExclusionManagementEnforcesAccessControl() public {
        vm.prank(alice);
        vm.expectRevert();
        adapter.setExclusionStatus(bob, true);
    }

    function test_ExclusionRejectsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert("Adapter: Target zero address");
        adapter.setExclusionStatus(address(0), true);
    }

    // ==========================================
    // TREASURY ADMISSION MECHANICS SCENARIOS
    // ==========================================

    function test_AdmitTreasuryIncrementsCalculatedSupply() public {
        uint256 additionAmount = 50_000_000 * 10 ** 18;

        vm.prank(admin);
        adapter.admitTreasury(treasuryWallet, additionAmount);
        assertEq(
            adapter.yieldBearingSupply(),
            BASE_YIELD_BEARING_SUPPLY + additionAmount
        );
    }
    function test_AdmitTreasuryValidatesInputs() public {
        vm.startPrank(admin);
        vm.expectRevert("Adapter: Holder zero address");
        adapter.admitTreasury(address(0), 10_000_000 * 10 ** 18);

        vm.expectRevert("Adapter: Amount must exceed zero");
        adapter.admitTreasury(treasuryWallet, 0);
        vm.stopPrank();
    }

    // ==========================================
    // MONTH 10: DEPOSIT FIRST YIELD MATH TESTS
    // ==========================================

    function test_DepositFirstYieldCorrectlyExcludesSablierMath() public {
        uint256 lockedAmount = 70_000_000 * 10 ** 18;
        vm.prank(admin);
        gobiToken.transfer(sablier, lockedAmount);

        uint256 intendedMacroBudget = 135_000 * 10 ** 6;

        vm.startPrank(depositor);
        usdt.approve(address(adapter), intendedMacroBudget);
        adapter.depositFirstYield(intendedMacroBudget, "QmFirstYieldHash123");
        vm.stopPrank();

        // Math Verification:
        // yieldBearingSupply = 270,000,000
        // lockedInSablier = 70,000,000
        // activeCirculatingSupply = 200,000,000
        // keptAmount = (135,000 * 200M) / 270M = 100,000 USDT ($100k)

        (
            uint256 snapshotId,
            uint256 totalUsdtAmount,
            uint256 supplyAtSnapshot,

        ) = adapter.epochs(0);

        assertEq(snapshotId, 1);
        assertEq(
            totalUsdtAmount,
            100_000 * 10 ** 6,
            "Kept asset quantity calculation mismatched"
        );
        assertEq(
            supplyAtSnapshot,
            200_000_000 * 10 ** 18,
            "Snapshot accounting denominator mismatched"
        );
        assertEq(usdt.balanceOf(address(adapter)), 100_000 * 10 ** 6);
    }

    function test_FirstYieldIndividualClaimMathStaysIntact() public {
        uint256 lockedAmount = 70_000_000 * 10 ** 18;
        vm.prank(admin);
        gobiToken.transfer(sablier, lockedAmount);

        uint256 intendedMacroBudget = 135_000 * 10 ** 6;

        vm.startPrank(depositor);
        usdt.approve(address(adapter), intendedMacroBudget);
        adapter.depositFirstYield(intendedMacroBudget, "QmFirstYieldHash123");
        vm.stopPrank();

        uint256 claimableAlice = adapter.claimableWallet(0, alice);

        // Expected Math:
        // Payout = (100,000 USDT * 100M) / 200M = 50,000 USDT
        assertEq(
            claimableAlice,
            50_000 * 10 ** 6,
            "Target yield distribution rate mutated"
        );

        uint256 startBalance = usdt.balanceOf(alice);
        uint256[] memory epochIds = new uint256[](1);
        epochIds[0] = 0;

        vm.prank(alice);
        adapter.claimWallet(epochIds);

        assertEq(usdt.balanceOf(alice) - startBalance, 50_000 * 10 ** 6);
    }

    function test_DepositFirstYieldRejectsEmptyHashAndZeroDeposits() public {
        vm.startPrank(depositor);
        usdt.approve(address(adapter), 100 * 10 ** 6);

        vm.expectRevert("Adapter: Deposit must exceed zero");
        adapter.depositFirstYield(0, "QmHash");

        vm.expectRevert("Adapter: IPFS hash cannot be empty");
        adapter.depositFirstYield(100 * 10 ** 6, "");
        vm.stopPrank();
    }

    // ==========================================
    // REGULAR BASELINE DISTRIBUTION SCENARIOS
    // ==========================================

    function test_DepositRegularYieldUsesFullBaselineSupply() public {
        uint256 depositAmount = 270_000 * 10 ** 6;

        vm.startPrank(depositor);
        usdt.approve(address(adapter), depositAmount);
        adapter.depositRegularYield(depositAmount, "QmRegularYieldHash");
        vm.stopPrank();

        (, , uint256 supplyAtSnapshot, ) = adapter.epochs(0);
        assertEq(
            supplyAtSnapshot,
            BASE_YIELD_BEARING_SUPPLY,
            "Regular yield processing denominator must not clear Sablier"
        );
        assertEq(adapter.claimableWallet(0, alice), 100_000 * 10 ** 6);
    }

    // ==========================================
    // MULTI-EPOCH CLAIMS & EDGE CASES
    // ==========================================

    function test_ClaimWalletCanProcessBatchEpochs() public {
        vm.prank(admin);
        gobiToken.transfer(sablier, 70_000_000 * 10 ** 18);

        vm.startPrank(depositor);
        usdt.approve(address(adapter), 500_000 * 10 ** 6);
        adapter.depositFirstYield(135_000 * 10 ** 6, "QmEpoch0");
        adapter.depositRegularYield(270_000 * 10 ** 6, "QmEpoch1");
        vm.stopPrank();

        uint256[] memory batchEpochIds = new uint256[](2);
        batchEpochIds[0] = 0;
        batchEpochIds[1] = 1;

        uint256 balanceBefore = usdt.balanceOf(alice);

        vm.prank(alice);
        adapter.claimWallet(batchEpochIds);

        assertEq(usdt.balanceOf(alice) - balanceBefore, 150_000 * 10 ** 6);
    }

    function test_ClaimWalletPreventsDoubleClaiming() public {
        uint256 depositAmount = 270_000 * 10 ** 6;
        vm.startPrank(depositor);
        usdt.approve(address(adapter), depositAmount);
        adapter.depositRegularYield(depositAmount, "QmHash");
        vm.stopPrank();

        uint256[] memory epochIds = new uint256[](1);
        epochIds[0] = 0;

        vm.prank(alice);
        adapter.claimWallet(epochIds);

        vm.prank(alice);
        vm.expectRevert("Adapter: No claimable yield available");
        adapter.claimWallet(epochIds);
    }

    function test_ClaimWalletBlocksExcludedWallets() public {
        uint256 depositAmount = 270_000 * 10 ** 6;
        vm.startPrank(depositor);
        usdt.approve(address(adapter), depositAmount);
        adapter.depositRegularYield(depositAmount, "QmHash");
        vm.stopPrank();

        vm.prank(admin);
        adapter.setExclusionStatus(alice, true);

        uint256[] memory epochIds = new uint256[](1);
        epochIds[0] = 0;

        vm.prank(alice);
        vm.expectRevert(
            "Adapter: Wallet address is excluded from snapshot path"
        );
        adapter.claimWallet(epochIds);

        assertEq(adapter.claimableWallet(0, alice), 0);
    }

    function test_ClaimWalletSkipsAlreadyClaimedEpochsInLoops() public {
        vm.startPrank(depositor);
        usdt.approve(address(adapter), 500_000 * 10 ** 6);
        adapter.depositRegularYield(100_000 * 10 ** 6, "QmHash0");
        adapter.depositRegularYield(200_000 * 10 ** 6, "QmHash1");
        vm.stopPrank();

        uint256[] memory simpleEpoch = new uint256[](1);
        simpleEpoch[0] = 0;
        vm.prank(alice);
        adapter.claimWallet(simpleEpoch);

        uint256[] memory batchEpochIds = new uint256[](2);
        batchEpochIds[0] = 0;
        batchEpochIds[1] = 1;

        uint256 balanceBefore = usdt.balanceOf(alice);
        vm.prank(alice);
        adapter.claimWallet(batchEpochIds);

        // She only receives the payout allocation for Epoch 1 because Epoch 0 skips gracefully
        assertEq(
            usdt.balanceOf(alice) - balanceBefore,
            (200_000 * 10 ** 6 * 100_000_000 * 10 ** 18) /
                BASE_YIELD_BEARING_SUPPLY
        );
    }

    function test_ClaimWalletRevertsOnNonExistentEpoch() public {
        uint256[] memory invalidEpoch = new uint256[](1);
        invalidEpoch[0] = 999;

        vm.prank(alice);
        vm.expectRevert("Adapter: Non-existent epoch");
        adapter.claimWallet(invalidEpoch);
    }

    function test_VestedUserUnlocksAndClaimsAtSecondEpoch() public {
        // --- STEP 1: SETUP LOCKUP FOR EPOCH 0 ---
        // Simulating 10M GOBI locked in Sablier vesting for Alice
        uint256 vestingAmount = 10_000_000 * 10 ** 18;
        vm.prank(admin);
        gobiToken.transfer(sablier, vestingAmount);

        // Alice starts with 100M GOBI in her wallet (unlocked)
        // Total Active Circulating Supply = 270M - 10M = 260M GOBI

        // Depositor funds Epoch 0 (First Yield Path)
        uint256 intendedBudget0 = 135_000 * 10 ** 6; // $135k USDT total intended budget
        vm.startPrank(depositor);
        usdt.approve(address(adapter), 500_000 * 10 ** 6);
        adapter.depositFirstYield(intendedBudget0, "QmEpoch0Hash");
        vm.stopPrank();

        // Contract Math Validation for Epoch 0:
        // keptAmount = (135,000 * 260M) / 270M = 130,000 USDT
        // Alice's expected Epoch 0 payout = (130,000 * 100M) / 260M = 50,000 USDT

        // --- STEP 2: 12 MONTHS PASS - VESTING UNLOCKS ---
        // Simulating Sablier distributing the 10M vested tokens to Alice's wallet
        vm.prank(sablier);
        gobiToken.transfer(alice, vestingAmount);

        // Alice now holds 110M GOBI in her wallet (100M original + 10M unlocked)

        // --- STEP 3: FUND EPOCH 1 (2ND EPOCH) ---
        // Depositor funds Epoch 1 (Regular Yield Path)
        uint256 depositAmount1 = 270_000 * 10 ** 6; // $270k USDT
        vm.prank(depositor);
        adapter.depositRegularYield(depositAmount1, "QmEpoch1Hash");

        // Contract Math Validation for Epoch 1:
        // Denominator = full 270M BASE_YIELD_BEARING_SUPPLY
        // Alice's expected Epoch 1 payout = (270,000 * 110M) / 270M = 110,000 USDT

        // --- STEP 4: BATCH CLAIM AND VERIFY ---
        // Total expected USDT across both epochs = 50,000 + 110,000 = 160,000 USDT
        uint256[] memory epochIds = new uint256[](2);
        epochIds[0] = 0;
        epochIds[1] = 1;

        uint256 balanceBefore = usdt.balanceOf(alice);

        vm.prank(alice);
        adapter.claimWallet(epochIds);

        uint256 balanceAfter = usdt.balanceOf(alice);

        // Assert Alice received the exact cumulative math share
        assertEq(
            balanceAfter - balanceBefore,
            160_000 * 10 ** 6,
            "Vested user reward distribution mismatched across epoch boundaries"
        );
    }

    function test_SequentialClaimsWithVestingUnlocks() public {
        // --- STEP 1: INITIAL STATE & LOCK GOBI IN SABLIER ---
        uint256 vestingAmount = 10_000_000 * 10 ** 18; // 10M GOBI
        vm.prank(admin);
        gobiToken.transfer(sablier, vestingAmount);

        // Alice starts with 100M GOBI. Total Active Supply = 260M GOBI.

        // --- STEP 2: DEPOSIT & CLAIM EPOCH 0 IMMEDIATELY ---
        uint256 intendedBudget0 = 135_000 * 10 ** 6; // $135k USDT
        vm.startPrank(depositor);
        usdt.approve(address(adapter), 500_000 * 10 ** 6);
        adapter.depositFirstYield(intendedBudget0, "QmEpoch0Hash");
        vm.stopPrank();

        // Alice claims ONLY Epoch 0 right now
        uint256[] memory firstClaim = new uint256[](1);
        firstClaim[0] = 0;

        uint256 balanceBefore0 = usdt.balanceOf(alice);
        vm.prank(alice);
        adapter.claimWallet(firstClaim);
        uint256 balanceAfter0 = usdt.balanceOf(alice);

        // Math check: (130,000 kept USDT * 100M Alice) / 260M active supply = 50,000 USDT
        assertEq(
            balanceAfter0 - balanceBefore0,
            50_000 * 10 ** 6,
            "Epoch 0 sequential claim failed"
        );
        assertTrue(
            adapter.claimedWallet(0, alice),
            "Epoch 0 state not marked as claimed"
        );

        // --- STEP 3: VESTING UNLOCKS AFTER 12 MONTHS ---
        vm.prank(sablier);
        gobiToken.transfer(alice, vestingAmount); // Alice now has 110M GOBI

        // --- STEP 4: DEPOSIT & CLAIM EPOCH 1 LATER ---
        uint256 depositAmount1 = 270_000 * 10 ** 6; // $270k USDT
        vm.prank(depositor);
        adapter.depositRegularYield(depositAmount1, "QmEpoch1Hash");

        // Alice claims Epoch 1.
        // We will pass [0, 1] to simulate a user trying to claim everything again,
        // verifying that the contract safely skips Epoch 0 and processes Epoch 1.
        uint256[] memory secondClaim = new uint256[](2);
        secondClaim[0] = 0;
        secondClaim[1] = 1;

        uint256 balanceBefore1 = usdt.balanceOf(alice);
        vm.prank(alice);
        adapter.claimWallet(secondClaim);
        uint256 balanceAfter1 = usdt.balanceOf(alice);

        // Math check: (270,000 USDT * 110M Alice) / 270M base supply = 110,000 USDT
        assertEq(
            balanceAfter1 - balanceBefore1,
            110_000 * 10 ** 6,
            "Epoch 1 sequential claim failed"
        );
        assertTrue(
            adapter.claimedWallet(1, alice),
            "Epoch 1 state not marked as claimed"
        );

        // Total USDT Alice received across both independent claims = $50,000 + $110,000 = $160,000 USDT
        assertEq(
            usdt.balanceOf(alice),
            160_000 * 10 ** 6,
            "Cumulative sequential payouts are incorrect"
        );
    }

    function test_EmergencyWithdrawRewards() public {
        // Admin performs an emergency withdrawal of all rewards to a specified recipient
        address recipient = address(0x8);

        // Use startPrank so both the approve and deposit are executed by the depositor
        vm.startPrank(depositor);
        usdt.approve(address(adapter), 100_000 * 10 ** 6);
        adapter.depositRegularYield(100_000 * 10 ** 6, "QmEmergencyHash");
        vm.stopPrank();

        uint256 balanceBefore = usdt.balanceOf(recipient);

        // Execute emergency withdraw as the admin
        vm.prank(admin);
        adapter.emergencyWithdrawRewards(recipient);

        uint256 balanceAfter = usdt.balanceOf(recipient);
        assertEq(
            balanceAfter - balanceBefore,
            100_000 * 10 ** 6,
            "Emergency withdrawal did not transfer the correct amount"
        );
    }
}
