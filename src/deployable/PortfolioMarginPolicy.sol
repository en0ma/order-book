// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IOrderBookCore} from "./IOrderBookCore.sol";
/// @title PortfolioMarginPolicy
/// @notice Read-side cross-market margin policy over multiple OrderBookCore markets.
/// @dev Settled positions inside the same risk group may receive a configurable hedge credit.
///      Contingent exposure between settledPosition and the min/max risk envelope is always
///      charged without cross-market netting, so resting orders cannot manufacture margin credit.
contract PortfolioMarginPolicy {
    uint256 public constant MAX_MARKETS = 32;

    struct MarketConfig {
        IOrderBookCore core;
        uint32 riskGroup;
        uint16 marginBps;
        uint16 hedgeCreditBps;
    }

    struct MarketInput {
        address core;
        uint32 riskGroup;
        uint16 marginBps;
        uint16 hedgeCreditBps;
    }

    error InvalidPortfolioConfig();
    error DuplicateMarket();
    error InconsistentRiskGroup();
    error Overflow();

    MarketConfig[] public markets;

    constructor(MarketInput[] memory configs) {
        uint256 length = configs.length;
        if (length == 0 || length > MAX_MARKETS) revert InvalidPortfolioConfig();

        for (uint256 i; i < length; ++i) {
            MarketInput memory input = configs[i];
            if (
                input.core == address(0) || input.riskGroup == 0
                    || input.marginBps == 0 || input.marginBps > 10_000
                    || input.hedgeCreditBps > 10_000
            ) revert InvalidPortfolioConfig();

            for (uint256 j; j < i; ++j) {
                MarketConfig storage prior = markets[j];
                if (address(prior.core) == input.core) revert DuplicateMarket();
                if (
                    prior.riskGroup == input.riskGroup
                        && prior.hedgeCreditBps != input.hedgeCreditBps
                ) revert InconsistentRiskGroup();
            }

            markets.push(
                MarketConfig({
                    core: IOrderBookCore(input.core),
                    riskGroup: input.riskGroup,
                    marginBps: input.marginBps,
                    hedgeCreditBps: input.hedgeCreditBps
                })
            );
        }
    }

    function marketCount() external view returns (uint256) {
        return markets.length;
    }

    function portfolioEquity(address account) public view returns (int256 equity) {
        uint256 length = markets.length;
        for (uint256 i; i < length; ++i) {
            equity += markets[i].core.accountEquity(account);
        }
    }

    function grossRequirement(address account)
        external
        view
        returns (uint256 requirement)
    {
        uint256 length = markets.length;
        for (uint256 i; i < length; ++i) {
            MarketConfig storage market = markets[i];
            (, int80 minPosition, int80 maxPosition) =
                market.core.accountRisk(account);

            uint96 worstLots = _maxAbs(minPosition, maxPosition);
            requirement += _requirement(market, worstLots);
        }
    }

    function portfolioRequirement(address account)
        public
        view
        returns (uint256 requirement)
    {
        uint256 length = markets.length;
        bool[] memory visited = new bool[](length);

        // Start from gross worst-case risk across every market envelope.
        for (uint256 i; i < length; ++i) {
            MarketConfig storage market = markets[i];
            (, int80 minPosition, int80 maxPosition) =
                market.core.accountRisk(account);
            requirement += _requirement(
                market,
                _maxAbs(minPosition, maxPosition)
            );
        }

        // Hedge credit applies only to exposure guaranteed to remain on the
        // same side for every reachable state inside each market's envelope.
        for (uint256 i; i < length; ++i) {
            if (visited[i]) continue;

            MarketConfig storage anchor = markets[i];
            uint256 guaranteedLongRequirement;
            uint256 guaranteedShortRequirement;

            for (uint256 j = i; j < length; ++j) {
                MarketConfig storage market = markets[j];
                if (market.riskGroup != anchor.riskGroup) continue;

                visited[j] = true;
                (int80 settledPosition, int80 minPosition, int80 maxPosition) =
                    market.core.accountRisk(account);

                if (settledPosition > 0 && minPosition > 0) {
                    guaranteedLongRequirement +=
                        _requirement(market, uint96(uint80(minPosition)));
                } else if (settledPosition < 0 && maxPosition < 0) {
                    guaranteedShortRequirement += _requirement(
                        market,
                        uint96(uint256(-int256(maxPosition)))
                    );
                }
            }

            uint256 matched = guaranteedLongRequirement < guaranteedShortRequirement
                ? guaranteedLongRequirement
                : guaranteedShortRequirement;
            uint256 creditPerSide =
                matched * uint256(anchor.hedgeCreditBps) / 10_000;
            requirement -= creditPerSide * 2;
        }
    }

    function health(address account) external view returns (int256) {
        uint256 requirement = portfolioRequirement(account);
        if (requirement > uint256(type(int256).max)) revert Overflow();
        return portfolioEquity(account) - int256(requirement);
    }

    function isUnderMargined(address account) external view returns (bool) {
        uint256 requirement = portfolioRequirement(account);
        if (requirement > uint256(type(int256).max)) return true;
        return portfolioEquity(account) < int256(requirement);
    }

    function _requirement(MarketConfig storage market, uint96 lots)
        internal
        view
        returns (uint256)
    {
        if (lots == 0) return 0;

        uint256 notional =
            market.core.notionalValue(lots, market.core.currentMarkTick());
        return notional * uint256(market.marginBps) / 10_000;
    }

    function _absLots(int80 position) internal pure returns (uint96) {
        if (position >= 0) return uint96(uint80(position));
        return uint96(uint256(-int256(position)));
    }

    function _maxAbs(int80 first, int80 second)
        internal
        pure
        returns (uint96)
    {
        uint96 firstAbs = _absLots(first);
        uint96 secondAbs = _absLots(second);
        return firstAbs > secondAbs ? firstAbs : secondAbs;
    }
}
