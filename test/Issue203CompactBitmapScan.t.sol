// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {TestBase} from "./TestBase.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMarkOracle} from "./mocks/MockMarkOracle.sol";

// Test only the internal bitmap primitive without a second production module.
contract CoreBitmapScanHarness is OrderBookCore {
    constructor()
        OrderBookCore(address(new MockERC20()), address(new MockMarkOracle(100)), 20, 1000, 0, 0)
    {}

    function scan(uint256 word) external pure returns (uint8) {
        return _msb(word);
    }
}

contract Issue203CompactBitmapScanTest is TestBase {
    CoreBitmapScanHarness internal core;

    function setUp() public {
        core = new CoreBitmapScanHarness();
    }

    function testFuzz_EightStepScanMatchesReference(uint256 word) public {
        if (word == 0) return;
        uint256 bit = 255;
        while ((word & (uint256(1) << bit)) == 0) {
            unchecked { --bit; }
        }
        assertEq(uint256(core.scan(word)), bit, "compact msb scan diverged");
    }

    function testBoundaryBitsAndZeroRejection() public {
        assertEq(uint256(core.scan(1)), 0, "lowest bit wrong");
        assertEq(uint256(core.scan(uint256(1) << 255)), 255, "highest bit wrong");
        assertEq(uint256(core.scan(type(uint256).max)), 255, "full word wrong");
        (bool success,) = address(core).call(abi.encodeCall(core.scan, (uint256(0))));
        assertTrue(!success, "empty word accepted");
    }
}
