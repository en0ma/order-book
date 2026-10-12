// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {LiquidationPolicy} from "../src/deployable/LiquidationPolicy.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev Deliberately untrusted oracle: mutable mark, arbitrary values, and revert.
contract AdversarialMarkOracle {
    uint16 public markTick;
    bool public shouldRevert;

    constructor(uint16 initialMark) { markTick = initialMark; }
    function setMark(uint16 nextMark) external { markTick = nextMark; }
    function setRevert(bool next) external { shouldRevert = next; }
    function readMark() external view returns (uint16) { return this.markTick(); }
}

/// @dev The Core calls markTick(), so this adapter simulates a reverting feed.
contract RevertingMarkOracle {
    uint16 internal mark;
    bool public shouldRevert;
    constructor(uint16 initialMark) { mark = initialMark; }
    function setMark(uint16 nextMark) external { mark = nextMark; }
    function setRevert(bool next) external { shouldRevert = next; }
    function markTick() external view returns (uint16) {
        require(!shouldRevert, "oracle unavailable");
        return mark;
    }
}

contract OracleTrustBoundaryAuditTest is TestBase {
    RevertingMarkOracle internal oracle;
    MockERC20 internal token;
    OrderBookCore internal core;
    LiquidationPolicy internal policy;

    function setUp() public {
        oracle = new RevertingMarkOracle(100);
        token = new MockERC20();
        core = new OrderBookCore(address(token), address(oracle), 30, 1000, 0, 0);
        policy = new LiquidationPolicy(address(core), address(new FixedOrderCountGateway()), 500);
    }

    function testCorePassesThroughZeroAndExtremeOracleMarks() public {
        oracle.setMark(0);
        assertEq(uint256(core.currentMarkTick()), 0, "zero mark was normalized");
        oracle.setMark(type(uint16).max);
        assertEq(uint256(core.currentMarkTick()), type(uint16).max, "max mark was clamped");
    }

    function testOracleRevertPropagatesToRiskAndLiquidationReads() public {
        oracle.setRevert(true);
        (bool markOk,) = address(core).call(abi.encodeCall(core.currentMarkTick, ()));
        assertTrue(!markOk, "unavailable oracle mark unexpectedly returned");
        (bool marginOk,) = address(policy).call(
            abi.encodeCall(policy.maintenanceRequirementForPosition, (int80(1)))
        );
        assertTrue(!marginOk, "maintenance risk read silently used a mark");
        assertEq(token.balanceOf(address(core)), 0, "unexpected custody change");
    }

    function testUntrustedMarkDoesNotChangeIdleAccountEquity() public {
        oracle.setMark(0);
        assertEq(core.accountEquity(address(this)), int256(0), "zero mark affected idle equity");
        oracle.setMark(type(uint16).max);
        assertEq(core.accountEquity(address(this)), int256(0), "extreme mark affected idle equity");
    }
}

contract FixedOrderCountGateway {
    function activeAdvancedOrders(address) external pure returns (uint32) { return 0; }
    function executionStrategyModule() external pure returns (address) { return address(0); }
}
