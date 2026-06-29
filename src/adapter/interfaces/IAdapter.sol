// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IAdapter {
    function addExclusion(address account) external;
    function removeExclusion(address account) external;
    function depositYield(uint256 amount, string calldata ipfsHash) external;
    function claimWallet(uint256[] calldata epochIds) external;
    function sweepExcess(address recipient) external;
    function rescueToken(address token, address recipient, uint256 amount) external;
    function outstandingLiability() external view returns (uint256);
    function claimableWallet(uint256 epochId, address account) external view returns (uint256);
    function isExcluded(address account) external view returns (bool);
    function excludedCount() external view returns (uint256);
    function excludedAt(uint256 index) external view returns (address);
}
