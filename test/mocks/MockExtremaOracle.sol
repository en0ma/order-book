// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract MockExtremaOracle {
    uint16 public markTick;
    uint64 public currentObservationId;

    mapping(uint64 => uint16) public observationTick;

    constructor(uint16 initialTick) {
        markTick = initialTick;
        currentObservationId = 1;
        observationTick[1] = initialTick;
    }

    function setMarkTick(uint16 next) external {
        markTick = next;
        unchecked {
            ++currentObservationId;
        }
        observationTick[currentObservationId] = next;
    }

    function highLowSince(uint64 observationId)
        external
        view
        returns (uint16 highTick, uint16 lowTick)
    {
        require(observationId != 0 && observationId <= currentObservationId, "bad observation");

        highTick = observationTick[observationId];
        lowTick = highTick;

        for (uint64 i = observationId + 1; i <= currentObservationId; ++i) {
            uint16 tick = observationTick[i];
            if (tick > highTick) highTick = tick;
            if (tick < lowTick) lowTick = tick;
        }
    }
}
