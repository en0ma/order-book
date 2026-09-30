// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AdvancedOrderModule} from "../../src/deployable/AdvancedOrderModule.sol";

contract AdvancedOrderModuleHarness is AdvancedOrderModule {
    constructor(address core_, address extremaOracle_)
        AdvancedOrderModule(core_, extremaOracle_)
    {}

    function otoGraphTest(uint64 parentOrderId, uint64 childOrderId)
        external
        view
        returns (
            uint64 childOne,
            uint64 childTwo,
            uint64 parentOfChild,
            uint96 childMaxLots
        )
    {
        childOne = otoChildOne[parentOrderId];
        childTwo = otoChildTwo[parentOrderId];
        parentOfChild = otoParent[childOrderId];
        childMaxLots = otoChildMaxLots[childOrderId];
    }

    function restingLinkTest(uint64 parentOrderId)
        external
        view
        returns (
            uint128 shares,
            uint96 remainingClaimLots,
            uint96 cumulativeFilledLots,
            uint32 generation,
            bool active
        )
    {
        RestingLink storage link = restingLinks[parentOrderId];
        shares = link.shares;
        remainingClaimLots = link.remainingClaimLots;
        cumulativeFilledLots = link.cumulativeFilledLots;
        generation = link.generation;
        active = link.active;
    }
}
