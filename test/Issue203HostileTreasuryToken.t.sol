// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {MockMarkOracle} from "./mocks/MockMarkOracle.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";

interface IFeeDistributableCore {
    function withdrawProtocolFees(uint256 amount) external;
}

/// @notice Active Core owner during the recursive transfer test. The token
/// can behave as an ERC20 that attempts to recursively authorize itself.
contract Issue203HostileTreasuryToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public extraDebit;
    uint256 public recipientShortfall;
    bool public attemptCallback;
    bool public callbackRejected;
    bytes public callbackData;

    function mint(address account, uint256 amount) external {
        balanceOf[account] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 remaining = allowance[from][msg.sender];
        require(remaining >= amount, "not authorized");
        if (remaining != type(uint256).max) allowance[from][msg.sender] = remaining - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function configure(uint256 extra, uint256 shortfall, bool recursive) external {
        extraDebit = extra;
        recipientShortfall = shortfall;
        attemptCallback = recursive;
    }

    function setCallbackData(bytes calldata data) external { callbackData = data; }

    function transfer(address recipient, uint256 amount) external returns (bool) {
        if (attemptCallback) {
            bytes memory data = callbackData;
            if (data.length == 0) {
                data = abi.encodeWithSignature("withdrawProtocolFees(uint256)", uint256(1));
            }
            (bool succeeded,) = msg.sender.call(data);
            callbackRejected = !succeeded;
        }

        uint256 debit = amount + extraDebit;
        balanceOf[msg.sender] -= debit;
        balanceOf[recipient] += amount - recipientShortfall;
        return true;
    }

    function beginWithdrawal(address core, uint256 amount) external {
        IFeeDistributableCore(core).withdrawProtocolFees(amount);
    }
}

contract Issue203HostileTreasuryTokenTest is TestBase {
    address internal constant MAKER = address(0xA11CE);
    address internal constant TAKER = address(0xB0B);
    address internal constant TREASURY = address(0xFEED);

    Issue203HostileTreasuryToken internal token;
    OrderBookCore internal core;

    function setUp() public {
        token = new Issue203HostileTreasuryToken();
        core = new OrderBookCore(address(token), address(new MockMarkOracle(100)), 30, 1000, 100, 0);
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

        core.configureTreasuryRecipient(TREASURY);
        core.setFeeDistributionEnabled(true);
        core.transferOwnership(address(token));
    }

    function test_RecursiveERC20OwnerCannotReenterTreasuryFeeDistribution() public {
        token.configure(0, 0, true);
        token.beginWithdrawal(address(core), 50);
        assertTrue(token.callbackRejected(), "recursive payout succeeded");
        assertEq(core.protocolFeesAccrued(), 150, "recursive fee was debited");
        assertEq(token.balanceOf(TREASURY), 50, "reentrant transfer overpaid treasury");
        assertEq(token.balanceOf(address(core)), 99950, "reentrant transfer took user backing");
    }

    function testFuzz_ExtraTokenDebitRollsBackEntireFeeTransaction(uint8 extraSeed) public {
        token.configure(uint256(extraSeed) + 1, 0, false);
        (bool succeeded,) = address(token).call(
            abi.encodeCall(token.beginWithdrawal, (address(core), uint256(50)))
        );
        assertTrue(!succeeded, "extra token debit escaped atomic rollback");
        assertEq(core.protocolFeesAccrued(), 200, "failed fee payout altered ledger");
        assertEq(token.balanceOf(TREASURY), 0, "failed fee payout moved tokens");
        assertEq(token.balanceOf(address(core)), 100000, "failed fee payout consumed collateral");
    }

    function testFuzz_RecipientUndercreditRollsBackEntireFeeTransaction(uint8 seed) public {
        uint256 shortfall = uint256(seed) % 50 + 1;
        token.configure(0, shortfall, false);
        (bool succeeded,) = address(token).call(
            abi.encodeCall(token.beginWithdrawal, (address(core), uint256(50)))
        );
        assertTrue(!succeeded, "undercredited recipient accepted fee transfer");
        assertEq(core.protocolFeesAccrued(), 200, "failed fee payout altered fee ledger");
        assertEq(token.balanceOf(TREASURY), 0, "undercredit sent tokens");
        assertEq(token.balanceOf(address(core)), 100000, "undercredit spent custody");
    }
}
