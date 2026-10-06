// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IOrderBookCore} from "./IOrderBookCore.sol";
import {ILiquidationGateway} from "./ILiquidationGateway.sol";
import {PortfolioMarginPolicy} from "./PortfolioMarginPolicy.sol";

/// @title PortfolioLiquidationModule
/// @notice Cross-market liquidation orchestration over a PortfolioMarginPolicy.
/// @dev This module intentionally does not provide cross-market collateral transfer or
///      portfolio admission. It only enforces portfolio health and atomically removes
///      all supplied open orders before reducing positions across configured markets.
contract PortfolioLiquidationModule {
    uint256 public constant MAX_MARKETS = 32;

    struct MarketInput {
        address core;
        address gateway;
    }

    struct MarketConfig {
        IOrderBookCore core;
        ILiquidationGateway gateway;
    }

    struct CleanupInput {
        IOrderBookCore.Side[] makerSides;
        uint16[] makerTicks;
        uint64[] conditionalIds;
        uint64[] trailingIds;
    }

    error InvalidPortfolioLiquidationConfig();
    error NotLiquidatable();
    error UnsettledOrders();
    error CleanupLengthMismatch();

    PortfolioMarginPolicy public immutable policy;
    MarketConfig[] public markets;

    event PortfolioMarketLiquidated(
        uint256 indexed marketIndex,
        address indexed account,
        IOrderBookCore.Side side,
        uint96 requestedLots,
        uint96 filledLots
    );

    event PortfolioLiquidationStatus(
        address indexed account,
        int256 equityAfter,
        uint256 requirementAfter,
        bool stillUnderMargined
    );

    constructor(address policy_, MarketInput[] memory configs) {
        if (policy_ == address(0)) revert InvalidPortfolioLiquidationConfig();
        if (configs.length == 0 || configs.length > MAX_MARKETS) {
            revert InvalidPortfolioLiquidationConfig();
        }

        PortfolioMarginPolicy policyRef = PortfolioMarginPolicy(policy_);
        if (policyRef.marketCount() != configs.length) {
            revert InvalidPortfolioLiquidationConfig();
        }

        for (uint256 i; i < configs.length; ++i) {
            if (configs[i].core == address(0) || configs[i].gateway == address(0)) {
                revert InvalidPortfolioLiquidationConfig();
            }

            (IOrderBookCore policyCore,,,) = policyRef.markets(i);
            if (address(policyCore) != configs[i].core) {
                revert InvalidPortfolioLiquidationConfig();
            }

            markets.push(
                MarketConfig({
                    core: IOrderBookCore(configs[i].core),
                    gateway: ILiquidationGateway(configs[i].gateway)
                })
            );
        }

        policy = policyRef;
    }

    function marketCount() external view returns (uint256) {
        return markets.length;
    }

    function hasOpenOrders(address account) public view returns (bool) {
        for (uint256 i; i < markets.length; ++i) {
            MarketConfig storage market = markets[i];
            if (
                market.core.activeQuoteCount(account) != 0
                    || market.gateway.activeAdvancedOrders(account) != 0
            ) {
                return true;
            }
        }
        return false;
    }

    function isLiquidatable(address account) external view returns (bool) {
        return policy.isUnderMargined(account);
    }

    function liquidate(address account, CleanupInput[] calldata cleanups)
        external
        returns (uint96 totalFilledLots)
    {
        uint256 length = markets.length;
        if (cleanups.length != length) revert CleanupLengthMismatch();
        if (!policy.isUnderMargined(account)) revert NotLiquidatable();

        for (uint256 i; i < length; ++i) {
            _cleanupMarket(account, markets[i], cleanups[i]);
        }

        if (hasOpenOrders(account)) revert UnsettledOrders();

        for (uint256 i; i < length; ++i) {
            if (!policy.isUnderMargined(account)) break;

            MarketConfig storage market = markets[i];
            (int80 position,,) = market.core.accountRisk(account);
            if (position == 0) continue;

            IOrderBookCore.Side side;
            uint16 limitTick;
            uint96 requestedLots;

            if (position > 0) {
                side = IOrderBookCore.Side.Ask;
                limitTick = 0;
                requestedLots = uint96(uint80(position));
            } else {
                side = IOrderBookCore.Side.Bid;
                limitTick = type(uint16).max;
                requestedLots = uint96(uint256(-int256(position)));
            }

            uint96 filledLots = market.gateway.liquidationTake(
                account,
                side,
                limitTick,
                requestedLots
            );
            totalFilledLots += filledLots;

            emit PortfolioMarketLiquidated(
                i,
                account,
                side,
                requestedLots,
                filledLots
            );
        }

        uint256 requirementAfter = policy.portfolioRequirement(account);
        int256 equityAfter = policy.portfolioEquity(account);
        bool underMargined = policy.isUnderMargined(account);

        emit PortfolioLiquidationStatus(
            account,
            equityAfter,
            requirementAfter,
            underMargined
        );
    }

    function liquidateWithStrategies(
        address account,
        CleanupInput[] calldata cleanups,
        uint64[][] calldata strategyIds
    ) external returns (uint96 totalFilledLots) {
        uint256 length = markets.length;
        if (cleanups.length != length || strategyIds.length != length) {
            revert CleanupLengthMismatch();
        }
        if (!policy.isUnderMargined(account)) revert NotLiquidatable();

        for (uint256 i; i < length; ++i) {
            markets[i].gateway.liquidationCleanupStrategies(
                account,
                strategyIds[i]
            );
        }

        totalFilledLots = this.liquidate(account, cleanups);
    }

    function _cleanupMarket(
        address account,
        MarketConfig storage market,
        CleanupInput calldata cleanup
    ) internal {
        if (cleanup.makerSides.length != cleanup.makerTicks.length) {
            revert CleanupLengthMismatch();
        }

        market.gateway.liquidationCleanupAdvanced(
            account,
            cleanup.conditionalIds,
            cleanup.trailingIds
        );

        for (uint256 i; i < cleanup.makerTicks.length; ++i) {
            market.gateway.liquidationForceCancelQuote(
                account,
                cleanup.makerSides[i],
                cleanup.makerTicks[i]
            );
        }
    }
}
