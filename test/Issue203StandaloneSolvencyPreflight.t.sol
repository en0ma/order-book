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
}
