// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IAdapter
/// @notice External surface of the Gobi yield distribution Adapter.
interface IAdapter {
    function addExclusion(address account) external;
    function removeExclusion(address account) external;
    function isExcluded(address account) external view returns (bool);
    function excludedCount() external view returns (uint256);
    function excludedAt(uint256 index) external view returns (address);
    function depositYield(uint256 amount, uint256 subsidyAmount, string calldata ipfsHash) external;
    function claimWallet(uint256[] calldata epochIds) external;
    function sweepExcess(address recipient) external;
    function rescueToken(address token, address recipient, uint256 amount) external;
    function setClaimWindow(uint256 newWindow) external;
    function reclaimExpired(uint256 epochId, address recipient) external;
    function outstandingLiability() external view returns (uint256);
    function claimableWallet(uint256 epochId, address account) external view returns (uint256);
}
