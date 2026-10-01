// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IOrderBookCore} from "./IOrderBookCore.sol";

/// @title OrderBookMath
/// @notice Shared stateless semantics for deployable order-book contracts.
/// @dev All functions are internal/pure so they introduce no trust boundary or external call.
library OrderBookMath {
    function opposite(IOrderBookCore.Side side)
        internal
        pure
        returns (IOrderBookCore.Side)
    {
        return side == IOrderBookCore.Side.Bid
            ? IOrderBookCore.Side.Ask
            : IOrderBookCore.Side.Bid;
    }

    function withinLimit(
        IOrderBookCore.Side makerSide,
        uint16 makerTick,
        uint16 limitTick
    ) internal pure returns (bool) {
        return makerSide == IOrderBookCore.Side.Ask
            ? makerTick <= limitTick
            : makerTick >= limitTick;
    }

    function upperTick(uint16 markTick, uint16 bandTicks)
        internal
        pure
        returns (uint16)
    {
        uint256 raw = uint256(markTick) + uint256(bandTicks);
        return raw > type(uint16).max ? type(uint16).max : uint16(raw);
    }

    function absPosition(int80 position) internal pure returns (uint80) {
        int256 wide = int256(position);
        return uint80(uint256(wide < 0 ? -wide : wide));
    }

    function mulDiv(
        uint256 x,
        uint256 y,
        uint256 denominator
    ) internal pure returns (uint256 result) {
        unchecked {
            uint256 prod0 = x * y;
            uint256 prod1;
            assembly ("memory-safe") {
                let mm := mulmod(x, y, not(0))
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            if (prod1 == 0) return prod0 / denominator;
            if (denominator <= prod1) revert();

            uint256 remainder;
            assembly ("memory-safe") {
                remainder := mulmod(x, y, denominator)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            uint256 twos = denominator & (~denominator + 1);
            assembly ("memory-safe") {
                denominator := div(denominator, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;

            uint256 inverse = (3 * denominator) ^ 2;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;

            result = prod0 * inverse;
        }
    }

    function mulDivUp(
        uint256 x,
        uint256 y,
        uint256 denominator
    ) internal pure returns (uint256 result) {
        result = mulDiv(x, y, denominator);
        if (mulmod(x, y, denominator) != 0) {
            if (result == type(uint256).max) revert();
            ++result;
        }
    }

    function redeemableLots(
        uint128 shares,
        uint96 remainingLots,
        uint128 totalShares
    ) internal pure returns (uint96) {
        if (shares == 0 || remainingLots == 0 || totalShares == 0) return 0;

        // The quotient cannot exceed remainingLots when shares <= totalShares.
        return uint96(
            uint256(shares) * uint256(remainingLots) / uint256(totalShares)
        );
    }

    function redeemableLotsCeil(
        uint128 shares,
        uint96 remainingLots,
        uint128 totalShares
    ) internal pure returns (uint96) {
        if (shares == 0 || remainingLots == 0 || totalShares == 0) return 0;

        uint256 numerator = uint256(shares) * uint256(remainingLots);
        return uint96((numerator + uint256(totalShares) - 1) / uint256(totalShares));
    }
}
