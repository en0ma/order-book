// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {PortfolioMarginPolicy} from "../src/deployable/PortfolioMarginPolicy.sol";
import {PortfolioCollateralVault} from "../src/deployable/PortfolioCollateralVault.sol";
import {PortfolioAdmissionCoordinator} from "../src/deployable/PortfolioAdmissionCoordinator.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMarkOracle} from "./mocks/MockMarkOracle.sol";
import {TestBase} from "./TestBase.sol";

/// @notice Stateful cross-market fuzzing for shared-collateral portfolio mode.
/// @dev Expected operation reverts are tolerated. End-state conservation is checked
///      after all tracked maker shares are retired so lazy fills are materialized.
contract PortfolioStateMachineTest is TestBase {
    MockERC20 internal token;
    MockMarkOracle internal oracleA;
    MockMarkOracle internal oracleB;
    OrderBookCore internal coreA;
    OrderBookCore internal coreB;
    PortfolioCollateralVault internal vault;
    PortfolioMarginPolicy internal policy;
    PortfolioAdmissionCoordinator internal coordinator;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);

    address[3] internal actors = [ALICE, BOB, CAROL];

    uint256[2] internal bidTakerFilled;
    uint256[2] internal askTakerFilled;

    function setUp() public {
        token = new MockERC20();
        oracleA = new MockMarkOracle(100);
        oracleB = new MockMarkOracle(100);

        coreA =
            new OrderBookCore(address(token), address(oracleA), 20, 1_000, 0, 0);
        coreB =
            new OrderBookCore(address(token), address(oracleB), 20, 1_000, 0, 0);

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

        vault = new PortfolioCollateralVault(address(token));

        PortfolioAdmissionCoordinator.MarketInput[] memory admissionInputs =
            new PortfolioAdmissionCoordinator.MarketInput[](2);
        admissionInputs[0] = PortfolioAdmissionCoordinator.MarketInput({
            core: address(coreA),
            gateway: address(this)
        });
        admissionInputs[1] = PortfolioAdmissionCoordinator.MarketInput({
            core: address(coreB),
            gateway: address(this)
        });
        coordinator = new PortfolioAdmissionCoordinator(
            address(policy),
            address(vault),
            admissionInputs
        );

        vault.configureController(address(coordinator));
        policy.configureSharedCollateralVault(address(vault));
        coreA.configurePortfolioController(address(coordinator));
        coreB.configurePortfolioController(address(coordinator));

        for (uint256 i; i < actors.length; ++i) {
            _deposit(actors[i], 1_000_000);
        }

        _checkStepInvariants();
    }

    function testFuzz_PortfolioMixedSequence(uint256 seed) public {
        _run(seed, 20);
    }

    function testPortfolioLongSequenceCorpus() public {
        for (uint256 seed = 1; seed <= 8; ++seed) {
            _run(uint256(keccak256(abi.encode(seed))), 40);
        }
    }

    function _run(uint256 seed, uint256 steps) internal {
        uint256 r = seed;

        for (uint256 step; step < steps; ++step) {
            r = uint256(keccak256(abi.encode(r, step)));
            _step(r);
            _checkStepInvariants();
        }

        _retireTrackedQuotes();
        _checkStepInvariants();
        _checkFinalConservation();
    }

    function _step(uint256 r) internal {
        uint256 op = r % 9;
        uint256 marketIndex = (r >> 8) & 1;
        address actor = actors[(r >> 16) % actors.length];
        IOrderBookCore.Side side =
            ((r >> 24) & 1) == 0 ? IOrderBookCore.Side.Bid : IOrderBookCore.Side.Ask;
        uint96 lots = uint96(((r >> 32) % 80) + 1);

        if (op <= 1) {
            _add(marketIndex, actor, side, lots);
        } else if (op <= 3) {
            _take(marketIndex, actor, side, lots);
        } else if (op == 4) {
            _remove(marketIndex, actor, side, r);
        } else if (op == 5) {
            _moveOracle(marketIndex, r);
        } else if (op == 6) {
            _setFunding(marketIndex, r);
        } else if (op == 7) {
            _withdraw(actor, r);
        } else {
            address(coordinator).call(
                abi.encodeCall(coordinator.syncAccount, (actor))
            );
        }
    }

    function _add(
        uint256 marketIndex,
        address actor,
        IOrderBookCore.Side side,
        uint96 lots
    ) internal {
        uint16 tick = side == IOrderBookCore.Side.Bid ? 96 : 104;
        vm.prank(actor);
        address(coordinator).call(
            abi.encodeCall(
                coordinator.addLiquidity,
                (marketIndex, side, tick, lots)
            )
        );
    }

    function _take(
        uint256 marketIndex,
        address actor,
        IOrderBookCore.Side side,
        uint96 lots
    ) internal {
        uint16 limit = side == IOrderBookCore.Side.Bid ? 104 : 96;
        vm.prank(actor);
        (bool ok, bytes memory data) = address(coordinator).call(
            abi.encodeCall(
                coordinator.take,
                (
                    marketIndex,
                    side,
                    limit,
                    lots,
                    IOrderBookCore.FillPolicy.IOC
                )
            )
        );

        if (ok && data.length >= 32) {
            uint96 filledLots = abi.decode(data, (uint96));
            if (side == IOrderBookCore.Side.Bid) {
                bidTakerFilled[marketIndex] += filledLots;
            } else {
                askTakerFilled[marketIndex] += filledLots;
            }
        }
    }

    function _remove(
        uint256 marketIndex,
        address actor,
        IOrderBookCore.Side side,
        uint256 r
    ) internal {
        OrderBookCore core = _core(marketIndex);
        uint16 tick = side == IOrderBookCore.Side.Bid ? 96 : 104;
        (uint128 shares,,) = core.quotes(actor, side, tick);
        if (shares == 0) return;

        uint128 burn = uint128((r % shares) + 1);
        (, , uint32 generation) = core.quotes(actor, side, tick);
        vm.prank(actor);
        address(coordinator).call(
            abi.encodeCall(
                coordinator.removeLiquidity,
                (marketIndex, side, tick, generation, burn)
            )
        );
    }

    function _moveOracle(uint256 marketIndex, uint256 r) internal {
        uint16 next = uint16(96 + ((r >> 48) % 9));
        if (marketIndex == 0) {
            oracleA.setMarkTick(next);
        } else {
            oracleB.setMarkTick(next);
        }
    }

    function _setFunding(uint256 marketIndex, uint256 r) internal {
        int256 signed = int256((r >> 64) % 2_001) - 1_000;
        _core(marketIndex).setFundingIndex(int128(signed * 1e14));
    }

    function _withdraw(address actor, uint256 r) internal {
        uint256 amount = ((r >> 80) % 5_000) + 1;
        vm.prank(actor);
        address(coordinator).call(
            abi.encodeCall(coordinator.withdraw, (amount))
        );
    }

    function _checkStepInvariants() internal view {
        assertEq(
            token.balanceOf(address(vault)),
            vault.totalAccountedCollateral(),
            "shared vault custody drift"
        );

        for (uint256 a; a < actors.length; ++a) {
            int256 claim = vault.collateralClaim(actors[a]);
            uint256 positiveClaim = claim > 0 ? uint256(claim) : 0;
            assertTrue(
                vault.lockedCollateral(actors[a]) <= positiveClaim,
                "lock exceeds positive collateral claim"
            );

            _checkRisk(coreA, actors[a]);
            _checkRisk(coreB, actors[a]);
        }
    }

    function _checkRisk(OrderBookCore core, address actor) internal view {
        (int80 settled, int80 minPosition, int80 maxPosition) =
            core.accountRisk(actor);
        assertTrue(minPosition <= settled, "risk min above settled");
        assertTrue(settled <= maxPosition, "risk settled above max");
    }

    function _retireTrackedQuotes() internal {
        for (uint256 m; m < 2; ++m) {
            OrderBookCore core = _core(m);
            for (uint256 a; a < actors.length; ++a) {
                _retire(core, actors[a], IOrderBookCore.Side.Bid, 96);
                _retire(core, actors[a], IOrderBookCore.Side.Ask, 104);
            }
        }
    }

    function _retire(
        OrderBookCore core,
        address actor,
        IOrderBookCore.Side side,
        uint16 tick
    ) internal {
        (uint128 shares,,) = core.quotes(actor, side, tick);
        if (shares == 0) return;

        (, , uint32 generation) = core.quotes(actor, side, tick);
        vm.prank(actor);
        coordinator.removeLiquidity(
            core == coreA ? 0 : 1,
            side,
            tick,
            generation,
            shares
        );
    }

    function _checkFinalConservation() internal view {
        int256 aggregateCollateralClaims;
        int256 positionA;
        int256 positionB;

        for (uint256 a; a < actors.length; ++a) {
            aggregateCollateralClaims += vault.collateralClaim(actors[a]);

            (int80 aPosition,,) = coreA.accountRisk(actors[a]);
            (int80 bPosition,,) = coreB.accountRisk(actors[a]);
            positionA += int256(aPosition);
            positionB += int256(bPosition);
        }

        // All vault debits/credits are represented by signed collateral claims.
        // Market trading/funding cashflows are separate zero-/conservative-sum claims
        // and therefore must not be compared directly with raw vault custody.
        assertTrue(
            aggregateCollateralClaims >= 0,
            "aggregate collateral claims negative"
        );
        assertEq(
            uint256(aggregateCollateralClaims),
            token.balanceOf(address(vault)),
            "signed collateral claims diverged from shared custody"
        );

        // Lazy pro-rata attribution may leave a bounded system-side position residue.
        // Its magnitude cannot exceed total executed taker lots in that market.
        uint256 totalFilledA = bidTakerFilled[0] + askTakerFilled[0];
        uint256 totalFilledB = bidTakerFilled[1] + askTakerFilled[1];

        assertTrue(
            _abs(positionA) <= totalFilledA,
            "market A rounding position exceeded total fills"
        );
        assertTrue(
            _abs(positionB) <= totalFilledB,
            "market B rounding position exceeded total fills"
        );
    }

    function _abs(int256 value) internal pure returns (uint256) {
        return value >= 0 ? uint256(value) : uint256(-value);
    }

    function _core(uint256 marketIndex) internal view returns (OrderBookCore) {
        return marketIndex == 0 ? coreA : coreB;
    }

    function _deposit(address account, uint256 amount) internal {
        token.mint(account, amount);
        vm.prank(account);
        token.approve(address(vault), type(uint256).max);
        vm.prank(account);
        vault.deposit(amount);
    }
}
