// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IExternalPriceSource} from "../../src/ValidatedMarkOracleAdapter.sol";

contract MockExternalPriceSource is IExternalPriceSource {
    int256 public price;
    uint256 public confidence;
    uint48 public publishTime;

    constructor(int256 price_, uint256 confidence_, uint48 publishTime_) {
        set(price_, confidence_, publishTime_);
    }

    function set(int256 price_, uint256 confidence_, uint48 publishTime_) public {
        price = price_;
        confidence = confidence_;
        publishTime = publishTime_;
    }

    function latestPrice()
        external
        view
        returns (int256, uint256, uint48)
    {
        return (price, confidence, publishTime);
    }
}
