// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IGobiToken
/// @notice Adapter-facing surface of the GobiToken.
interface IGobiToken {
    function snapshot() external returns (uint256);
    function balanceOfAt(address account, uint256 snapshotId) external view returns (uint256);
    function totalSupplyAt(uint256 snapshotId) external view returns (uint256);
    /// @notice Category A-eligible (Sablier-sourced) balance at a snapshot.
    function categoryABalanceAt(address account, uint256 snapshotId) external view returns (uint256);
    function categoryATotalSupplyAt(uint256 snapshotId) external view returns (uint256);
    function sablierLockup() external view returns (address);
}
