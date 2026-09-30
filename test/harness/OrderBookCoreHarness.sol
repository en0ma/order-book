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

    function accountingStateTest(address account)
        external
        view
        returns (
            uint256 collateral,
            int256 trading,
            int256 funding,
            uint256 reserved,
            int128 fundingCheckpoint
        )
    {
        collateral = collateralBalance[account];
        trading = tradeCashflow[account];
        funding = fundingCashflow[account];
        reserved = reservedMargin[account];
        fundingCheckpoint = _accountMeta[account].fundingCheckpointX18;
    }

    function fundingIndexTest() external view returns (int128) {
        return fundingIndexX18;
    }
}
