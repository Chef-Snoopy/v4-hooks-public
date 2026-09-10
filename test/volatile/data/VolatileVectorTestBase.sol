// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {VolatileHookState} from "../../../src/volatile/interfaces/IVolatileFeeConfiguration.sol";

/// @title VolatileVectorTestBase
/// @notice Shared scaffolding for the reference-generator vector suites under test/volatile/data/.
/// @dev Fees and PI are E6 pips (bps * 100). CSV cells are floored from the generator's exact rationals;
///      flags are checked exactly. Column legend: h = permanent fee, g = temporary (one-block) fee,
///      f = h + g = first-swap baseline; a signed piE6 > 0 is an up-move (ask leans). Spec symbols:
///      RS restingSpread, alpha_top skewRate, d_top maxSkewStep, h_max maxSkew, cutoff backrunThreshold,
///      c backrunCaptureFraction, alpha_mid midFadeRate, d_mid maxMidFade.
abstract contract VolatileVectorTestBase is Test {
    uint256 internal constant ROUNDING_TOLERANCE_E6 = 1;

    // Shared by every scenario; skew rate, step and ceiling vary per suite.
    uint24 internal constant RESTING_SPREAD_E6 = 900;
    uint24 internal constant BACKRUN_THRESHOLD_E6 = 1000;
    uint24 internal constant BACKRUN_CAPTURE_FRACTION_E6 = 500_000;
    uint24 internal constant NEUTRAL_PERM_FEE_E6 = RESTING_SPREAD_E6 / 2;

    /// @notice `expected <= actual <= expected + ROUNDING_TOLERANCE_E6`: the library truncates to whole
    ///         pips, so it may land one pip above a floored reference, never below.
    function assertGeWithinPip(uint256 actual, uint256 expected, string memory label) internal pure {
        assertGe(actual, expected, string.concat(label, ": below reference"));
        assertLe(actual, expected + ROUNDING_TOLERANCE_E6, string.concat(label, ": more than a pip over"));
    }

    function _dataLines(string memory path) internal view returns (string[] memory lines) {
        string[] memory raw = vm.split(vm.readFile(path), "\n");

        uint256 count;
        for (uint256 i = 1; i < raw.length; i++) {
            if (bytes(raw[i]).length != 0) count++;
        }
        require(count > 0, "no rows parsed from CSV");

        lines = new string[](count);
        uint256 index;
        for (uint256 i = 1; i < raw.length; i++) {
            if (bytes(raw[i]).length != 0) lines[index++] = raw[i];
        }
    }

    /// @notice sqrt(price) in Q96 for a token1/token0 price `scaledPrice / priceOne`.
    /// @param scaledPrice Price column value
    /// @param priceOne Column scale: 1 for whole prices, 1e3 for three decimals
    function _sqrtPriceX96(uint256 scaledPrice, uint256 priceOne) internal pure returns (uint160) {
        return uint160(
            FixedPointMathLib.sqrt(
                FixedPointMathLib.fullMulDiv(
                    uint256(FixedPoint96.Q96) * uint256(FixedPoint96.Q96), scaledPrice, priceOne
                )
            )
        );
    }

    function _abs(int256 x) internal pure returns (uint256) {
        return x < 0 ? uint256(-x) : uint256(x);
    }

    function _label(string memory row, string memory column) internal pure returns (string memory) {
        return string.concat(row, " ", column);
    }

    function _hookState(uint24 skewRateE6, uint24 maxSkewStepE6, uint24 maxSkewE6)
        internal
        pure
        returns (VolatileHookState memory hookState)
    {
        hookState.restingSpreadE6 = RESTING_SPREAD_E6;
        hookState.skewRateE6 = skewRateE6;
        hookState.maxSkewStepE6 = maxSkewStepE6;
        hookState.maxSkewE6 = maxSkewE6;
        hookState.backrunThresholdE6 = BACKRUN_THRESHOLD_E6;
        hookState.backrunCaptureFractionE6 = BACKRUN_CAPTURE_FRACTION_E6;
    }
}
