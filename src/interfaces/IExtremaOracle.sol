// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IExtremaOracle {
    function markTick() external view returns (uint16);
    function currentObservationId() external view returns (uint64);
    function highLowSince(uint64 observationId)
        external
        view
        returns (uint16 highTick, uint16 lowTick);
}
