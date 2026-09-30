// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface Vm {
    function prank(address) external;
    function envString(string calldata) external returns (string memory);
    function createSelectFork(string calldata) external returns (uint256);
    function deal(address account, uint256 newBalance) external;
}

abstract contract TestBase {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function assertEq(uint256 a, uint256 b, string memory message) internal pure {
        require(a == b, message);
    }

    function assertEq(int256 a, int256 b, string memory message) internal pure {
        require(a == b, message);
    }

    function assertTrue(bool value, string memory message) internal pure {
        require(value, message);
    }

    function boundNonZero(uint256 x, uint256 max) internal pure returns (uint96) {
        return uint96((x % max) + 1);
    }
}
