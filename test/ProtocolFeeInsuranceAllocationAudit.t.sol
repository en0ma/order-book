// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {OrderBookCoreHarness} from "./harness/OrderBookCoreHarness.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {SegmentTreeExtremaOracle} from "../src/SegmentTreeExtremaOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Real fee accrual, owner allocation and insurance reserve accounting.
/// @dev No treasury payout is assumed; an accounting reclassification is not ERC20 withdrawal.
contract ProtocolFeeInsuranceAllocationAuditTest is TestBase {
    address internal constant MAKER = address(0xA01);
    address internal constant TAKER = address(0xA02);
    address internal constant ATTACKER = address(0xA03);

    MockERC20 internal token;
    OrderBookCoreHarness internal core;

    function setUp() public {
        token = new MockERC20();
        SegmentTreeExtremaOracle oracle =
            new SegmentTreeExtremaOracle(address(this), 100, 3600);
        core = new OrderBookCoreHarness(address(token), address(oracle), 40, 1000, 100, 0);
        _deposit(MAKER, 100000);
        _deposit(TAKER, 20000);

        vm.prank(MAKER);
        core.addLiquidity(IOrderBookCore.Side.Ask, 100, 100);
        vm.prank(TAKER);
        assertEq(
            uint256(core.take(IOrderBookCore.Side.Bid, 100, 100, IOrderBookCore.FillPolicy.IOC)),
            100,
            "initial matching failed"
        );
        assertEq(core.protocolFeesAccrued(), 100, "taker fee accrual incorrect");
    }

    function testOwnerAllocationReclassifiesOnlyFeeClaimsNotTokens() public {
        uint256 custody = token.balanceOf(address(core));
        uint256 makerClaim = _cashClaim(MAKER);
        uint256 takerClaim = _cashClaim(TAKER);

        core.allocateProtocolFeesToInsurance(40);
        assertEq(core.protocolFeesAccrued(), 60, "incorrect remaining fees");
        assertEq(core.insuranceReserves(), 40, "incorrect insurance allocation");
        assertEq(token.balanceOf(address(core)), custody, "allocation withdrew collateral");
        assertEq(_cashClaim(MAKER), makerClaim, "maker claim changed");
        assertEq(_cashClaim(TAKER), takerClaim, "taker claim changed");

        core.allocateProtocolFeesToInsurance(60);
        assertEq(core.protocolFeesAccrued(), 0, "residual fee balance");
        assertEq(core.insuranceReserves(), 100, "allocation did not add up");
        assertEq(token.balanceOf(address(core)), custody, "second allocation moved custody");
    }

    function testNonOwnerCannotAllocateEvenIfFeesAvailable() public {
        uint256 custody = token.balanceOf(address(core));
        vm.prank(ATTACKER);
        (bool ok,) = address(core).call(
            abi.encodeCall(core.allocateProtocolFeesToInsurance, (uint256(50)))
        );
        assertTrue(!ok, "unauthorized allocation accepted");
        assertEq(core.protocolFeesAccrued(), 100, "unauthorized fee mutation");
        assertEq(core.insuranceReserves(), 0, "unauthorized insurance mutation");
        assertEq(token.balanceOf(address(core)), custody, "unauthorized custody mutation");
    }

    function testZeroAndOverAllocationRevertWithoutStateChange() public {
        uint256 custody = token.balanceOf(address(core));
        (bool zero,) = address(core).call(
            abi.encodeCall(core.allocateProtocolFeesToInsurance, (uint256(0)))
        );
        assertTrue(!zero, "zero allocation accepted");
        (bool over,) = address(core).call(
            abi.encodeCall(core.allocateProtocolFeesToInsurance, (uint256(101)))
        );
        assertTrue(!over, "over allocation accepted");
        assertEq(core.protocolFeesAccrued(), 100, "failed allocation spent fees");
        assertEq(core.insuranceReserves(), 0, "failed allocation funded insurance");
        assertEq(token.balanceOf(address(core)), custody, "failed allocation moved collateral");
    }

    function testExternalInsuranceFundingAndFeeReclassificationAreDistinct() public {
        token.mint(address(this), 75);
        token.approve(address(core), 75);
        uint256 custody = token.balanceOf(address(core));
        core.fundInsurance(75);
        assertEq(token.balanceOf(address(core)), custody + 75, "funding not physically deposited");

        core.allocateProtocolFeesToInsurance(25);
        assertEq(core.insuranceReserves(), 100, "combined insurance reserve incorrect");
        assertEq(core.protocolFeesAccrued(), 75, "incorrect remaining protocol fees");
        assertEq(token.balanceOf(address(core)), custody + 75, "allocation transferred tokens");
    }

    function _deposit(address who, uint256 amount) internal {
        token.mint(who, amount);
        vm.prank(who);
        token.approve(address(core), amount);
        vm.prank(who);
        core.depositCollateral(amount);
    }

    function _cashClaim(address who) internal view returns (uint256) {
        (uint256 collateral,,,,) = core.accountingStateTest(who);
        return collateral;
    }
}
