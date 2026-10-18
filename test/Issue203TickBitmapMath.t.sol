// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {TickBitmapMathModule} from "../src/deployable/TickBitmapMathModule.sol";

contract Issue203TickBitmapMathTest is TestBase {
    TickBitmapMathModule internal scanner;

    function setUp() public {
        scanner = new TickBitmapMathModule();
    }

    function testFuzz_ExtractedEdgesMatchReferenceForEveryNonzeroWord(uint256 word) public {
        if (word == 0) return;

        uint8 low;
        uint8 high;
        // Scan a separate reference implementation from the two ends.
        while ((word & (uint256(1) << low)) == 0) {
            unchecked { ++low; }
        }
        high = 255;
        while ((word & (uint256(1) << high)) == 0) {
            unchecked { --high; }
        }
        assertEq(uint256(scanner.edgeBit(true, word)), uint256(low), "ask edge changed");
        assertEq(uint256(scanner.edgeBit(false, word)), uint256(high), "bid edge changed");
    }

    function testZeroWordFailsClosedForBothSides() public {
        (bool askOk,) = address(scanner).call(
            abi.encodeCall(scanner.edgeBit, (true, uint256(0)))
        );
        (bool bidOk,) = address(scanner).call(
            abi.encodeCall(scanner.edgeBit, (false, uint256(0)))
        );
        assertTrue(!askOk, "empty ask word yielded phantom tick");
        assertTrue(!bidOk, "empty bid word yielded phantom tick");
    }
}
