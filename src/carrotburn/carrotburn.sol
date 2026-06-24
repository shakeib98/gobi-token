// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/Icarrot.sol";
import "./interfaces/Icarrotburn.sol";
import "openzeppelin/access/AccessControl.sol";

contract CarrotBurn is ICarrotBurn, AccessControl {
    /// @dev Role for accounts that can burn carbon credits
    bytes32 public constant DEPOSITOR_ROLE = keccak256("DEPOSITOR_ROLE");
    /// @dev Reference to the external carbon engine contract
    ICarrot public immutable carrotToken;

    /// @dev Emitted when carbon credits are burned
    event CarrotBurned(uint256 amount, string beneficiary);

    /// @dev Constructor initializes the contract and sets the external carbon engine address
    /// @param carrotTokenAddress Address of the external carbon engine contract
    /// @param admin Address to be granted DEFAULT_ADMIN_ROLE and DEPOSITOR_ROLE
    constructor(address carrotTokenAddress, address admin) {
        require(carrotTokenAddress != address(0), "Carrot token address cannot be zero");
        require(admin != address(0), "Admin address cannot be zero");
        carrotToken = ICarrot(carrotTokenAddress);
        _setupRole(DEFAULT_ADMIN_ROLE, admin);
        _setupRole(DEPOSITOR_ROLE, admin);
    }
    /**
     * @notice Permanently retires carbon credits to fulfill the mine's environmental compliance mandates.
     * @dev Invokes the external carbon engine interface. Contract must hold or be approved for the tokens.
     * @param amount The specific volume of carbon tokens to permanently delete.
     * @param beneficiary Descriptive text or legal entity name mapped to the retirement ledger.
     */

    function burnCarrot(uint256 amount, string calldata beneficiary) external override onlyRole(DEPOSITOR_ROLE) {
        require(amount > 0, "Adapter: Burn volume must exceed zero");
        require(bytes(beneficiary).length > 0, "Adapter: Beneficiary description cannot be empty");

        // Execute external contract call to lock up carbon credits permanently
        carrotToken.retire(amount, beneficiary);

        // Emit the public environmental audit log
        emit CarrotBurned(amount, beneficiary);
    }
}
