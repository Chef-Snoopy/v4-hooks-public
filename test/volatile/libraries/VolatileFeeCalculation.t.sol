// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {VolatileFuzzTestBase} from "../base/VolatileFuzzTestBase.sol";
import {VolatileFeeCalculation} from "../../../src/volatile/libraries/VolatileFeeCalculation.sol";
import {VolatileFeeConfig, VolatileHookState} from "../../../src/volatile/interfaces/IVolatileFeeConfiguration.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

contract VolatileFeeCalculationTest is VolatileFuzzTestBase {
    uint256 internal constant ONE_E6 = VolatileFeeCalculation.ONE_E6;

    uint160 internal constant MIN_SQRT_PRICE = TickMath.MIN_SQRT_PRICE;
    uint160 internal constant MAX_SQRT_PRICE = TickMath.MAX_SQRT_PRICE;
    uint160 internal constant SQRT_PRICE_1_1 = Constants.SQRT_PRICE_1_1; // 2**96

    /// priceImpact's largest output, from the ratioX96 == 0 clamp. An unbounded pi would overflow rate * pi in
    /// mulDivUp, which no priceImpact output can (rate < 2**24, pi < 2**116).
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
    // priceImpact
    // -------------------------------------------------------------------------

    /// The ratioX96 == 0 clamp lands exactly on ONE_E6.
    function test_priceImpact_downMove_isBoundedByOneE6() public pure {
        (uint256 moveFullE6, bool increasedFull) =
            VolatileFeeCalculation.priceImpact(MIN_SQRT_PRICE, MAX_SQRT_PRICE - 1);
        assertEq(moveFullE6, ONE_E6);
        assertFalse(increasedFull);

        // A 2x down move in PRICE space. floor(sqrt(2) * 2**96) is below the exact reference, so the true move is
        // just under 500_000; the Q48 floor of 2**144 / ref pushes ratioX96 below 2**95 and divUp gives 500_001.
        // Both roundings enlarge the move: rounding favours LPs.
        (uint256 moveHalvedE6, bool increasedHalved) =
            VolatileFeeCalculation.priceImpact(SQRT_PRICE_1_1, SQRT_PRICE_2_1);
        assertEq(moveHalvedE6, ONE_E6 / 2 + 1);
        assertFalse(increasedHalved);

        (uint256 moveEqualE6, bool increasedEqual) = VolatileFeeCalculation.priceImpact(SQRT_PRICE_1_1, SQRT_PRICE_1_1);
        assertEq(moveEqualE6, 0);
        assertFalse(increasedEqual);
    }

    function testFuzz_priceImpact_upMove_monotoneNonDecreasing(uint160 refSeed, uint160 aSeed, uint160 bSeed)
        public
        pure
    {
        uint160 ref = uint160(bound(uint256(refSeed), MIN_SQRT_PRICE, MAX_SQRT_PRICE - 2));
        uint160 a = uint160(bound(uint256(aSeed), ref, MAX_SQRT_PRICE - 1));
        uint160 b = uint160(bound(uint256(bSeed), a, MAX_SQRT_PRICE - 1));

        (uint256 moveAE6, bool increasedA) = VolatileFeeCalculation.priceImpact(a, ref);
        (uint256 moveBE6, bool increasedB) = VolatileFeeCalculation.priceImpact(b, ref);

        assertLe(moveAE6, moveBE6, "PI must not decrease as the up-move grows");
        assertEq(increasedA, a > ref, "direction flag for a");
        assertEq(increasedB, b > ref, "direction flag for b");
    }

    function testFuzz_priceImpact_downMove_boundedAndMonotone(uint160 refSeed, uint160 aSeed, uint160 bSeed)
        public
        pure
    {
        uint160 ref = uint160(bound(uint256(refSeed), MIN_SQRT_PRICE, MAX_SQRT_PRICE - 1));
        uint160 b = uint160(bound(uint256(bSeed), MIN_SQRT_PRICE, ref));
        uint160 a = uint160(bound(uint256(aSeed), MIN_SQRT_PRICE, b));

        (uint256 moveAE6, bool increasedA) = VolatileFeeCalculation.priceImpact(a, ref);
        (uint256 moveBE6, bool increasedB) = VolatileFeeCalculation.priceImpact(b, ref);

        assertLe(moveAE6, ONE_E6, "down-move PI bounded by 100%");
        assertLe(moveBE6, ONE_E6, "down-move PI bounded by 100%");
        assertGe(moveAE6, moveBE6, "a further below ref must not report a smaller PI than b");
        assertFalse(increasedA, "direction flag for a");
        assertFalse(increasedB, "direction flag for b");
    }

    // -------------------------------------------------------------------------
    // midBlockBackrunFee
    // -------------------------------------------------------------------------

    function test_midBlockBackrunFee_pointValues() public pure {
        assertEq(VolatileFeeCalculation.midBlockBackrunFee(NEUTRAL_PERM_E6, 0, BCF_E6), 1500);
        assertEq(VolatileFeeCalculation.midBlockBackrunFee(NEUTRAL_PERM_E6, 10_000, BCF_E6), 6500);
        assertEq(VolatileFeeCalculation.midBlockBackrunFee(NEUTRAL_PERM_E6, 1, BCF_E6), 1501);
        assertEq(VolatileFeeCalculation.midBlockBackrunFee(NEUTRAL_PERM_E6, 2_000_000, 0), 1500);
    }

    function test_midBlockBackrunFee_clampsToMaxHookFee() public pure {
        assertEq(VolatileFeeCalculation.midBlockBackrunFee(NEUTRAL_PERM_E6, 2_000_000, uint24(ONE_E6)), MAX_HOOK_FEE_E6);
        assertEq(VolatileFeeCalculation.midBlockBackrunFee(0, MAX_PI_E6, uint24(ONE_E6)), MAX_HOOK_FEE_E6);
    }

    function testFuzz_midBlockBackrunFee_boundedAndMonotone(
        uint24 baselineSeed,
        uint256 dispSeedA,
        uint256 dispSeedB,
        uint24 bcfSeed
    ) public pure {
        uint24 baselineFeeE6 = uint24(bound(uint256(baselineSeed), 0, MAX_HOOK_FEE_E6));
        uint256 dispAE6 = bound(dispSeedA, 0, MAX_PI_E6);
        uint256 dispBE6 = bound(dispSeedB, dispAE6, MAX_PI_E6);
        uint24 bcfE6 = uint24(bound(uint256(bcfSeed), 0, ONE_E6));

        uint24 feeAE6 = VolatileFeeCalculation.midBlockBackrunFee(baselineFeeE6, dispAE6, bcfE6);
        uint24 feeBE6 = VolatileFeeCalculation.midBlockBackrunFee(baselineFeeE6, dispBE6, bcfE6);

        assertGe(feeAE6, baselineFeeE6, "fee below baseline");
        assertLe(feeBE6, MAX_HOOK_FEE_E6, "fee above ceiling");
        assertLe(feeAE6, feeBE6, "larger displacement pays less");
    }

    // -------------------------------------------------------------------------
    // midBlockContinuingFee
    // -------------------------------------------------------------------------

    function test_midBlockContinuingFee_pointValues() public pure {
        assertEq(
            VolatileFeeCalculation.midBlockContinuingFee(NEUTRAL_PERM_E6, 0, MID_FADE_RATE_E6, MAX_MID_FADE_E6), 1500
        );
        assertEq(
            VolatileFeeCalculation.midBlockContinuingFee(NEUTRAL_PERM_E6, 10_000, MID_FADE_RATE_E6, MAX_MID_FADE_E6),
            3500
        );
        assertEq(
            VolatileFeeCalculation.midBlockContinuingFee(NEUTRAL_PERM_E6, 1, MID_FADE_RATE_E6, MAX_MID_FADE_E6), 1501
        );
        assertEq(
            VolatileFeeCalculation.midBlockContinuingFee(NEUTRAL_PERM_E6, 100_000, MID_FADE_RATE_E6, MAX_MID_FADE_E6),
            6500
        );
        assertEq(VolatileFeeCalculation.midBlockContinuingFee(NEUTRAL_PERM_E6, 10_000, 0, MAX_MID_FADE_E6), 1500);
    }

    /// The hook's _toFeeUint24 clamps, not the library.
    function test_midBlockContinuingFee_isNotClampedToMaxHookFee() public pure {
        assertEq(
            VolatileFeeCalculation.midBlockContinuingFee(MAX_HOOK_FEE_E6, MAX_PI_E6, 1, MAX_HOOK_FEE_E6),
            2 * uint256(MAX_HOOK_FEE_E6)
        );
    }

    function testFuzz_midBlockContinuingFee_boundedAndMonotone(
        uint24 baselineSeed,
        uint256 dispSeedA,
        uint256 dispSeedB,
        uint24 rateE6,
        uint24 maxFadeSeed
    ) public pure {
        uint24 baselineFeeE6 = uint24(bound(uint256(baselineSeed), 0, MAX_HOOK_FEE_E6));
        uint256 dispAE6 = bound(dispSeedA, 0, MAX_PI_E6);
        uint256 dispBE6 = bound(dispSeedB, dispAE6, MAX_PI_E6);
        uint24 maxFadeE6 = uint24(bound(uint256(maxFadeSeed), 0, MAX_HOOK_FEE_E6));

        uint24 feeAE6 = VolatileFeeCalculation.midBlockContinuingFee(baselineFeeE6, dispAE6, rateE6, maxFadeE6);
        uint24 feeBE6 = VolatileFeeCalculation.midBlockContinuingFee(baselineFeeE6, dispBE6, rateE6, maxFadeE6);

        assertGe(feeAE6, baselineFeeE6, "fee below baseline");
        assertLe(feeBE6, uint256(baselineFeeE6) + maxFadeE6, "fade above cap");
        assertLe(feeAE6, feeBE6, "larger displacement pays less");
    }

    // -------------------------------------------------------------------------
    // temporaryBackrunFee
    // -------------------------------------------------------------------------

    function test_temporaryBackrunFee_pointValues() public pure {
        assertEq(VolatileFeeCalculation.temporaryBackrunFee(1700, 1500, 1999, BCF_E6, BACKRUN_THRESHOLD_E6), 200);
        assertEq(VolatileFeeCalculation.temporaryBackrunFee(1700, 1500, 2000, BCF_E6, BACKRUN_THRESHOLD_E6), 1200);
        assertEq(VolatileFeeCalculation.temporaryBackrunFee(1700, 1500, 10_000, BCF_E6, BACKRUN_THRESHOLD_E6), 5200);
        assertEq(VolatileFeeCalculation.temporaryBackrunFee(1500, 1500, 10_000, BCF_E6, BACKRUN_THRESHOLD_E6), 5000);
        assertEq(VolatileFeeCalculation.temporaryBackrunFee(1700, 1500, 10_000, 0, BACKRUN_THRESHOLD_E6), 200);
        assertEq(VolatileFeeCalculation.temporaryBackrunFee(1500, 1500, 1, BCF_E6, 0), 1);
    }

    function test_temporaryBackrunFee_zeroThresholdOnFlatBlock_isZero() public pure {
        assertEq(VolatileFeeCalculation.temporaryBackrunFee(1500, 1500, 0, BCF_E6, 0), 0);
    }

    function test_temporaryBackrunFee_clampsOnlyTheCapturedTerm() public pure {
        assertEq(
            VolatileFeeCalculation.temporaryBackrunFee(2000, 1500, MAX_PI_E6, uint24(ONE_E6), 0),
            uint256(MAX_HOOK_FEE_E6) + 500
        );
    }

    function testFuzz_temporaryBackrunFee_gatedBoundedAndMonotone(
        uint24 oldPermSeed,
        uint24 stepSeed,
        uint256 piSeedA,
        uint256 piSeedB,
        uint24 bcfSeed,
        uint24 backrunThresholdE6
    ) public pure {
        uint24 oldPermFeeE6 = uint24(bound(uint256(oldPermSeed), 0, MAX_HOOK_FEE_E6));
        uint24 stepE6 = uint24(bound(uint256(stepSeed), 0, MAX_HOOK_FEE_E6 - oldPermFeeE6));
        uint256 piAE6 = bound(piSeedA, 0, MAX_PI_E6);
        uint256 piBE6 = bound(piSeedB, piAE6, MAX_PI_E6);
        uint24 bcfE6 = uint24(bound(uint256(bcfSeed), 0, ONE_E6));

        uint24 feeAE6 = VolatileFeeCalculation.temporaryBackrunFee(
            oldPermFeeE6 + stepE6, oldPermFeeE6, piAE6, bcfE6, backrunThresholdE6
        );
        uint24 feeBE6 = VolatileFeeCalculation.temporaryBackrunFee(
            oldPermFeeE6 + stepE6, oldPermFeeE6, piBE6, bcfE6, backrunThresholdE6
        );

        if (piAE6 < backrunThresholdE6) assertEq(feeAE6, stepE6, "charged below threshold");
        assertGe(feeAE6, stepE6, "fee below step");
        assertLe(feeBE6, uint256(stepE6) + MAX_HOOK_FEE_E6, "fee above step + ceiling");
        assertLe(feeAE6, feeBE6, "larger move charges less");
    }

    // -------------------------------------------------------------------------
    // newPermAndTempFee (and newPermanentFee through it)
    // -------------------------------------------------------------------------

    function test_newPermAndTempFee_pointValues_upMoves() public pure {
        VolatileHookState memory s = _pointState();

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
        VolatileHookState memory s = _pointState();

        // Mirror of the neutral 1% up case.
        _assertTopOfBlock(s, NEUTRAL_PERM_E6, 10_000, false, 1100, 6500, 1900);

        // Ask at its ceiling (bid perm 1000), then 1% down: the bid leans to 1400, the ask perm falls to 1600, and the
        // ask baseline is its old perm 2000 plus the 5000 capture.
        _assertTopOfBlock(s, 2000, 10_000, false, 1600, 7000, 1400);
    }

    function testFuzz_newPermAndTempFee_keepsBandAndBounds(
        ConfigSeed memory seed,
        uint24 oldAskSeed,
        uint256 piSeed,
        bool up
    ) public pure {
        VolatileHookState memory s = _buildHookState(seed);
        uint24 oldAskPermFeeE6 =
            uint24(bound(uint256(oldAskSeed), uint256(s.restingSpreadE6) - s.maxSkewE6, s.maxSkewE6));
        uint256 piE6 = bound(piSeed, 0, MAX_PI_E6);

        (uint24 newAskPermFeeE6, uint24 askBaselineFeeE6, uint24 bidBaselineFeeE6) =
            VolatileFeeCalculation.newPermAndTempFee(s, oldAskPermFeeE6, piE6, up);

        assertGe(newAskPermFeeE6, s.restingSpreadE6 - s.maxSkewE6, "askPerm below band");
        assertLe(newAskPermFeeE6, s.maxSkewE6, "askPerm above band");

        uint256 oldLean = up ? oldAskPermFeeE6 : s.restingSpreadE6 - oldAskPermFeeE6;
        uint256 newLean = up ? newAskPermFeeE6 : s.restingSpreadE6 - newAskPermFeeE6;
        assertGe(newLean, oldLean, "leaning side moved back");
        assertLe(newLean, oldLean + s.maxSkewStepE6, "leaning side moved more than one step");
        assertEq(up ? askBaselineFeeE6 : bidBaselineFeeE6, newLean, "leaning baseline != new perm fee");

        uint256 otherBaseline = up ? bidBaselineFeeE6 : askBaselineFeeE6;
        uint256 otherOldPermE6 = s.restingSpreadE6 - oldLean;
        assertGe(otherBaseline, otherOldPermE6, "backrun side below its perm fee");
        assertLe(otherBaseline, otherOldPermE6 + MAX_HOOK_FEE_E6, "backrun side above perm fee + ceiling");
        if (piE6 < s.backrunThresholdE6) assertEq(otherBaseline, otherOldPermE6, "charged below threshold");
        if (piE6 == 0) {
            assertEq(newLean, oldLean, "flat block moved the perm fee");
            assertEq(otherBaseline, otherOldPermE6, "flat block charged the backrun side");
        }
    }

    function testFuzz_newPermAndTempFee_upAndDownAreMirrorImages(
        ConfigSeed memory seed,
        uint24 leanSeed,
        uint256 piSeed
    ) public pure {
        VolatileHookState memory s = _buildHookState(seed);
        uint24 leanPermFeeE6 = uint24(bound(uint256(leanSeed), uint256(s.restingSpreadE6) - s.maxSkewE6, s.maxSkewE6));
        uint256 piE6 = bound(piSeed, 0, MAX_PI_E6);

        (uint24 upAskPermE6, uint24 upAskBaselineE6, uint24 upBidBaselineE6) =
            VolatileFeeCalculation.newPermAndTempFee(s, leanPermFeeE6, piE6, true);
        (uint24 downAskPermE6, uint24 downAskBaselineE6, uint24 downBidBaselineE6) =
            VolatileFeeCalculation.newPermAndTempFee(s, s.restingSpreadE6 - leanPermFeeE6, piE6, false);

        assertEq(uint256(downAskPermE6) + upAskPermE6, s.restingSpreadE6, "perm fees are not mirrored");
        assertEq(downAskBaselineE6, upBidBaselineE6, "backrun baselines differ");
        assertEq(downBidBaselineE6, upAskBaselineE6, "leaning baselines differ");
    }

    function _pointState() internal pure returns (VolatileHookState memory s) {
        s.restingSpreadE6 = RS_E6;
        s.maxSkewE6 = MAX_SKEW_E6;
        s.maxSkewStepE6 = MAX_SKEW_STEP_E6;
        s.skewRateE6 = SKEW_RATE_E6;
        s.backrunCaptureFractionE6 = BCF_E6;
        s.backrunThresholdE6 = BACKRUN_THRESHOLD_E6;
    }

    function _buildHookState(ConfigSeed memory seed) internal pure returns (VolatileHookState memory s) {
        VolatileFeeConfig memory c = _boundFeeConfig(seed);
        s.restingSpreadE6 = c.restingSpreadE6;
        s.maxSkewE6 = c.maxSkewE6;
        s.maxSkewStepE6 = c.maxSkewStepE6;
        s.skewRateE6 = c.skewRateE6;
        s.backrunCaptureFractionE6 = c.backrunCaptureFractionE6;
        s.backrunThresholdE6 = c.backrunThresholdE6;
    }

    function _assertTopOfBlock(
        VolatileHookState memory s,
        uint24 oldAskPermFeeE6,
        uint256 piE6,
        bool up,
        uint24 expectedAskPermE6,
        uint24 expectedAskBaselineE6,
        uint24 expectedBidBaselineE6
    ) internal pure {
        (uint24 newAskPermE6, uint24 askBaselineE6, uint24 bidBaselineE6) =
            VolatileFeeCalculation.newPermAndTempFee(s, oldAskPermFeeE6, piE6, up);
        assertEq(newAskPermE6, expectedAskPermE6, "askPerm");
        assertEq(askBaselineE6, expectedAskBaselineE6, "askBaseline");
        assertEq(bidBaselineE6, expectedBidBaselineE6, "bidBaseline");
    }
}
