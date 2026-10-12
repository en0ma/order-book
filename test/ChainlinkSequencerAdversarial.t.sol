// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {ChainlinkPriceSource} from "../src/ChainlinkPriceSource.sol";

/// @dev Arbitrary AggregatorV3 feed for malformed price/sequencer round tests.
contract AdversarialAggregatorV3 {
    uint8 public immutable decimals;
    uint80 public roundId = 1;
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;
    uint80 public answeredInRound = 1;

    constructor(uint8 decimals_, int256 answer_) {
        decimals = decimals_;
        answer = answer_;
        startedAt = block.timestamp;
        updatedAt = block.timestamp;
    }

    function setRound(
        uint80 roundId_, int256 answer_, uint256 startedAt_,
        uint256 updatedAt_, uint80 answeredInRound_
    ) external {
        roundId = roundId_;
        answer = answer_;
        startedAt = startedAt_;
        updatedAt = updatedAt_;
        answeredInRound = answeredInRound_;
    }

    function latestRoundData()
        external view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}

contract ChainlinkSequencerAdversarialTest is TestBase {
    AdversarialAggregatorV3 internal price;
    AdversarialAggregatorV3 internal sequencer;
    ChainlinkPriceSource internal source;

    function setUp() public {
        vm.warp(10_000);
        price = new AdversarialAggregatorV3(8, 100e8);
        sequencer = new AdversarialAggregatorV3(0, 0);
        sequencer.setRound(1, 0, 9_000, 9_900, 1);
        source = new ChainlinkPriceSource(address(price), address(sequencer), 60, 300);
    }

    function _assertRejected(bytes4 selector) internal {
        (bool ok, bytes memory reason) =
            address(source).call(abi.encodeCall(source.latestPrice, ()));
        assertTrue(!ok, "unsafe feed round accepted");
        assertTrue(reason.length >= 4 && bytes4(reason) == selector, "wrong error selector");
    }

    function testValidSequencerAndPriceReturnSourceTimestamp() public {
        (int256 answer, uint256 confidence, uint48 published) = source.latestPrice();
        assertEq(answer, int256(100e8), "price changed");
        assertEq(confidence, 0, "Chainlink confidence incorrectly inferred");
        assertEq(uint256(published), 10_000, "source time changed");
    }

    function testRejectsSequencerDown() public {
        sequencer.setRound(2, 1, 9_000, 9_999, 2);
        _assertRejected(ChainlinkPriceSource.SequencerUnavailable.selector);
    }

    function testRejectsSequencerRecoveryInsideGracePeriod() public {
        sequencer.setRound(2, 0, 9_701, 9_999, 2);
        _assertRejected(ChainlinkPriceSource.SequencerUnavailable.selector);
    }

    function testRejectsIncompleteSequencerRound() public {
        sequencer.setRound(2, 0, 9_000, 9_999, 1);
        _assertRejected(ChainlinkPriceSource.SequencerUnavailable.selector);
    }

    function testRejectsFutureSequencerTimestamp() public {
        sequencer.setRound(2, 0, 10_001, 10_001, 2);
        _assertRejected(ChainlinkPriceSource.SequencerUnavailable.selector);
    }

    function testRejectsIncompletePriceRound() public {
        price.setRound(3, 100e8, 9_999, 10_000, 2);
        _assertRejected(ChainlinkPriceSource.InvalidRound.selector);
    }

    function testRejectsStalePriceEvenWithHealthySequencer() public {
        price.setRound(2, 100e8, 9_800, 9_939, 2);
        _assertRejected(ChainlinkPriceSource.StaleRound.selector);
    }

    function testRejectsNonPositivePrice() public {
        price.setRound(2, 0, 9_999, 10_000, 2);
        _assertRejected(ChainlinkPriceSource.InvalidRound.selector);
    }

    function testHeartbeatBoundaryAccepted() public {
        price.setRound(2, 100e8, 9_940, 9_940, 2);
        (int256 answer,, uint48 publishTime) = source.latestPrice();
        assertEq(answer, int256(100e8), "heartbeat boundary rejected");
        assertEq(uint256(publishTime), 9_940, "unexpected heartbeat time");
    }
}
