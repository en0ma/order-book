// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OrderBookCore} from "../../src/deployable/OrderBookCore.sol";

contract OrderBookCoreHarness is OrderBookCore {
    constructor(
        address collateralToken_,
        address markOracle_,
        uint16 executionBandTicks_,
        uint16 initialMarginBps_,
        uint16 takerFeeBps_,
        uint16 makerRebateBps_
    )
        OrderBookCore(
            collateralToken_,
            markOracle_,
            executionBandTicks_,
            initialMarginBps_,
            takerFeeBps_,
            makerRebateBps_
        )
    {}

    function marginStateTest(address account)
        external
        view
        returns (uint256 collateral, uint256 reserved)
    {
        collateral = collateralBalance[account];
        reserved = reservedMargin[account];
    }
}
