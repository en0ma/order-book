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
    function maintenanceRequirement(address account) external view returns (uint256);

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

    function moduleForceCancelQuote(address account, Side side, uint16 tick)
        external
        returns (uint96 removedLots);
}
