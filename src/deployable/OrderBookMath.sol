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
}
