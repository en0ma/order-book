// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract MockMarkOracle {
    uint16 public markTick;

    constructor(uint16 initialTick) {
        markTick = initialTick;
    }

    function setMarkTick(uint16 next) external {
        markTick = next;
    }
}
