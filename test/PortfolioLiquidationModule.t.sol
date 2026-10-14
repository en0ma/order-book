// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PortfolioMarginPolicy} from "../src/deployable/PortfolioMarginPolicy.sol";
import {PortfolioLiquidationModule} from "../src/deployable/PortfolioLiquidationModule.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {ILiquidationGateway} from "../src/deployable/ILiquidationGateway.sol";
import {TestBase} from "./TestBase.sol";

contract MockPortfolioLiquidationCore {
    struct Risk {
        int80 settledPosition;
        int80 minPosition;
        int80 maxPosition;
    }

    uint16 public markTick = 100;
    mapping(address => Risk) internal _risk;
    mapping(address => int256) internal _equity;
    mapping(address => uint32) internal _quotes;

    function setRisk(address account, int80 settled, int80 minPos, int80 maxPos) external {
        _risk[account] = Risk(settled, minPos, maxPos);
    }

    function setEquity(address account, int256 equity) external {
        _equity[account] = equity;
    }

    function setActiveQuotes(address account, uint32 count) external {
        _quotes[account] = count;
    }

    function reducePosition(address account, IOrderBookCore.Side side, uint96 lots) external {
        Risk storage r = _risk[account];
        int80 amount = int80(uint80(lots));
        if (side == IOrderBookCore.Side.Ask) {
            r.settledPosition -= amount;
        } else {
            r.settledPosition += amount;
        }
        r.minPosition = r.settledPosition;
        r.maxPosition = r.settledPosition;
    }

    function clearQuotes(address account) external {
        _quotes[account] = 0;
    }

    function accountRisk(address account)
        external
        view
        returns (int80 settledPosition, int80 minPosition, int80 maxPosition)
    {
        Risk memory r = _risk[account];
        return (r.settledPosition, r.minPosition, r.maxPosition);
    }

    function activeQuoteCount(address account) external view returns (uint32) {
        return _quotes[account];
    }

    function accountEquity(address account) external view returns (int256) {
        return _equity[account];
    }

    function currentMarkTick() external view returns (uint16) {
        return markTick;
    }

    function notionalValue(uint96 lots, uint16 tick) external pure returns (uint256) {
        return uint256(lots) * uint256(tick);
    }
}

contract MockPortfolioLiquidationGateway is ILiquidationGateway {
    MockPortfolioLiquidationCore public immutable core;
    mapping(address => uint32) internal _advanced;
    uint96 public maxFill = type(uint96).max;
    bool public fakeFill;
    bool public overReportFill;
    address public executionStrategyModule;

    constructor(address core_) {
        core = MockPortfolioLiquidationCore(core_);
    }

    function setActiveAdvanced(address account, uint32 count) external {
        _advanced[account] = count;
    }

    function setExecutionStrategyModule(address strategy) external {
        executionStrategyModule = strategy;
    }

    function setFakeFill(bool enabled) external { fakeFill = enabled; }
    function setOverReportFill(bool enabled) external { overReportFill = enabled; }

    function setMaxFill(uint96 maxFill_) external {
        maxFill = maxFill_;
    }

    function activeAdvancedOrders(address account) external view returns (uint32) {
        return _advanced[account];
    }

    function liquidationCleanupAdvanced(
        address account,
        uint64[] calldata,
        uint64[] calldata
    ) external {
        _advanced[account] = 0;
    }

    function liquidationCleanupStrategies(
        address account,
        uint64[] calldata
    ) external {
        _advanced[account] = 0;
    }

    function liquidationForceCancelQuote(
        address account,
        IOrderBookCore.Side,
        uint16
    ) external returns (uint96 removedLots) {
        core.clearQuotes(account);
        return 0;
    }

    function liquidationTake(
        address account,
        IOrderBookCore.Side side,
        uint16,
        uint96 lots
    ) external returns (uint96 filledLots) {
        filledLots = lots < maxFill ? lots : maxFill;
        if (overReportFill) return lots + 1;
        if (!fakeFill) core.reducePosition(account, side, filledLots);
    }

    function liquidationCoverBadDebt(address, uint256)
        external
        pure
        returns (uint256)
    {
        return 0;
    }

    function liquidationPayReward(address, uint256)
        external
        pure
        returns (uint256)
    {
        return 0;
    }
}

contract MockPortfolioLiquidationStrategy {
    mapping(address => uint32) public activeStrategyCount;

    function setActive(address account, uint32 count) external {
        activeStrategyCount[account] = count;
    }
}

contract PortfolioLiquidationModuleTest is TestBase {
    address internal constant TRADER = address(0xBEEF);

    MockPortfolioLiquidationCore internal coreA;
    MockPortfolioLiquidationCore internal coreB;
    MockPortfolioLiquidationGateway internal gatewayA;
    MockPortfolioLiquidationGateway internal gatewayB;
    PortfolioMarginPolicy internal policy;
    PortfolioLiquidationModule internal module;

    function setUp() public {
        coreA = new MockPortfolioLiquidationCore();
        coreB = new MockPortfolioLiquidationCore();
        gatewayA = new MockPortfolioLiquidationGateway(address(coreA));
        gatewayB = new MockPortfolioLiquidationGateway(address(coreB));

        PortfolioMarginPolicy.MarketInput[] memory policyInputs =
            new PortfolioMarginPolicy.MarketInput[](2);
        policyInputs[0] = PortfolioMarginPolicy.MarketInput({
            core: address(coreA),
            riskGroup: 1,
            marginBps: 1_000,
            hedgeCreditBps: 5_000
        });
        policyInputs[1] = PortfolioMarginPolicy.MarketInput({
            core: address(coreB),
            riskGroup: 1,
            marginBps: 1_000,
            hedgeCreditBps: 5_000
        });
        policy = new PortfolioMarginPolicy(policyInputs);

        PortfolioLiquidationModule.MarketInput[] memory liquidationInputs =
            new PortfolioLiquidationModule.MarketInput[](2);
        liquidationInputs[0] = PortfolioLiquidationModule.MarketInput({
            core: address(coreA),
            gateway: address(gatewayA)
        });
        liquidationInputs[1] = PortfolioLiquidationModule.MarketInput({
            core: address(coreB),
            gateway: address(gatewayB)
        });
        module = new PortfolioLiquidationModule(address(policy), liquidationInputs);
    }

    function testHealthyPortfolioCannotBeLiquidated() public {
        coreA.setRisk(TRADER, 100, 100, 100);
        coreB.setRisk(TRADER, -100, -100, -100);
        coreA.setEquity(TRADER, 600);
        coreB.setEquity(TRADER, 600);

        PortfolioLiquidationModule.CleanupInput[] memory cleanups = _emptyCleanups();
        (bool ok,) = address(module).call(
            abi.encodeCall(module.liquidate, (TRADER, cleanups))
        );
        assertTrue(!ok, "healthy portfolio liquidated");
    }

    function testLiquidationCleansOrdersAcrossAllMarketsAtomically() public {
        coreA.setRisk(TRADER, 100, 100, 100);
        coreB.setRisk(TRADER, 0, 0, 0);
        coreA.setEquity(TRADER, 100);
        coreB.setEquity(TRADER, 0);
        coreA.setActiveQuotes(TRADER, 1);
        coreB.setActiveQuotes(TRADER, 1);
        gatewayA.setActiveAdvanced(TRADER, 1);
        gatewayB.setActiveAdvanced(TRADER, 1);

        PortfolioLiquidationModule.CleanupInput[] memory cleanups = _singleQuoteCleanups();
        uint96 filled = module.liquidate(TRADER, cleanups);

        assertEq(filled, 100, "wrong liquidation fill");
        assertTrue(!module.hasOpenOrders(TRADER), "orders survived liquidation");
    }

    function testPartialCleanupOfSecondMarketRevertsAllPriorCancellations() public {
        coreA.setRisk(TRADER, 100, 100, 100);
        coreA.setEquity(TRADER, 100);
        coreA.setActiveQuotes(TRADER, 1);
        coreB.setActiveQuotes(TRADER, 1);
        gatewayA.setActiveAdvanced(TRADER, 1);
        gatewayB.setActiveAdvanced(TRADER, 1);

        PortfolioLiquidationModule.CleanupInput[] memory cleanups = _singleQuoteCleanups();
        // Omit the second market's maker inventory while the first market
        // is fully cleaned. The whole transaction must unwind.
        cleanups[1].makerSides = new IOrderBookCore.Side[](0);
        cleanups[1].makerTicks = new uint16[](0);
        (bool ok,) = address(module).call(
            abi.encodeCall(module.liquidate, (TRADER, cleanups))
        );
        assertTrue(!ok, "incomplete market inventory was accepted");
        assertEq(uint256(coreA.activeQuoteCount(TRADER)), 1, "first market cleanup committed");
        assertEq(uint256(coreB.activeQuoteCount(TRADER)), 1, "second market quote vanished");
        assertEq(uint256(gatewayA.activeAdvancedOrders(TRADER)), 1, "first advanced cleanup committed");
        assertEq(uint256(gatewayB.activeAdvancedOrders(TRADER)), 1, "second advanced cleanup committed");
        (int80 position,,) = coreA.accountRisk(TRADER);
        assertEq(int256(position), 100, "failed cleanup liquidated position");
    }

    function testLiquidationStopsOncePortfolioRecovers() public {
        coreA.setRisk(TRADER, 100, 100, 100);
        coreB.setRisk(TRADER, 100, 100, 100);
        coreA.setEquity(TRADER, 900);
        coreB.setEquity(TRADER, 0);

        // Requirement starts at 2,000; closing A drops it to 1,000.
        // Equity remains 900, so still under-margined and B must also close.
        uint96 filled = module.liquidate(TRADER, _emptyCleanups());
        assertEq(filled, 200, "expected both markets to close");

        coreA.setRisk(TRADER, 100, 100, 100);
        coreB.setRisk(TRADER, 100, 100, 100);
        coreA.setEquity(TRADER, 1_100);
        coreB.setEquity(TRADER, 0);

        // Requirement starts at 2,000. Closing A drops it to 1,000,
        // so the second market must not be liquidated.
        filled = module.liquidate(TRADER, _emptyCleanups());
        assertEq(filled, 100, "liquidation did not stop after recovery");

        (int80 bPosition,,) = coreB.accountRisk(TRADER);
        assertEq(int256(bPosition), int256(100), "healthy market was over-liquidated");
    }

    function testPartialLiquidityContinuesAcrossMarkets() public {
        coreA.setRisk(TRADER, 100, 100, 100);
        coreB.setRisk(TRADER, 100, 100, 100);
        coreA.setEquity(TRADER, 100);
        coreB.setEquity(TRADER, 0);
        gatewayA.setMaxFill(40);

        uint96 filled = module.liquidate(TRADER, _emptyCleanups());

        assertEq(filled, 140, "partial fill did not continue cross-market");
        (int80 aPosition,,) = coreA.accountRisk(TRADER);
        (int80 bPosition,,) = coreB.accountRisk(TRADER);
        assertEq(int256(aPosition), int256(60), "market A residual mismatch");
        assertEq(int256(bPosition), int256(0), "market B was not closed");
    }

    function testCleanupLengthMismatchRevertsAtomically() public {
        coreA.setRisk(TRADER, 100, 100, 100);
        coreA.setEquity(TRADER, 0);
        coreA.setActiveQuotes(TRADER, 1);

        PortfolioLiquidationModule.CleanupInput[] memory cleanups =
            new PortfolioLiquidationModule.CleanupInput[](1);

        (bool ok,) = address(module).call(
            abi.encodeCall(module.liquidate, (TRADER, cleanups))
        );
        assertTrue(!ok, "cleanup length mismatch accepted");
        assertEq(
            uint256(coreA.activeQuoteCount(TRADER)),
            uint256(1),
            "failed liquidation mutated state"
        );
    }

    function testOutstandingStrategyInventoryBlocksLiquidationAtomically() public {
        coreA.setRisk(TRADER, 100, 100, 100);
        coreA.setEquity(TRADER, 100);
        MockPortfolioLiquidationStrategy strategy = new MockPortfolioLiquidationStrategy();
        strategy.setActive(TRADER, 1);
        gatewayB.setExecutionStrategyModule(address(strategy));

        assertTrue(module.hasOpenOrders(TRADER), "strategy inventory was omitted");
        (bool ok,) = address(module).call(
            abi.encodeCall(module.liquidate, (TRADER, _emptyCleanups()))
        );
        assertTrue(!ok, "unsettled strategy liquidation succeeded");
        (int80 position,,) = coreA.accountRisk(TRADER);
        assertEq(int256(position), 100, "failed cleanup mutated other market");

        strategy.setActive(TRADER, 0);
        assertTrue(!module.hasOpenOrders(TRADER), "empty strategy inventory not recognized");
        assertEq(uint256(module.liquidate(TRADER, _emptyCleanups())), 100,
            "clean portfolio liquidation did not complete");
    }

    function testZeroLiquidityRetainsExposureAndAllowsRetry() public {
        coreA.setRisk(TRADER, 100, 100, 100);
        coreB.setRisk(TRADER, 80, 80, 80);
        coreA.setEquity(TRADER, 100);
        gatewayA.setMaxFill(0);
        gatewayB.setMaxFill(0);

        assertEq(uint256(module.liquidate(TRADER, _emptyCleanups())), 0,
            "zero-liquidity liquidation credited phantom fill");
        (int80 firstPosition,,) = coreA.accountRisk(TRADER);
        (int80 secondPosition,,) = coreB.accountRisk(TRADER);
        assertEq(int256(firstPosition), 100, "first exposure disappeared");
        assertEq(int256(secondPosition), 80, "second exposure disappeared");

        gatewayA.setMaxFill(40);
        gatewayB.setMaxFill(80);
        assertEq(uint256(module.liquidate(TRADER, _emptyCleanups())), 120,
            "retry did not use available cross-market liquidity");
        (firstPosition,,) = coreA.accountRisk(TRADER);
        (secondPosition,,) = coreB.accountRisk(TRADER);
        assertEq(int256(firstPosition), 60, "partial residual was discarded");
        assertEq(int256(secondPosition), 0, "liquid market not flattened");
    }

    function testFakeGatewayFillCannotConcealResidualRisk() public {
        coreA.setRisk(TRADER, 100, 100, 100);
        coreA.setEquity(TRADER, 100);
        gatewayA.setFakeFill(true);
        (bool ok,) = address(module).call(
            abi.encodeCall(module.liquidate, (TRADER, _emptyCleanups()))
        );
        assertTrue(!ok, "gateway credited a nonexecuted liquidation");
        (int80 position,,) = coreA.accountRisk(TRADER);
        assertEq(int256(position), 100, "reverted phantom fill altered risk");
    }

    function testOverreportedGatewayFillCannotAdvanceLiquidation() public {
        coreA.setRisk(TRADER, 100, 100, 100);
        coreA.setEquity(TRADER, 100);
        gatewayA.setOverReportFill(true);
        (bool ok,) = address(module).call(
            abi.encodeCall(module.liquidate, (TRADER, _emptyCleanups()))
        );
        assertTrue(!ok, "overreported fill advanced liquidation");
        (int80 position,,) = coreA.accountRisk(TRADER);
        assertEq(int256(position), 100, "failed fill mutated position");
    }

    function _emptyCleanups()
        internal
        pure
        returns (PortfolioLiquidationModule.CleanupInput[] memory cleanups)
    {
        cleanups = new PortfolioLiquidationModule.CleanupInput[](2);
        for (uint256 i; i < 2; ++i) {
            cleanups[i].makerSides = new IOrderBookCore.Side[](0);
            cleanups[i].makerTicks = new uint16[](0);
            cleanups[i].conditionalIds = new uint64[](0);
            cleanups[i].trailingIds = new uint64[](0);
        }
    }

    function _singleQuoteCleanups()
        internal
        pure
        returns (PortfolioLiquidationModule.CleanupInput[] memory cleanups)
    {
        cleanups = _emptyCleanups();
        for (uint256 i; i < 2; ++i) {
            cleanups[i].makerSides = new IOrderBookCore.Side[](1);
            cleanups[i].makerSides[0] = IOrderBookCore.Side.Ask;
            cleanups[i].makerTicks = new uint16[](1);
            cleanups[i].makerTicks[0] = 100;
        }
    }
}
