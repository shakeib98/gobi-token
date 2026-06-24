// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/carrotburn/carrotburn.sol";
import "openzeppelin/token/ERC20/ERC20.sol";

// Mock Carrot Token
contract MockCarrotToken is ERC20 {
    mapping(address => bool) public retiredBy;
    uint256 public retiredAmount;
    string public retiredBeneficiary;

    constructor() ERC20("Carrot Token", "CARROT") {}

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }

    function retire(uint256 amount, string calldata beneficiary) external {
        require(amount > 0, "Amount must be greater than 0");
        require(balanceOf(msg.sender) >= amount, "Insufficient balance to retire");

        _burn(msg.sender, amount);
        retiredAmount = amount;
        retiredBeneficiary = beneficiary;
        retiredBy[msg.sender] = true;
    }
}

contract CarrotBurnTest is Test {
    CarrotBurn public carrotBurn;
    MockCarrotToken public carrotToken;

    address public admin = address(0x1);
    address public depositor = address(0x2);
    address public alice = address(0x3);
    address public bob = address(0x4);

    event CarrotBurned(uint256 amount, string beneficiary);

    function setUp() public {
        // Deploy contracts
        carrotToken = new MockCarrotToken();
        carrotBurn = new CarrotBurn(address(carrotToken), admin);

        // Verify admin has the roles
        assert(carrotBurn.hasRole(carrotBurn.DEFAULT_ADMIN_ROLE(), admin));

        // Grant depositor role and mint carrot tokens as admin
        vm.startPrank(admin);
        carrotBurn.grantRole(carrotBurn.DEPOSITOR_ROLE(), depositor);
        vm.stopPrank();

        // Mint carrot tokens (no role needed for this simple ERC20)
        carrotToken.mint(address(carrotBurn), 1_000_000 * 10 ** 18);
    }

    // =====================
    // INITIALIZATION TESTS
    // =====================

    function test_InitialState() public {
        assertEq(address(carrotBurn.carrotToken()), address(carrotToken));
    }

    function test_ConstructorAssignsAdmin() public {
        assertTrue(carrotBurn.hasRole(carrotBurn.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_ConstructorAssignsDepositorRole() public {
        assertTrue(carrotBurn.hasRole(carrotBurn.DEPOSITOR_ROLE(), admin));
    }

    function test_ConstructorRejectsZeroCarrotToken() public {
        vm.expectRevert("Carrot token address cannot be zero");
        new CarrotBurn(address(0), admin);
    }

    function test_ConstructorRejectsZeroAdmin() public {
        vm.expectRevert("Admin address cannot be zero");
        new CarrotBurn(address(carrotToken), address(0));
    }

    // =====================
    // BURN CARROT TESTS
    // =====================

    function test_BurnCarrot() public {
        uint256 amount = 100_000 * 10 ** 18;

        vm.prank(depositor);
        carrotBurn.burnCarrot(amount, "Climate Initiative");

        // Verify tokens were retired
        assertEq(carrotToken.retiredAmount(), amount);
    }

    function test_BurnCarrotEmitsEvent() public {
        uint256 amount = 100_000 * 10 ** 18;

        vm.prank(depositor);
        vm.expectEmit(false, false, false, true);
        emit CarrotBurned(amount, "Climate Initiative");
        carrotBurn.burnCarrot(amount, "Climate Initiative");
    }

    function test_BurnCarrotMultipleTimes() public {
        uint256 amount1 = 100_000 * 10 ** 18;
        uint256 amount2 = 50_000 * 10 ** 18;

        vm.prank(depositor);
        carrotBurn.burnCarrot(amount1, "Initiative 1");

        vm.prank(depositor);
        carrotBurn.burnCarrot(amount2, "Initiative 2");

        // Both should have been retired
        assertEq(carrotToken.retiredAmount(), amount2);
    }

    function test_BurnCarrotRevertsNonDepositor() public {
        uint256 amount = 100_000 * 10 ** 18;

        vm.prank(alice);
        vm.expectRevert();
        carrotBurn.burnCarrot(amount, "Unauthorized");
    }

    function test_BurnCarrotRejectsZeroAmount() public {
        vm.prank(depositor);
        vm.expectRevert("Adapter: Burn volume must exceed zero");
        carrotBurn.burnCarrot(0, "Climate Initiative");
    }

    function test_BurnCarrotRejectsEmptyBeneficiary() public {
        uint256 amount = 100_000 * 10 ** 18;

        vm.prank(depositor);
        vm.expectRevert("Adapter: Beneficiary description cannot be empty");
        carrotBurn.burnCarrot(amount, "");
    }

    function test_BurnCarrotWithDifferentBeneficiaries() public {
        uint256 amount = 100_000 * 10 ** 18;
        string memory beneficiary1 = "Reforestation Project";
        string memory beneficiary2 = "Ocean Conservation";

        vm.prank(depositor);
        carrotBurn.burnCarrot(amount, beneficiary1);

        // Check the first beneficiary was recorded
        assertEq(carrotToken.retiredBeneficiary(), beneficiary1);

        vm.prank(depositor);
        carrotBurn.burnCarrot(amount, beneficiary2);

        // Check the second beneficiary was recorded
        assertEq(carrotToken.retiredBeneficiary(), beneficiary2);
    }

    // =====================
    // ROLE MANAGEMENT TESTS
    // =====================

    function test_AdminCanGrantDepositorRole() public {
        vm.startPrank(admin);
        carrotBurn.grantRole(carrotBurn.DEPOSITOR_ROLE(), bob);
        vm.stopPrank();

        assertTrue(carrotBurn.hasRole(carrotBurn.DEPOSITOR_ROLE(), bob));

        uint256 amount = 100_000 * 10 ** 18;
        vm.prank(bob);
        carrotBurn.burnCarrot(amount, "Authorized Burn");
    }

    function test_AdminCanRevokeDepositorRole() public {
        vm.startPrank(admin);
        carrotBurn.grantRole(carrotBurn.DEPOSITOR_ROLE(), bob);
        carrotBurn.revokeRole(carrotBurn.DEPOSITOR_ROLE(), bob);
        vm.stopPrank();

        assertFalse(carrotBurn.hasRole(carrotBurn.DEPOSITOR_ROLE(), bob));

        uint256 amount = 100_000 * 10 ** 18;
        vm.prank(bob);
        vm.expectRevert();
        carrotBurn.burnCarrot(amount, "Unauthorized");
    }

    // =====================
    // EDGE CASES & SECURITY
    // =====================

    function test_BurnCarrotLargeAmount() public {
        uint256 largeAmount = 500_000 * 10 ** 18;

        vm.prank(depositor);
        carrotBurn.burnCarrot(largeAmount, "Large Scale Initiative");

        assertEq(carrotToken.retiredAmount(), largeAmount);
    }

    function test_BurnCarrotVerySmallAmount() public {
        uint256 smallAmount = 1; // 1 wei

        vm.prank(depositor);
        carrotBurn.burnCarrot(smallAmount, "Small Contribution");

        assertEq(carrotToken.retiredAmount(), smallAmount);
    }

    function test_BurnCarrotLongBeneficiaryString() public {
        uint256 amount = 100_000 * 10 ** 18;
        string memory longBeneficiary =
            "Very Long Beneficiary Name That Describes A Complex Environmental Initiative Across Multiple Geographies";

        vm.prank(depositor);
        carrotBurn.burnCarrot(amount, longBeneficiary);

        assertEq(carrotToken.retiredBeneficiary(), longBeneficiary);
    }

    function test_MultipleDepositorsCanBurn() public {
        // Grant role to multiple depositors
        vm.startPrank(admin);
        carrotBurn.grantRole(carrotBurn.DEPOSITOR_ROLE(), alice);
        vm.stopPrank();

        uint256 amount = 100_000 * 10 ** 18;

        vm.prank(depositor);
        carrotBurn.burnCarrot(amount, "Depositor 1");

        uint256 firstRetirement = carrotToken.retiredAmount();

        vm.prank(alice);
        carrotBurn.burnCarrot(amount, "Depositor 2");

        // Both burns should have succeeded (second one updates retired amount)
        assertGt(carrotToken.retiredAmount(), 0);
    }

    function test_InsufficientFundsHandledByCarrotToken() public {
        // Deploy a new carrot burn contract with insufficient funds
        MockCarrotToken emptyToken = new MockCarrotToken();
        CarrotBurn emptyBurn = new CarrotBurn(address(emptyToken), admin);

        vm.startPrank(admin);
        emptyBurn.grantRole(emptyBurn.DEPOSITOR_ROLE(), depositor);
        vm.stopPrank();

        // emptyBurn has no tokens
        uint256 amount = 100_000 * 10 ** 18;

        vm.prank(depositor);
        vm.expectRevert("Insufficient balance to retire");
        emptyBurn.burnCarrot(amount, "Will Fail");
    }

    // =====================
    // INTEGRATION TESTS
    // =====================

    function test_BurnCarrotIntegration() public {
        // Simulate multiple burns over time
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 100_000 * 10 ** 18;
        amounts[1] = 50_000 * 10 ** 18;
        amounts[2] = 25_000 * 10 ** 18;

        for (uint256 i = 0; i < amounts.length; i++) {
            vm.prank(depositor);
            carrotBurn.burnCarrot(amounts[i], string(abi.encodePacked("Initiative ", vm.toString(i))));
        }

        // Last amount should be recorded
        assertEq(carrotToken.retiredAmount(), amounts[2]);
    }
}
