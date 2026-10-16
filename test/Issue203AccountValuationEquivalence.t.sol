// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {AccountValuationModule} from "../src/deployable/AccountValuationModule.sol";

contract Issue203AccountValuationEquivalenceTest is TestBase {
    AccountValuationModule internal valuation;

    function setUp() public {
        valuation = new AccountValuationModule();
    }

    function testFuzz_PureMarkedCashAndFundingMatchesOriginalArithmetic(
        int64 signedLots,
        int64 currentIndex,
        int64 entryIndex,
        uint16 mark,
        uint32 scale,
        int128 trade,
        int128 funding
    ) public {
        int80 position = int80(signedLots);
        uint128 unitScale = uint128(uint256(scale) + 1);
        int256 pendingFunding = -(
            int256(position) * (int256(currentIndex) - int256(entryIndex)) / 1e18
        );
        int256 markedPositionValue;
        if (position != 0) {
            uint96 lots = uint96(uint80(position > 0 ? int256(position) : -int256(position)));
            int256 marked = int256(uint256(lots) * uint256(mark) * uint256(unitScale));
            markedPositionValue = position > 0 ? marked : -marked;
        }
        int256 expected = int256(trade) + int256(funding) + pendingFunding + markedPositionValue;
        int256 actual = valuation.marketValue(
            position,
            int128(currentIndex),
            int128(entryIndex),
            mark,
            unitScale,
            int256(trade),
            int256(funding)
        );
        assertEq(actual, expected, "external valuation changed signed cash conservation");
    }
}
