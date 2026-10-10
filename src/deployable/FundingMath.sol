// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IOrderBookCore} from "./IOrderBookCore.sol";

/// @notice Pure funding rounding operations shared across order-book modules.
/// @dev Internal functions are inlined or compiled into callers; no external-call trust boundary.
library FundingMath {
    function divFundingCeil(int256 numerator, int256 denominator)
        internal
        pure
        returns (int256 quotient)
    {
        quotient = numerator / denominator;
        if (numerator > 0 && numerator % denominator != 0) {
            ++quotient;
        }
    }

    function divFundingDirected(
        IOrderBookCore.Side side,
        int256 numerator,
        int256 denominator
    ) internal pure returns (int256 quotient) {
        quotient = numerator / denominator;
        int256 remainder = numerator % denominator;
        if (remainder == 0) return quotient;

        if (side == IOrderBookCore.Side.Bid) {
            if (numerator < 0) --quotient;
        } else if (numerator > 0) {
            ++quotient;
        }
    }

}
