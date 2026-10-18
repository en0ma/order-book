// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Pure bitmap edge search split from deployable Core runtime.
/// @dev A zero word is invalid, matching the former Core helper.
contract TickBitmapMathModule {
    error InsufficientLiquidity();

    function edgeBit(bool ascending, uint256 x) external pure returns (uint8 r) {
        if (x == 0) revert InsufficientLiquidity();
        if (ascending) {
            unchecked {
                x &= ~x + 1;
            }
        }
        assembly ("memory-safe") {
            let f := shl(7, iszero(iszero(shr(128, x))))
            x := shr(f, x)
            r := f

            f := shl(6, iszero(iszero(shr(64, x))))
            x := shr(f, x)
            r := or(r, f)

            f := shl(5, iszero(iszero(shr(32, x))))
            x := shr(f, x)
            r := or(r, f)

            f := shl(4, iszero(iszero(shr(16, x))))
            x := shr(f, x)
            r := or(r, f)

            f := shl(3, iszero(iszero(shr(8, x))))
            x := shr(f, x)
            r := or(r, f)

            f := shl(2, iszero(iszero(shr(4, x))))
            x := shr(f, x)
            r := or(r, f)

            f := shl(1, iszero(iszero(shr(2, x))))
            x := shr(f, x)
            r := or(r, f)

            r := or(r, iszero(iszero(shr(1, x))))
        }
    }
}
