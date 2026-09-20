// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {VolatileFeeCalculation} from "../../../src/volatile/libraries/VolatileFeeCalculation.sol";
import {RelativeMove, RelativeMoveLibrary} from "../../../src/volatile/libraries/RelativeMoveLibrary.sol";
import {VolatileFeeConfig, VolatileFeeState} from "../../../src/volatile/interfaces/IVolatileFeeConfiguration.sol";

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

    /// @notice `expected <= actual <= expected + ROUNDING_TOLERANCE_E6`: the library rounds up to whole
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

    /// @notice The exact ratio `piE6 / 1e6` with a direction: a CSV PI cell as the library's input.
    function _moveFromE6(uint256 piE6, bool up) internal pure returns (RelativeMove) {
        return RelativeMoveLibrary.pack(piE6, VolatileFeeCalculation.ONE_E6, up);
    }

    /// @notice `piE6 - 1 <= move < piE6 + 1`, compared as exact ratios. The generator floors PI from unrounded
    ///         prices but the price columns carry 3 or 4 decimals, which moves the ratio rebuilt from them by up
    ///         to a third of a pip either way. s4 block 4, s5 block 2 and s8 block 4 land just under their cell.
    function assertMoveMatchesPI(RelativeMove move, uint256 piE6, string memory label) internal pure {
        assertTrue(piE6 == 0 || move.gte(piE6 - 1), string.concat(label, ": a pip or more under"));
        assertFalse(move.gte(piE6 + 1), string.concat(label, ": a pip or more over"));
    }

    function _feeConfig(uint24 skewRateE6, uint24 maxSkewStepE6, uint24 maxSkewE6)
        internal
        pure
        returns (VolatileFeeConfig memory config)
    {
        config.restingSpreadE6 = RESTING_SPREAD_E6;
        config.skewRateE6 = skewRateE6;
        config.maxSkewStepE6 = maxSkewStepE6;
        config.maxSkewE6 = maxSkewE6;
        config.backrunThresholdE6 = BACKRUN_THRESHOLD_E6;
        config.backrunCaptureFractionE6 = BACKRUN_CAPTURE_FRACTION_E6;
    }

    /// @notice `newPermAndTempFee` composed with `baselineFee` per side: h_ask and the f columns for one block.
    function _newPermAndBaselines(
        VolatileFeeConfig memory config,
        uint24 oldAskPermFeeE6,
        uint256 blockPriceImpactE6,
        bool blockPriceImpactUp
    ) internal pure returns (uint24 newAskPermFeeE6, uint24 askBaselineFeeE6, uint24 bidBaselineFeeE6) {
        return _newPermAndBaselines(config, oldAskPermFeeE6, _moveFromE6(blockPriceImpactE6, blockPriceImpactUp));
    }

    function _newPermAndBaselines(
        VolatileFeeConfig memory config,
        uint24 oldAskPermFeeE6,
        RelativeMove blockPriceImpact
    ) internal pure returns (uint24 newAskPermFeeE6, uint24 askBaselineFeeE6, uint24 bidBaselineFeeE6) {
        VolatileFeeState memory state;
        (state.askPermFeeE6, state.tempFeeE6, state.tempOnBid) =
            VolatileFeeCalculation.newPermAndTempFee(config, oldAskPermFeeE6, blockPriceImpact);
        newAskPermFeeE6 = state.askPermFeeE6;
        askBaselineFeeE6 = VolatileFeeCalculation.baselineFee(state, config.restingSpreadE6, false);
        bidBaselineFeeE6 = VolatileFeeCalculation.baselineFee(state, config.restingSpreadE6, true);
    }
}
