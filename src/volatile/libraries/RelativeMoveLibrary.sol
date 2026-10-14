// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @notice A relative price move, |P_new - P_ref| / P_ref, as an exact ratio with its direction, packed into
///         one word: bits 0-127 hold the numerator, bits 128-254 the denominator, bit 255 the direction.
/// @dev The move itself is never rounded. Each consumer scales it once with `mulUp`, so the only rounding
///      on the fee path is that final round up. The field widths are headroom, not a cost: masking a stack
///      word is the same gas at any width. relativeMove needs 96 and 97 bits; test vectors built from
///      (piE6, 1e6) need up to 117 bits of numerator.
type RelativeMove is uint256;

using RelativeMoveLibrary for RelativeMove global;

/// @title RelativeMoveLibrary
/// @notice Packing and single-rounding scaling for RelativeMove.
library RelativeMoveLibrary {
    uint256 private constant ONE_E6 = 1e6;
    uint256 private constant DENOMINATOR_OFFSET = 128;
    uint256 private constant NUMERATOR_MASK = type(uint128).max;
    uint256 private constant DENOMINATOR_MASK = (1 << 127) - 1;
    uint256 private constant INCREASED_FLAG = 1 << 255;

    /// @notice Packs a ratio and its direction.
    /// @param _numerator Ratio numerator, below 2**128
    /// @param _denominator Ratio denominator, nonzero and below 2**127
    /// @param _increased True if the price went up
    function pack(uint256 _numerator, uint256 _denominator, bool _increased) internal pure returns (RelativeMove) {
        return RelativeMove.wrap(_numerator | (_denominator << DENOMINATOR_OFFSET) | (_increased ? INCREASED_FLAG : 0));
    }

    function numerator(RelativeMove move) internal pure returns (uint256) {
        return RelativeMove.unwrap(move) & NUMERATOR_MASK;
    }

    function denominator(RelativeMove move) internal pure returns (uint256) {
        return (RelativeMove.unwrap(move) >> DENOMINATOR_OFFSET) & DENOMINATOR_MASK;
    }

    function increased(RelativeMove move) internal pure returns (bool) {
        return RelativeMove.unwrap(move) & INCREASED_FLAG != 0;
    }

    /// @notice `rateE6 * move`, rounded up. An E6 rate gives E6 pips. This is the only rounding on the fee path.
    /// @dev rateE6 < 2**24 and numerator < 2**128, so the product fits 256 bits.
    function mulUp(RelativeMove move, uint256 rateE6) internal pure returns (uint256) {
        return FixedPointMathLib.mulDivUp(rateE6, numerator(move), denominator(move));
    }

    /// @notice True if the move is at least `thresholdE6` pips. Exact, no rounding.
    function gte(RelativeMove move, uint256 thresholdE6) internal pure returns (bool) {
        return numerator(move) * ONE_E6 >= thresholdE6 * denominator(move);
    }
}
