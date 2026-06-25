// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IYieldDistributor {
    // Exclusion management
    function addExclusion(address account) external;

    function removeExclusion(address account) external;

    // Yield distribution (single derived-denominator path)
    function depositYield(uint256 amount, string calldata ipfsHash) external;

    function claim(uint256[] calldata epochIds) external;

    // Recovery (cannot touch outstanding claims)
    function sweepExcess(address recipient) external;

    function rescueToken(address token, address recipient, uint256 amount) external;
}
