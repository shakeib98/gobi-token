// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "openzeppelin/token/ERC20/ERC20.sol";
import "openzeppelin/token/ERC20/extensions/ERC20Snapshot.sol";
import "openzeppelin/access/AccessControl.sol";
import "openzeppelin/token/ERC20/extensions/ERC20Burnable.sol";

/// @title GobiToken
/// @dev ERC-20 token with snapshot capabilities, role-based access control, and supply cap.
contract GobiToken is ERC20, ERC20Snapshot, AccessControl, ERC20Burnable {
    /// @dev Maximum total supply of GOBI tokens (1.2 billion with 18 decimals)
    uint256 public constant MAX_SUPPLY = 1_200_000_000e18;

    /// @dev Role for accounts that can mint new tokens
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @dev Role for accounts that can take snapshots
    bytes32 public constant SNAPSHOT_ROLE = keccak256("SNAPSHOT_ROLE");

    /// @dev Emitted when a snapshot is taken
    event SnapshotTaken(uint256 indexed snapshotId);

    /// @dev Constructor initializes the token and grants roles to the multisig
    /// @param multisig Address of the multisig wallet that holds DEFAULT_ADMIN_ROLE
    constructor(address multisig) ERC20("Gobi Token", "GOBI") {
        require(multisig != address(0), "Multisig address cannot be zero");

        // Grant DEFAULT_ADMIN_ROLE to multisig
        _grantRole(DEFAULT_ADMIN_ROLE, multisig);

        // Grant MINTER_ROLE to multisig initially (can be revoked or granted to others)
        _grantRole(MINTER_ROLE, multisig);

        // Mint initial supply of 400,000,000 GOBI to multisig at TGE
        _mint(multisig, 400_000_000e18);
    }

    /// @dev Mints new tokens, subject to MAX_SUPPLY constraint
    /// @param to Recipient address
    /// @param amount Amount to mint
    /// @custom:access Only MINTER_ROLE
    function mint(address to, uint256 amount) public onlyRole(MINTER_ROLE) {
        require(totalSupply() + amount <= MAX_SUPPLY, "Mint would exceed max supply");
        _mint(to, amount);
    }

    /// @dev Takes a snapshot of current token balances
    /// @return newSnapshotId The ID of the newly created snapshot
    /// @custom:access Only SNAPSHOT_ROLE (Adapter)
    function snapshot() public onlyRole(SNAPSHOT_ROLE) returns (uint256) {
        uint256 newSnapshotId = _snapshot();
        emit SnapshotTaken(newSnapshotId);
        return newSnapshotId;
    }

    /// @dev Returns the current snapshot ID
    function getCurrentSnapshotId() public view returns (uint256) {
        return _getCurrentSnapshotId();
    }

    /// @dev Returns the balance of an account at a given snapshot ID
    /// @param account The account to query
    /// @param snapshotId The snapshot ID
    /// @return The balance at the given snapshot
    function balanceOfAt(address account, uint256 snapshotId) public view override(ERC20Snapshot) returns (uint256) {
        return super.balanceOfAt(account, snapshotId);
    }

    /// @dev Returns the total supply at a given snapshot ID
    /// @param snapshotId The snapshot ID
    /// @return The total supply at the given snapshot
    function totalSupplyAt(uint256 snapshotId) public view override(ERC20Snapshot) returns (uint256) {
        return super.totalSupplyAt(snapshotId);
    }

    // Internal function overrides to handle multiple inheritance

    /// @dev Override required by Solidity due to multiple inheritance
    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override(ERC20, ERC20Snapshot) {
        super._beforeTokenTransfer(from, to, amount);
    }

    /// @dev Override required by Solidity due to multiple inheritance
    function _afterTokenTransfer(address from, address to, uint256 amount) internal override(ERC20) {
        super._afterTokenTransfer(from, to, amount);
    }

    /// @dev Override required by Solidity due to multiple inheritance
    function _mint(address to, uint256 amount) internal override(ERC20) {
        super._mint(to, amount);
    }

    /// @dev Override required by Solidity due to multiple inheritance
    function _burn(address account, uint256 amount) internal override(ERC20) {
        super._burn(account, amount);
    }
}
