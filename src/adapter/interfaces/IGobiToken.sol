// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IGobiToken {
    function snapshot() external returns (uint256);
    function balanceOfAt(address account, uint256 snapshotId) external view returns (uint256);
    function totalSupplyAt(uint256 snapshotId) external view returns (uint256);
}
