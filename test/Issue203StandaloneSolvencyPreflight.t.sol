// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMarkOracle} from "./mocks/MockMarkOracle.sol";
import {StandaloneFeeSolvencyPreflight} from "../src/deployable/StandaloneFeeSolvencyPreflight.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";

contract Issue203StandaloneSolvencyPreflightTest is TestBase {
    address internal constant MAKER = address(0xA11CE);
    address internal constant TAKER = address(0xB0B);

    MockERC20 internal token;
    OrderBookCore internal core;
    StandaloneFeeSolvencyPreflight internal proof;

    function setUp() public {
        token = new MockERC20();
        core = new OrderBookCore(address(token), address(new MockMarkOracle(100)), 30, 1000, 100, 0);
        proof = new StandaloneFeeSolvencyPreflight();
        token.mint(MAKER, 50000);
        token.mint(TAKER, 50000);
        vm.prank(MAKER);
        token.approve(address(core), type(uint256).max);
        vm.prank(MAKER);
        core.depositCollateral(50000);
        vm.prank(TAKER);
        token.approve(address(core), type(uint256).max);
        vm.prank(TAKER);
        core.depositCollateral(50000);
    }

    function test_EnumeratesActualOnChainClaimsAndCanonicalTokenCustody() public {
        (uint256 capacity, uint256 claims, uint256 reserved) =
            proof.conservativeCapacity(core);
        assertEq(capacity, 0, "unearned fees became distributable");
        assertEq(claims, 100000, "missing user collateral claim");
        assertEq(reserved, 100000, "incorrect protected backing");

        token.mint(address(core), 1000);
        (capacity, claims, reserved) = proof.conservativeCapacity(core);
        assertEq(capacity, 0, "donated collateral manufactured protocol fees");
        assertEq(claims, 100000, "donation changed depositor liabilities");
        assertEq(reserved, 100000, "donation changed reserve accounting");
    }

    function test_FailsClosedOnOpenMakerRiskEvenWithExcessTokens() public {
        vm.prank(MAKER);
        core.addLiquidity(IOrderBookCore.Side.Ask, 100, 100);
        token.mint(address(core), 1000000);

        (bool verified,) = address(proof).call(
            abi.encodeCall(proof.conservativeCapacity, (core))
        );
        assertTrue(!verified, "active maker exposure was treated as free surplus");
    }

    function test_RejectsClaimantSetThatExceedsBoundedGasBudget() public {
        for (uint256 i; i < 65; ++i) {
            address account = address(uint160(i + 1000));
            token.mint(account, 1);
            vm.prank(account);
            token.approve(address(core), 1);
            vm.prank(account);
            core.depositCollateral(1);
        }

        assertEq(core.claimantRegistry().count(), 67, "claimant inventory was truncated");
        (bool verified,) = address(proof).call(
            abi.encodeCall(proof.conservativeCapacity, (core))
        );
        assertTrue(!verified, "unbounded claimant scan was accepted");
    }
    function test_CompletedRoundTripCanEarnAConservativelyBackedFeeCandidate() public {
        vm.prank(MAKER);
        core.addLiquidity(IOrderBookCore.Side.Ask, 100, 100);
        vm.prank(TAKER);
        core.take(IOrderBookCore.Side.Bid, 100, 100, IOrderBookCore.FillPolicy.IOC);
        vm.prank(MAKER);
        core.settle(IOrderBookCore.Side.Ask, 100);

        vm.prank(MAKER);
        core.addLiquidity(IOrderBookCore.Side.Bid, 100, 100);
        vm.prank(TAKER);
        core.take(IOrderBookCore.Side.Ask, 100, 100, IOrderBookCore.FillPolicy.IOC);
        vm.prank(MAKER);
        core.settle(IOrderBookCore.Side.Bid, 100);

        (int80 makerPosition,,) = core.accountRisk(MAKER);
        (int80 takerPosition,,) = core.accountRisk(TAKER);
        assertEq(int256(makerPosition), 0, "maker position not closed");
        assertEq(int256(takerPosition), 0, "taker position not closed");
        assertEq(core.activeQuoteCount(MAKER), 0, "maker quote remains");
        assertEq(core.protocolFeesAccrued(), 200, "roundtrip accrued fee mismatch");

        (uint256 capacity, uint256 claims, uint256 reserves) =
            proof.conservativeCapacity(core);
        assertEq(claims, 99800, "settled positive claims do not reconcile");
        assertEq(reserves, 99800, "incorrect conservative liability floor");
        assertEq(capacity, 200, "fully settled fees were not conservatively backed");
        assertEq(token.balanceOf(address(core)), claims + capacity,
            "physical ERC20 conservation failed");
    }

    function test_PermissionlessTokenDrainCannotManufactureFeeCapacity() public {
        vm.prank(MAKER);
        core.addLiquidity(IOrderBookCore.Side.Ask, 100, 100);
        vm.prank(TAKER);
        core.take(IOrderBookCore.Side.Bid, 100, 100, IOrderBookCore.FillPolicy.IOC);
        vm.prank(MAKER);
        core.settle(IOrderBookCore.Side.Ask, 100);

        vm.prank(MAKER);
        core.addLiquidity(IOrderBookCore.Side.Bid, 100, 100);
        vm.prank(TAKER);
        core.take(IOrderBookCore.Side.Ask, 100, 100, IOrderBookCore.FillPolicy.IOC);
        vm.prank(MAKER);
        core.settle(IOrderBookCore.Side.Bid, 100);

        (uint256 initiallyAvailable,,) = proof.conservativeCapacity(core);
        assertEq(initiallyAvailable, 200, "initial fee claim not backed");

        // Simulate collateral loss from an adversarial token/custody event.
        // A live ERC20 cannot be presumed honest solely from the fee ledger.
        vm.prank(address(core));
        token.transfer(address(0xBAD), 201);
        (uint256 remainingCapacity, uint256 claims, uint256 reserved) =
            proof.conservativeCapacity(core);
        assertEq(remainingCapacity, 0, "insolvent custody still authorized fees");
        assertEq(claims, 99800, "token loss incorrectly destroyed account claims");
        assertEq(reserved, 99800, "protected obligations silently reduced");
        assertTrue(token.balanceOf(address(core)) < reserved,
            "physical custody loss failed to trigger insolvency");
    }

}
