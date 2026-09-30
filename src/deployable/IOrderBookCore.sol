// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IOrderBookCore {
    enum Side {
        Bid,
        Ask
    }

    enum FillPolicy {
        IOC,
        FOK
    }

    function currentMarkTick() external view returns (uint16);
    function accountPosition(address account) external view returns (int80);
    function activeQuoteCount(address account) external view returns (uint32);
    function accountEquity(address account) external view returns (int256);

    function poolState(Side side, uint16 tick)
        external
        view
        returns (uint128 totalShares, uint96 remainingLots, uint32 generation);

    function quoteStateRaw(address account, Side side, uint16 tick)
        external
        view
        returns (uint128 shares, uint96 claimLots, uint32 generation);
    function moduleReserveExposure(address account, Side side, uint96 lots)
        external
        returns (uint16 riskCeilingTick);

    function moduleReleaseExposure(address account, Side side, uint96 lots) external;

    function moduleTake(
        address account,
        Side side,
        uint16 limitTick,
        uint96 lots,
        FillPolicy policy,
        bool reduceOnly,
        bool preReserved
    ) external returns (uint96 filledLots);

    function moduleAddLiquidity(
        address account,
        Side side,
        uint16 tick,
        uint96 lots,
        uint16 reservedRiskCeiling
    ) external returns (uint128 mintedShares);

    function moduleSettle(address account, Side side, uint16 tick)
        external
        returns (uint96 filledLots);

    function moduleRemoveLockedShares(
        address account,
        Side side,
        uint16 tick,
        uint128 shares
    ) external returns (uint96 removedLots);

    function moduleUnlockShares(address account, Side side, uint16 tick, uint128 shares)
        external;

    function moduleForceCancelQuote(address account, Side side, uint16 tick)
        external
        returns (uint96 removedLots);
}
