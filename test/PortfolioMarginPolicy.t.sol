// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PortfolioMarginPolicy} from "../src/deployable/PortfolioMarginPolicy.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {TestBase} from "./TestBase.sol";

contract MockPortfolioMarket {
    struct Risk {
        int80 settledPosition;
        int80 minPosition;
        int80 maxPosition;
    }

    uint16 public markTick;
    uint128 public unitsPerLotTick = 1;
    mapping(address => Risk) internal _risk;
    mapping(address => int256) internal _equity;

    constructor(uint16 markTick_) {
        markTick = markTick_;
    }

    function setRisk(
        address account,
        int80 settledPosition,
        int80 minPosition,
        int80 maxPosition
    ) external {
        _risk[account] = Risk(settledPosition, minPosition, maxPosition);
    }

    function setEquity(address account, int256 equity) external {
        _equity[account] = equity;
    }

    function accountRisk(address account)
        external
        view
        returns (int80 settledPosition, int80 minPosition, int80 maxPosition)
    {
        Risk memory risk = _risk[account];
        return (risk.settledPosition, risk.minPosition, risk.maxPosition);
    }

    function accountEquity(address account) external view returns (int256) {
        return _equity[account];
    }

    function currentMarkTick() external view returns (uint16) {
        return markTick;
    }

    function notionalValue(uint96 lots, uint16 tick)
        external
        view
        returns (uint256)
    {
        return uint256(lots) * uint256(tick) * uint256(unitsPerLotTick);
    }
}

contract PortfolioMarginPolicyTest is TestBase {
    address internal constant TRADER = address(0xA11CE);

    MockPortfolioMarket internal marketA;
    MockPortfolioMarket internal marketB;

    function setUp() public {
        marketA = new MockPortfolioMarket(100);
        marketB = new MockPortfolioMarket(100);
    }

    function testOpposingSettledPositionsReceiveConfiguredGroupCredit() public {
        PortfolioMarginPolicy policy = _policy(1, 1, 1_000, 5_000);

        marketA.setRisk(TRADER, 100, 100, 100);
        marketB.setRisk(TRADER, -80, -80, -80);

        assertEq(policy.grossRequirement(TRADER), 1_800, "gross margin mismatch");
        assertEq(
            policy.portfolioRequirement(TRADER),
            1_000,
            "portfolio hedge credit mismatch"
        );
    }

    function testDifferentRiskGroupsDoNotNet() public {
        PortfolioMarginPolicy policy = _policy(1, 2, 1_000, 10_000);

        marketA.setRisk(TRADER, 100, 100, 100);
        marketB.setRisk(TRADER, -80, -80, -80);

        assertEq(
            policy.portfolioRequirement(TRADER),
            1_800,
            "different groups unexpectedly netted"
        );
    }

    function testSameDirectionDoesNotNet() public {
        PortfolioMarginPolicy policy = _policy(1, 1, 1_000, 10_000);

        marketA.setRisk(TRADER, 100, 100, 100);
        marketB.setRisk(TRADER, 80, 80, 80);

        assertEq(
            policy.portfolioRequirement(TRADER),
            1_800,
            "same-direction exposure unexpectedly netted"
        );
    }

    function testRestingExposureExpansionIsNeverCrossNetted() public {
        PortfolioMarginPolicy policy = _policy(1, 1, 1_000, 10_000);

        // The settled 100/-100 pair fully offsets. Market A can still expand
        // to +150 through resting exposure, so the extra 50 lots remain margined.
        marketA.setRisk(TRADER, 100, 100, 150);
        marketB.setRisk(TRADER, -100, -100, -100);

        assertEq(
            policy.portfolioRequirement(TRADER),
            500,
            "contingent expansion received unsafe netting credit"
        );
    }

    function testZeroSettledCrossingEnvelopeIsChargedGross() public {
        PortfolioMarginPolicy policy = _policy(1, 1, 1_000, 10_000);

        marketA.setRisk(TRADER, 0, -50, 50);
        marketB.setRisk(TRADER, 0, 0, 0);

        assertEq(
            policy.portfolioRequirement(TRADER),
            500,
            "two-sided contingent envelope was netted"
        );
    }

    function testPortfolioEquityAndHealthAggregateAcrossMarkets() public {
        PortfolioMarginPolicy policy = _policy(1, 1, 1_000, 5_000);

        marketA.setRisk(TRADER, 100, 100, 100);
        marketB.setRisk(TRADER, -80, -80, -80);
        marketA.setEquity(TRADER, 700);
        marketB.setEquity(TRADER, 500);

        assertEq(policy.portfolioEquity(TRADER), int256(1_200), "equity mismatch");
        assertEq(policy.health(TRADER), int256(200), "health mismatch");
        assertTrue(!policy.isUnderMargined(TRADER), "healthy portfolio flagged");
    }

    function testUnderMarginedPortfolioIsDetected() public {
        PortfolioMarginPolicy policy = _policy(1, 1, 1_000, 5_000);

        marketA.setRisk(TRADER, 100, 100, 100);
        marketB.setRisk(TRADER, -80, -80, -80);
        marketA.setEquity(TRADER, 400);
        marketB.setEquity(TRADER, 500);

        assertTrue(policy.isUnderMargined(TRADER), "under-margined portfolio missed");
        assertEq(policy.health(TRADER), int256(-100), "negative health mismatch");
    }

    function testConstructorRejectsDuplicateMarket() public {
        PortfolioMarginPolicy.MarketInput[] memory configs =
            new PortfolioMarginPolicy.MarketInput[](2);
        configs[0] = PortfolioMarginPolicy.MarketInput({
            core: address(marketA),
            riskGroup: 1,
            marginBps: 1_000,
            hedgeCreditBps: 5_000
        });
        configs[1] = PortfolioMarginPolicy.MarketInput({
            core: address(marketA),
            riskGroup: 1,
            marginBps: 1_000,
            hedgeCreditBps: 5_000
        });

        vm.expectRevert(PortfolioMarginPolicy.DuplicateMarket.selector);
        new PortfolioMarginPolicy(configs);
    }

    function testConstructorRejectsInconsistentGroupCredit() public {
        PortfolioMarginPolicy.MarketInput[] memory configs =
            new PortfolioMarginPolicy.MarketInput[](2);
        configs[0] = PortfolioMarginPolicy.MarketInput({
            core: address(marketA),
            riskGroup: 7,
            marginBps: 1_000,
            hedgeCreditBps: 2_500
        });
        configs[1] = PortfolioMarginPolicy.MarketInput({
            core: address(marketB),
            riskGroup: 7,
            marginBps: 1_000,
            hedgeCreditBps: 5_000
        });

        vm.expectRevert(PortfolioMarginPolicy.InconsistentRiskGroup.selector);
        new PortfolioMarginPolicy(configs);
    }

    function _policy(
        uint32 groupA,
        uint32 groupB,
        uint16 marginBps,
        uint16 hedgeCreditBps
    ) internal returns (PortfolioMarginPolicy policy) {
        PortfolioMarginPolicy.MarketInput[] memory configs =
            new PortfolioMarginPolicy.MarketInput[](2);
        configs[0] = PortfolioMarginPolicy.MarketInput({
            core: address(marketA),
            riskGroup: groupA,
            marginBps: marginBps,
            hedgeCreditBps: hedgeCreditBps
        });
        configs[1] = PortfolioMarginPolicy.MarketInput({
            core: address(marketB),
            riskGroup: groupB,
            marginBps: marginBps,
            hedgeCreditBps: hedgeCreditBps
        });
        policy = new PortfolioMarginPolicy(configs);
    }
}
