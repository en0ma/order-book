// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IMarkOracle {
    function markTick() external view returns (uint16);
}
