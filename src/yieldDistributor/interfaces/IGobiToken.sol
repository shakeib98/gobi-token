// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "openzeppelin/token/ERC20/IERC20.sol";

interface IGobiToken is IERC20 {
    /// @notice Take a new balance snapshot; returns the new snapshot id.
    /// @dev    Restricted to SNAPSHOT_ROLE on the token — the distributor must hold it.
    function snapshot() external returns (uint256);

    /// @notice Balance of `account` at a past snapshot.
    function balanceOfAt(address account, uint256 snapshotId) external view returns (uint256);

    /// @notice Total supply at a past snapshot (required to derive yield-bearing supply).
    function totalSupplyAt(uint256 snapshotId) external view returns (uint256);
}
