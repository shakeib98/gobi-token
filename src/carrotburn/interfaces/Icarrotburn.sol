// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ICarrotBurn {
    function burnCarrot(uint256 amount, string calldata beneficiary) external;
}
