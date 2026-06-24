// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IAdapter {
    function setExclusionStatus(address account, bool excluded) external;

    function admitTreasury(address holder, uint256 amount) external;

    function depositFirstYield(uint256 amount, string calldata ipfsHash) external;

    function depositRegularYield(uint256 amount, string calldata ipfsHash) external;

    function claimWallet(uint256[] calldata epochIds) external;

    function emergencyWithdrawRewards(
        address recipient
    ) external;
}
