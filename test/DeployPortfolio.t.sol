// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {DeployPortfolio} from "../script/DeployPortfolio.s.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {SegmentTreeExtremaOracle} from "../src/SegmentTreeExtremaOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract DeployPortfolioTest is TestBase {
    address internal constant ADMIN = address(0xA11CE);
    address internal constant FUNDING_A = address(0xF001);
    address internal constant FUNDING_B = address(0xF002);

    MockERC20 internal token;
    SegmentTreeExtremaOracle internal oracleA;
    SegmentTreeExtremaOracle internal oracleB;
    DeployPortfolio internal script;

    function setUp() public {
        token = new MockERC20();
        oracleA = new SegmentTreeExtremaOracle(address(this), 100, 3_600);
        oracleB = new SegmentTreeExtremaOracle(address(this), 200, 3_600);
        script = new DeployPortfolio();
    }

    function testDeployPortfolioWiresTwoMarketsAndHandsOffAdmin() public {
        DeployPortfolio.Deployment memory deployment =
            script.deployPortfolio(_config());

        assertEq(deployment.markets.length, 2, "market count");
        assertEq(deployment.policy.marketCount(), 2, "policy market count");
        assertEq(deployment.coordinator.marketCount(), 2, "coordinator market count");
        assertEq(deployment.liquidation.marketCount(), 2, "liquidation market count");

        assertTrue(
            deployment.vault.controller() == address(deployment.coordinator),
            "vault controller"
        );
        assertTrue(
            address(deployment.policy.sharedCollateralVault())
                == address(deployment.vault),
            "policy vault"
        );
        assertTrue(deployment.policy.owner() == ADMIN, "policy owner");
        assertTrue(deployment.vault.owner() == ADMIN, "vault owner");

        for (uint256 i; i < 2; ++i) {
            DeployPortfolio.MarketDeployment memory market = deployment.markets[i];

            assertTrue(market.core.owner() == ADMIN, "core owner");
            assertTrue(market.advanced.owner() == ADMIN, "advanced owner");
            assertTrue(
                market.core.portfolioController() == address(deployment.coordinator),
                "core coordinator"
            );
            assertTrue(
                address(market.advanced.portfolioController())
                    == address(deployment.coordinator),
                "advanced coordinator"
            );
            assertEq(
                uint256(market.advanced.portfolioMarketIndex()),
                i,
                "advanced market index"
            );
            assertTrue(
                market.advanced.marketMakerModule() == address(market.marketMaker),
                "market maker wiring"
            );
            assertTrue(
                market.advanced.liquidationModule() == address(deployment.liquidation),
                "liquidation wiring"
            );

            address expectedFunding = i == 0 ? FUNDING_A : FUNDING_B;
            assertTrue(
                market.core.fundingUpdater() == expectedFunding,
                "funding updater"
            );
            assertEq(
                market.core.notionalValue(1, 1),
                i == 0 ? 1_000 : 2_000,
                "accounting scale"
            );
        }
    }

    function testPortfolioBootstrapBlocksDirectRiskIncrease() public {
        DeployPortfolio.Deployment memory deployment =
            script.deployPortfolio(_config());

        token.mint(address(this), 10_000);
        token.approve(address(deployment.vault), type(uint256).max);
        deployment.vault.deposit(10_000);

        (bool ok,) = address(deployment.markets[0].core).call(
            abi.encodeCall(
                deployment.markets[0].core.addLiquidity,
                (IOrderBookCore.Side.Ask, uint16(100), uint96(10))
            )
        );
        assertTrue(!ok, "direct core risk increase bypassed coordinator");
    }

    function testPortfolioBootstrapRejectsInvalidArrayLengths() public {
        DeployPortfolio.Config memory config = _config();
        config.fundingUpdaters = new address[](1);
        config.fundingUpdaters[0] = FUNDING_A;

        (bool ok,) = address(script).call(
            abi.encodeCall(script.deployPortfolio, (config))
        );
        assertTrue(!ok, "mismatched market arrays accepted");
    }

    function testPortfolioBootstrapRejectsInconsistentRiskGroupCredit() public {
        DeployPortfolio.Config memory config = _config();
        config.riskGroups[1] = config.riskGroups[0];
        config.hedgeCreditBps[1] = 2_500;

        (bool ok,) = address(script).call(
            abi.encodeCall(script.deployPortfolio, (config))
        );
        assertTrue(!ok, "inconsistent risk-group hedge credit accepted");
    }

    function testPortfolioBootstrapRejectsZeroAdmin() public {
        DeployPortfolio.Config memory config = _config();
        config.protocolAdmin = address(0);

        (bool ok,) = address(script).call(
            abi.encodeCall(script.deployPortfolio, (config))
        );
        assertTrue(!ok, "zero protocol admin accepted");
    }

    function _config()
        internal
        view
        returns (DeployPortfolio.Config memory config)
    {
        config.protocolAdmin = ADMIN;
        config.collateralToken = address(token);

        config.fundingUpdaters = new address[](2);
        config.fundingUpdaters[0] = FUNDING_A;
        config.fundingUpdaters[1] = FUNDING_B;

        config.oracles = new address[](2);
        config.oracles[0] = address(oracleA);
        config.oracles[1] = address(oracleB);

        config.executionBandTicks = new uint16[](2);
        config.executionBandTicks[0] = 40;
        config.executionBandTicks[1] = 60;

        config.initialMarginBps = new uint16[](2);
        config.initialMarginBps[0] = 1_000;
        config.initialMarginBps[1] = 1_500;

        config.takerFeeBps = new uint16[](2);
        config.takerFeeBps[0] = 5;
        config.takerFeeBps[1] = 7;

        config.makerRebateBps = new uint16[](2);
        config.makerRebateBps[0] = 2;
        config.makerRebateBps[1] = 3;

        config.collateralUnitsPerLotTick = new uint128[](2);
        config.collateralUnitsPerLotTick[0] = 1_000;
        config.collateralUnitsPerLotTick[1] = 2_000;

        config.riskGroups = new uint32[](2);
        config.riskGroups[0] = 1;
        config.riskGroups[1] = 2;

        config.portfolioMarginBps = new uint16[](2);
        config.portfolioMarginBps[0] = 1_000;
        config.portfolioMarginBps[1] = 1_500;

        config.hedgeCreditBps = new uint16[](2);
        config.hedgeCreditBps[0] = 5_000;
        config.hedgeCreditBps[1] = 0;
    }
}
