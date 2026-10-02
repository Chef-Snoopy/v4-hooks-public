// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {VolatileFuzzTestBase} from "../base/VolatileFuzzTestBase.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {VolatileFeeCalculation} from "../../../src/volatile/libraries/VolatileFeeCalculation.sol";
import {RelativeMove} from "../../../src/volatile/libraries/RelativeMoveLibrary.sol";
import {VolatileFeeConfig, VolatileFeeState} from "../../../src/volatile/interfaces/IVolatileFeeConfiguration.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

contract VolatileFeeCalculationTest is VolatileFuzzTestBase {
    uint256 internal constant ONE_E6 = VolatileFeeCalculation.ONE_E6;

    uint160 internal constant MIN_SQRT_PRICE = TickMath.MIN_SQRT_PRICE;
    uint160 internal constant MAX_SQRT_PRICE = TickMath.MAX_SQRT_PRICE;
    uint160 internal constant SQRT_PRICE_1_1 = Constants.SQRT_PRICE_1_1; // 2**96

    /// relativeMove's largest output in E6, from the ratioX96 == 0 clamp. Fed back through `_moveFromE6` its
    /// numerator is below 2**117, so rate * numerator (rate < 2**24) cannot overflow `mulUp`.
    uint256 internal constant MAX_PI_E6 = (FixedPoint96.Q96 - 1) * ONE_E6;

    /// floor(sqrt(2) * 2**96)
    uint160 internal constant SQRT_PRICE_2_1 = 112045541949572279837463876454;

    uint24 internal constant RS_E6 = 3000;
    uint24 internal constant NEUTRAL_PERM_E6 = RS_E6 / 2;
    uint24 internal constant BCF_E6 = 500_000;
    uint24 internal constant BACKRUN_THRESHOLD_E6 = 2000;
    uint24 internal constant MID_FADE_RATE_E6 = 200_000;
    uint24 internal constant MAX_MID_FADE_E6 = 5000;
    uint24 internal constant SKEW_RATE_E6 = 100_000;
    uint24 internal constant MAX_SKEW_STEP_E6 = 400;
    uint24 internal constant MAX_SKEW_E6 = 2000;

    // -------------------------------------------------------------------------
    // relativeMove
    // -------------------------------------------------------------------------

    /// The ratioX96 == 0 clamp sits one part in Q96 under 100%; a down move never reaches ONE_E6.
    function test_relativeMove_downMove_isBoundedByOneE6() public pure {
        RelativeMove full = VolatileFeeCalculation.relativeMove(MIN_SQRT_PRICE, MAX_SQRT_PRICE - 1);
        assertTrue(full.gte(ONE_E6 - 1), "full move below the last pip");
        assertFalse(full.gte(ONE_E6), "full move reached 100%");
        assertFalse(full.increased());

        // A 2x down move in PRICE space. floor(sqrt(2) * 2**96) is below the exact reference, so the true move is
        // just under 500_000; the Q48 floor of 2**144 / ref pushes ratioX96 below 2**95 and the ratio just over
        // 500_000. The one rounding in the ratio enlarges the move: rounding favours LPs.
        RelativeMove halved = VolatileFeeCalculation.relativeMove(SQRT_PRICE_1_1, SQRT_PRICE_2_1);
        assertTrue(halved.gte(ONE_E6 / 2), "halved below 50%");
        assertFalse(halved.gte(ONE_E6 / 2 + 1), "halved a pip or more over 50%");
        assertFalse(halved.increased());

        RelativeMove equal = VolatileFeeCalculation.relativeMove(SQRT_PRICE_1_1, SQRT_PRICE_1_1);
        assertEq(equal.numerator(), 0);
        assertFalse(equal.gte(1), "equal prices moved");
        assertFalse(equal.increased());
    }

    /// The move is carried as a ratio; scaling it once rounds up once. A 6.5 pip move at skewRate 0.15 is an
    /// exact step of 0.975, so the step is 1, not the 2 that ceil(0.15 * ceil(6.5)) gives.
    function test_relativeMove_mulUp_roundsOnce() public pure {
        uint160 sqrtNew = uint160(uint256(SQRT_PRICE_1_1) + uint256(SQRT_PRICE_1_1) * 32_499_947 / 1e13);
        RelativeMove move = VolatileFeeCalculation.relativeMove(sqrtNew, SQRT_PRICE_1_1);
        assertTrue(move.gte(6), "move below 6 pips");
        assertFalse(move.gte(7), "move reached 7 pips");
        assertEq(move.mulUp(150_000), 1);
    }

    function test_fuzz_relativeMove_upMove_monotoneNonDecreasing(uint160 refSeed, uint160 aSeed, uint160 bSeed)
        public
        pure
    {
        uint160 ref = uint160(bound(uint256(refSeed), MIN_SQRT_PRICE, MAX_SQRT_PRICE - 2));
        uint160 a = uint160(bound(uint256(aSeed), ref, MAX_SQRT_PRICE - 1));
        uint160 b = uint160(bound(uint256(bSeed), a, MAX_SQRT_PRICE - 1));

        RelativeMove moveA = VolatileFeeCalculation.relativeMove(a, ref);
        RelativeMove moveB = VolatileFeeCalculation.relativeMove(b, ref);

        assertTrue(_lte(moveA, moveB), "PI must not decrease as the up-move grows");
        assertEq(moveA.increased(), a > ref, "direction flag for a");
        assertEq(moveB.increased(), b > ref, "direction flag for b");
    }

    function test_fuzz_relativeMove_downMove_boundedAndMonotone(uint160 refSeed, uint160 aSeed, uint160 bSeed)
        public
        pure
    {
        uint160 ref = uint160(bound(uint256(refSeed), MIN_SQRT_PRICE, MAX_SQRT_PRICE - 1));
        uint160 b = uint160(bound(uint256(bSeed), MIN_SQRT_PRICE, ref));
        uint160 a = uint160(bound(uint256(aSeed), MIN_SQRT_PRICE, b));

        RelativeMove moveA = VolatileFeeCalculation.relativeMove(a, ref);
        RelativeMove moveB = VolatileFeeCalculation.relativeMove(b, ref);

        assertFalse(moveA.gte(ONE_E6), "down-move PI reached 100%");
        assertFalse(moveB.gte(ONE_E6), "down-move PI reached 100%");
        assertTrue(_lte(moveB, moveA), "a further below ref must not report a smaller PI than b");
        assertFalse(moveA.increased(), "direction flag for a");
        assertFalse(moveB.increased(), "direction flag for b");
    }

    // -------------------------------------------------------------------------
    // displacementBackrunFee
    // -------------------------------------------------------------------------

    function test_displacementBackrunFee_pointValues() public pure {
        assertEq(VolatileFeeCalculation.displacementBackrunFee(NEUTRAL_PERM_E6, _moveFromE6(0, false), BCF_E6), 1500);
        assertEq(
            VolatileFeeCalculation.displacementBackrunFee(NEUTRAL_PERM_E6, _moveFromE6(10_000, false), BCF_E6), 6500
        );
        assertEq(VolatileFeeCalculation.displacementBackrunFee(NEUTRAL_PERM_E6, _moveFromE6(1, false), BCF_E6), 1501);
        assertEq(VolatileFeeCalculation.displacementBackrunFee(NEUTRAL_PERM_E6, _moveFromE6(2_000_000, false), 0), 1500);
    }

    function test_displacementBackrunFee_clampsToMaxFee() public pure {
        assertEq(
            VolatileFeeCalculation.displacementBackrunFee(
                NEUTRAL_PERM_E6, _moveFromE6(2_000_000, false), uint24(ONE_E6)
            ),
            MAX_FEE_E6
        );
        assertEq(
            VolatileFeeCalculation.displacementBackrunFee(0, _moveFromE6(MAX_PI_E6, false), uint24(ONE_E6)), MAX_FEE_E6
        );
    }

    function test_fuzz_displacementBackrunFee_boundedAndMonotone(
        uint24 baselineSeed,
        uint256 dispSeedA,
        uint256 dispSeedB,
        uint24 bcfSeed
    ) public pure {
        uint24 baselineFeeE6 = uint24(bound(uint256(baselineSeed), 0, MAX_FEE_E6));
        uint256 dispAE6 = bound(dispSeedA, 0, MAX_PI_E6);
        uint256 dispBE6 = bound(dispSeedB, dispAE6, MAX_PI_E6);
        uint24 bcfE6 = uint24(bound(uint256(bcfSeed), 0, ONE_E6));

        uint24 feeAE6 = VolatileFeeCalculation.displacementBackrunFee(baselineFeeE6, _moveFromE6(dispAE6, false), bcfE6);
        uint24 feeBE6 = VolatileFeeCalculation.displacementBackrunFee(baselineFeeE6, _moveFromE6(dispBE6, false), bcfE6);

        assertGe(feeAE6, baselineFeeE6, "fee below baseline");
        assertLe(feeBE6, MAX_FEE_E6, "fee above ceiling");
        assertLe(feeAE6, feeBE6, "larger displacement pays less");
    }

    // -------------------------------------------------------------------------
    // displacementContinuingFee
    // -------------------------------------------------------------------------

    function test_displacementContinuingFee_pointValues() public pure {
        assertEq(
            VolatileFeeCalculation.displacementContinuingFee(
                NEUTRAL_PERM_E6, _moveFromE6(0, false), MID_FADE_RATE_E6, MAX_MID_FADE_E6
            ),
            1500
        );
        assertEq(
            VolatileFeeCalculation.displacementContinuingFee(
                NEUTRAL_PERM_E6, _moveFromE6(10_000, false), MID_FADE_RATE_E6, MAX_MID_FADE_E6
            ),
            3500
        );
        assertEq(
            VolatileFeeCalculation.displacementContinuingFee(
                NEUTRAL_PERM_E6, _moveFromE6(1, false), MID_FADE_RATE_E6, MAX_MID_FADE_E6
            ),
            1501
        );
        assertEq(
            VolatileFeeCalculation.displacementContinuingFee(
                NEUTRAL_PERM_E6, _moveFromE6(100_000, false), MID_FADE_RATE_E6, MAX_MID_FADE_E6
            ),
            6500
        );
        assertEq(
            VolatileFeeCalculation.displacementContinuingFee(
                NEUTRAL_PERM_E6, _moveFromE6(10_000, false), 0, MAX_MID_FADE_E6
            ),
            1500
        );
    }

    /// The library clamps baseline + fade (here 2 * MAX_FEE_E6) to the ceiling; the hook adds no clamp of its own.
    function test_displacementContinuingFee_clampsToMaxFee() public pure {
        assertEq(
            VolatileFeeCalculation.displacementContinuingFee(MAX_FEE_E6, _moveFromE6(MAX_PI_E6, false), 1, MAX_FEE_E6),
            MAX_FEE_E6
        );
    }

    function test_fuzz_displacementContinuingFee_boundedAndMonotone(
        uint24 baselineSeed,
        uint256 dispSeedA,
        uint256 dispSeedB,
        uint24 rateE6,
        uint24 maxFadeSeed
    ) public pure {
        uint24 baselineFeeE6 = uint24(bound(uint256(baselineSeed), 0, MAX_FEE_E6));
        uint256 dispAE6 = bound(dispSeedA, 0, MAX_PI_E6);
        uint256 dispBE6 = bound(dispSeedB, dispAE6, MAX_PI_E6);
        uint24 maxFadeE6 = uint24(bound(uint256(maxFadeSeed), 0, MAX_FEE_E6));

        uint24 feeAE6 = VolatileFeeCalculation.displacementContinuingFee(
            baselineFeeE6, _moveFromE6(dispAE6, false), rateE6, maxFadeE6
        );
        uint24 feeBE6 = VolatileFeeCalculation.displacementContinuingFee(
            baselineFeeE6, _moveFromE6(dispBE6, false), rateE6, maxFadeE6
        );

        assertGe(feeAE6, baselineFeeE6, "fee below baseline");
        assertLe(feeBE6, uint256(baselineFeeE6) + maxFadeE6, "fade above cap");
        assertLe(feeAE6, feeBE6, "larger displacement pays less");
    }

    // -------------------------------------------------------------------------
    // temporaryBackrunFee
    // -------------------------------------------------------------------------

    function test_temporaryBackrunFee_pointValues() public pure {
        assertEq(_tempFee(1700, 1500, 1999, BCF_E6, BACKRUN_THRESHOLD_E6), 200);
        assertEq(_tempFee(1700, 1500, 2000, BCF_E6, BACKRUN_THRESHOLD_E6), 1200);
        assertEq(_tempFee(1700, 1500, 10_000, BCF_E6, BACKRUN_THRESHOLD_E6), 5200);
        assertEq(_tempFee(1500, 1500, 10_000, BCF_E6, BACKRUN_THRESHOLD_E6), 5000);
        assertEq(_tempFee(1700, 1500, 10_000, 0, BACKRUN_THRESHOLD_E6), 200);
        assertEq(_tempFee(1500, 1500, 1, BCF_E6, 0), 1);
    }

    function test_temporaryBackrunFee_zeroThresholdOnFlatBlock_isZero() public pure {
        assertEq(_tempFee(1500, 1500, 0, BCF_E6, 0), 0);
    }

    /// Step + captured term (500 + ~2**96 * 1e6) clamps as a whole, so the temp fee alone never exceeds the ceiling.
    function test_temporaryBackrunFee_clampsToMaxFee() public pure {
        assertEq(_tempFee(2000, 1500, MAX_PI_E6, uint24(ONE_E6), 0), MAX_FEE_E6);
    }

    function test_fuzz_temporaryBackrunFee_gatedBoundedAndMonotone(
        uint24 oldPermSeed,
        uint24 stepSeed,
        uint256 piSeedA,
        uint256 piSeedB,
        uint24 bcfSeed,
        uint24 backrunThresholdE6
    ) public pure {
        uint24 oldPermFeeE6 = uint24(bound(uint256(oldPermSeed), 0, MAX_FEE_E6));
        uint24 stepE6 = uint24(bound(uint256(stepSeed), 0, MAX_FEE_E6 - oldPermFeeE6));
        uint256 piAE6 = bound(piSeedA, 0, MAX_PI_E6);
        uint256 piBE6 = bound(piSeedB, piAE6, MAX_PI_E6);
        uint24 bcfE6 = uint24(bound(uint256(bcfSeed), 0, ONE_E6));

        uint24 feeAE6 = _tempFee(oldPermFeeE6 + stepE6, oldPermFeeE6, piAE6, bcfE6, backrunThresholdE6);
        uint24 feeBE6 = _tempFee(oldPermFeeE6 + stepE6, oldPermFeeE6, piBE6, bcfE6, backrunThresholdE6);

        if (piAE6 < backrunThresholdE6) assertEq(feeAE6, stepE6, "charged below threshold");
        assertGe(feeAE6, stepE6, "fee below step");
        assertLe(feeBE6, uint256(stepE6) + MAX_FEE_E6, "fee above step + ceiling");
        assertLe(feeAE6, feeBE6, "larger move charges less");
    }

    // -------------------------------------------------------------------------
    // newPermAndTempFee (and newPermanentFee through it)
    // -------------------------------------------------------------------------

    function test_newPermAndTempFee_pointValues_upMoves() public pure {
        VolatileFeeConfig memory s = _pointConfig();

        // Flat block: nothing changes and both baselines are the perm fees, whichever way the direction flag points.
        _assertTopOfBlock(s, NEUTRAL_PERM_E6, 0, true, 1500, 1500, 1500);
        _assertTopOfBlock(s, NEUTRAL_PERM_E6, 0, false, 1500, 1500, 1500);

        // 0.1% up: step = ceil(10% * 1000) = 100. The ask leans to 1600. The bid loses 100 of perm fee and gets it back
        // as temp fee, so its baseline stays 1500: the step cancels on the backrun side.
        _assertTopOfBlock(s, NEUTRAL_PERM_E6, 1000, true, 1600, 1600, 1500);

        // One pip under the threshold vs. at it: the step is 200 either way (199.9 rounds up), and the bid side adds
        // the 50% capture (1000) only once the move reaches 0.2%.
        _assertTopOfBlock(s, NEUTRAL_PERM_E6, 1999, true, 1700, 1700, 1500);
        _assertTopOfBlock(s, NEUTRAL_PERM_E6, 2000, true, 1700, 1700, 2500);

        // 1% up: the raw step of 1000 caps at maxSkewStep 400; the bid baseline is its old perm 1500 plus the 5000
        // capture.
        _assertTopOfBlock(s, NEUTRAL_PERM_E6, 10_000, true, 1900, 1900, 6500);

        // Another 1% up from 1900: the step would reach 2300 but the skew ceiling holds it at 2000, so only 100 moves
        // and the bid baseline is 1100 + 5000.
        _assertTopOfBlock(s, 1900, 10_000, true, 2000, 2000, 6100);

        // At the ceiling a further 1% up adds no step; the bid baseline is 1000 + 5000.
        _assertTopOfBlock(s, 2000, 10_000, true, 2000, 2000, 6000);
    }

    function test_newPermAndTempFee_pointValues_downMoves() public pure {
        VolatileFeeConfig memory s = _pointConfig();

        // Mirror of the neutral 1% up case.
        _assertTopOfBlock(s, NEUTRAL_PERM_E6, 10_000, false, 1100, 6500, 1900);

        // Ask at its ceiling (bid perm 1000), then 1% down: the bid leans to 1400, the ask perm falls to 1600, and the
        // ask baseline is its old perm 2000 plus the 5000 capture.
        _assertTopOfBlock(s, 2000, 10_000, false, 1600, 7000, 1400);
    }

    function test_fuzz_newPermAndTempFee_keepsBandAndBounds(
        ConfigSeed memory seed,
        uint24 oldAskSeed,
        uint256 piSeed,
        bool up
    ) public pure {
        VolatileFeeConfig memory s = _boundFeeConfig(seed);
        uint24 oldAskPermFeeE6 =
            uint24(bound(uint256(oldAskSeed), uint256(s.restingSpreadE6) - s.maxSkewE6, s.maxSkewE6));
        uint256 piE6 = bound(piSeed, 0, MAX_PI_E6);

        VolatileFeeState memory state;
        (state.askPermFeeE6, state.tempFeeE6, state.tempOnBid) =
            VolatileFeeCalculation.newPermAndTempFee(s, oldAskPermFeeE6, _moveFromE6(piE6, up));
        assertEq(state.tempOnBid, up, "temp fee must sit on the backrun side");
        uint24 newAskPermFeeE6 = state.askPermFeeE6;
        (uint24 askNewBaselineFeeE6, uint24 bidNewBaselineFeeE6) = _baselines(state, s.restingSpreadE6);

        assertGe(newAskPermFeeE6, s.restingSpreadE6 - s.maxSkewE6, "askPerm below band");
        assertLe(newAskPermFeeE6, s.maxSkewE6, "askPerm above band");

        // lean: the side the price moved toward; its perm fee steps up by at most maxSkewStep
        uint256 oldLean = up ? oldAskPermFeeE6 : s.restingSpreadE6 - oldAskPermFeeE6;
        uint256 newLean = up ? newAskPermFeeE6 : s.restingSpreadE6 - newAskPermFeeE6;
        assertGe(newLean, oldLean, "leaning side moved back");
        assertLe(newLean, oldLean + s.maxSkewStepE6, "leaning side moved more than one step");
        assertEq(up ? askNewBaselineFeeE6 : bidNewBaselineFeeE6, newLean, "leaning baseline != new perm fee");

        // other: the backrun side, opposite the leaning side; its perm fee is RS - lean and drops by the step
        uint256 otherNewBaselineE6 = up ? bidNewBaselineFeeE6 : askNewBaselineFeeE6;
        uint256 otherNewPermE6 = s.restingSpreadE6 - newLean;
        // the temp fee adds restoreFraction * step back when PI >= restoreThreshold; the step is newLean - oldLean
        uint256 restoreE6 = piE6 >= s.restoreThresholdE6
            ? FixedPointMathLib.mulDivUp(newLean - oldLean, s.restoreFractionE6, ONE_E6)
            : 0;
        assertGe(otherNewBaselineE6, otherNewPermE6, "backrun side below its perm fee");
        assertLe(otherNewBaselineE6, MAX_FEE_E6, "backrun side above ceiling");
        // the temp fee adds backrunCaptureFraction * PI when PI >= backrunThreshold; the sum clamps to the ceiling
        uint256 backrunE6 =
            piE6 >= s.backrunThresholdE6 ? FixedPointMathLib.mulDivUp(piE6, s.backrunCaptureFractionE6, ONE_E6) : 0;
        // If backrun threshold not met, fee must be equal to perm + restore (restore can be 0 if threshold not met)
        if (piE6 < s.backrunThresholdE6) {
            assertEq(
                otherNewBaselineE6, otherNewPermE6 + restoreE6, "backrun side != perm fee + restore below threshold"
            );
        }
        // If backrun threshold not met, fee must be equal to perm + backrun (backrun can be 0 if threshold not met)
        if (piE6 < s.restoreThresholdE6) {
            assertEq(
                otherNewBaselineE6,
                FixedPointMathLib.min(otherNewPermE6 + backrunE6, MAX_FEE_E6),
                "backrun side != perm fee + backrun below restore threshold"
            );
        }
        if (piE6 == 0) {
            assertEq(newLean, oldLean, "flat block moved the perm fee");
            assertEq(otherNewBaselineE6, otherNewPermE6, "flat block charged the backrun side");
        }
    }

    function test_fuzz_newPermAndTempFee_upAndDownAreMirrorImages(
        ConfigSeed memory seed,
        uint24 leanSeed,
        uint256 piSeed
    ) public pure {
        VolatileFeeConfig memory s = _boundFeeConfig(seed);
        uint24 leanPermFeeE6 = uint24(bound(uint256(leanSeed), uint256(s.restingSpreadE6) - s.maxSkewE6, s.maxSkewE6));
        uint256 piE6 = bound(piSeed, 0, MAX_PI_E6);

        (uint24 upAskPermE6, uint24 upAskBaselineE6, uint24 upBidBaselineE6) =
            _newPermAndBaselines(s, leanPermFeeE6, piE6, true);
        (uint24 downAskPermE6, uint24 downAskBaselineE6, uint24 downBidBaselineE6) =
            _newPermAndBaselines(s, s.restingSpreadE6 - leanPermFeeE6, piE6, false);

        assertEq(uint256(downAskPermE6) + upAskPermE6, s.restingSpreadE6, "perm fees are not mirrored");
        assertEq(downAskBaselineE6, upBidBaselineE6, "backrun baselines differ");
        assertEq(downBidBaselineE6, upAskBaselineE6, "leaning baselines differ");
    }

    /// `temporaryBackrunFee` on a pip-denominated move; the direction does not enter the temp fee.
    function _tempFee(uint24 newPermFeeE6, uint24 oldPermFeeE6, uint256 piE6, uint24 bcfE6, uint24 thresholdE6)
        internal
        pure
        returns (uint24)
    {
        return VolatileFeeCalculation.temporaryBackrunFee(
            newPermFeeE6,
            oldPermFeeE6,
            _moveFromE6(piE6, false),
            bcfE6,
            thresholdE6,
            RESTORE_FRACTION_E6,
            RESTORE_THRESHOLD_E6
        );
    }

    /// Top-of-block fields only; the mid-block fade fields stay zero.
    function _pointConfig() internal pure returns (VolatileFeeConfig memory s) {
        s.restingSpreadE6 = RS_E6;
        s.maxSkewE6 = MAX_SKEW_E6;
        s.maxSkewStepE6 = MAX_SKEW_STEP_E6;
        s.skewRateE6 = SKEW_RATE_E6;
        s.backrunCaptureFractionE6 = BCF_E6;
        s.backrunThresholdE6 = BACKRUN_THRESHOLD_E6;
        s.restoreFractionE6 = RESTORE_FRACTION_E6;
        s.restoreThresholdE6 = RESTORE_THRESHOLD_E6;
    }

    function _assertTopOfBlock(
        VolatileFeeConfig memory s,
        uint24 oldAskPermFeeE6,
        uint256 piE6,
        bool up,
        uint24 expectedAskPermE6,
        uint24 expectedAskBaselineE6,
        uint24 expectedBidBaselineE6
    ) internal pure {
        (uint24 newAskPermE6, uint24 askBaselineE6, uint24 bidBaselineE6) =
            _newPermAndBaselines(s, oldAskPermFeeE6, piE6, up);
        assertEq(newAskPermE6, expectedAskPermE6, "askPerm");
        assertEq(askBaselineE6, expectedAskBaselineE6, "askBaseline");
        assertEq(bidBaselineE6, expectedBidBaselineE6, "bidBaseline");
    }
}
