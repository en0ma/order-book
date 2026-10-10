// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ChainlinkPriceSource} from "../src/ChainlinkPriceSource.sol";
import {CorroboratedPriceSource} from "../src/CorroboratedPriceSource.sol";
import {TestBase} from "./TestBase.sol";

/// @notice Exercises the guard against genuine deployed Ethereum price feeds.
contract CorroboratedPriceSourceMainnetForkTest is TestBase {
    address internal constant ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address internal constant BTC_USD = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;

    function testRejectsDifferentUnderlyingMarketsOnLiveFeeds() public {
        vm.createSelectFork(vm.envString("ETH_RPC"));
        assertEq(block.chainid, 1, "wrong fork chain");
        ChainlinkPriceSource ethSource =
            new ChainlinkPriceSource(ETH_USD, address(0), 3 days, 0);
        ChainlinkPriceSource btcSource =
            new ChainlinkPriceSource(BTC_USD, address(0), 3 days, 0);

        CorroboratedPriceSource guarded = new CorroboratedPriceSource(
            address(ethSource), address(btcSource),
            ethSource.sourceScale(), btcSource.sourceScale(), 3 days, 100
        );
        (bool ok, bytes memory returndata) =
            address(guarded).call(abi.encodeCall(guarded.latestPrice, ()));
        assertTrue(!ok, "unrelated ETH and BTC prices were corroborated");
        assertTrue(
            returndata.length >= 4 &&
            bytes4(returndata) == CorroboratedPriceSource.SourceDeviation.selector,
            "unexpected rejection reason"
        );
    }

    function testRejectsIdenticalSourceAddresses() public {
        vm.createSelectFork(vm.envString("ETH_RPC"));
        ChainlinkPriceSource source =
            new ChainlinkPriceSource(ETH_USD, address(0), 3 days, 0);
        (bool ok,) = address(this).call(
            abi.encodeWithSelector(
                this.deploySameSource.selector, address(source), source.sourceScale()
            )
        );
        assertTrue(!ok, "one source accepted as two independent sources");
    }

    function deploySameSource(address source, uint256 scale) external {
        new CorroboratedPriceSource(source, source, scale, scale, 3 days, 100);
    }
}
