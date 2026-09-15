// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {VolatileHookState} from "../interfaces/IVolatileFeeConfiguration.sol";

/// @title VolatileFeeCalculation
/// @notice Pure math for the volatile dynamic-fee algorithm. All `*E6` values are E6 pips; 1e6 = 100%.
/// @dev Rounding favours LPs: every division that feeds a charged fee rounds up, and the sqrt-ratio
///      intermediates in relativeMoveE6 round down because a smaller ratio means a larger move.
library VolatileFeeCalculation {
    /// @notice 1e6 is 100% in pips format
    uint256 constant ONE_E6 = 1e6;

    /// @notice Maximum LP fee the hook can charge. Pool.swap combines the LP fee with the protocol fee.
    ///         Hook fee of 999_999 compounds to 1e6 for any nonzero protocol fee, whereas 999_998 hits
    ///         999_999 for any non-zero protocol fee.
    uint256 internal constant MAX_HOOK_FEE_E6 = 1e6 - 2;

    /// @notice Scale for the sqrt-ratio intermediate calculation
    uint256 internal constant Q48 = 2 ** 48;

    /// @notice Relative move between two sqrt prices, as an E6 fraction of the reference price.
    /// @param sqrtPriceNewX96 Current/new sqrt price
    /// @param sqrtPriceRefX96 Reference sqrt price (denominator)
    /// @return moveE6 Relative move magnitude
    /// @return increased True if sqrtPriceNewX96 > sqrtPriceRefX96
    function relativeMoveE6(uint160 sqrtPriceNewX96, uint160 sqrtPriceRefX96)
        internal
        pure
        returns (uint256 moveE6, bool increased)
    {
        if (sqrtPriceNewX96 == sqrtPriceRefX96) return (0, false);
        increased = sqrtPriceNewX96 > sqrtPriceRefX96;

        // Q96 price ratio of smaller/larger price.
        uint256 sqrtRatioX96 = increased
            ? uint256(sqrtPriceRefX96) * Q48 / sqrtPriceNewX96  // ref is smaller
            : uint256(sqrtPriceNewX96) * Q48 / sqrtPriceRefX96; // new is smaller
        uint256 ratioX96 = sqrtRatioX96 * sqrtRatioX96;
        // An extreme up-move can round ratioX96 down to 0; clamp so the division below never panics.
        // The resulting move is enormous and gets clamped to the max fee downstream (fail-safe, never reverts).
        if (ratioX96 == 0) ratioX96 = 1;

        // Convert to a percentage move, dividing by the reference price:
        //   up   (ref smaller): move = P_new/P_ref - 1 = (Q96 - ratioX96) / ratioX96
        //   down (ref larger):  move = 1 - P_new/P_ref = (Q96 - ratioX96) / Q96
        // Rounds up so a fractional pip of movement charges a whole pip of fee.
        uint256 Q96MinusRatioX96 = (FixedPoint96.Q96 - ratioX96) * ONE_E6;
        moveE6 = increased
            ? FixedPointMathLib.divUp(Q96MinusRatioX96, ratioX96)
            : FixedPointMathLib.divUp(Q96MinusRatioX96, FixedPoint96.Q96);
    }

    /// @notice Applies the per-block permanent skew step to the leaning side's fee.
    /// @param oldPermFeeE6 Previous block's permanent fee for the leaning side
    /// @param blockPriceImpactE6 Price impact magnitude (>= 0)
    /// @param skewRateE6 Lean per unit of price impact
    /// @param maxSkewStepE6 Per-block skew step cap
    /// @param maxSkewE6 Skew ceiling
    /// @return newPermFeeE6 New permanent fee for the leaning side
    function newPermanentFee(
        uint24 oldPermFeeE6,
        uint256 blockPriceImpactE6,
        uint24 skewRateE6,
        uint24 maxSkewStepE6,
        uint24 maxSkewE6
    ) internal pure returns (uint24 newPermFeeE6) {
        // Compute the step, capped by maxSkewStep
        // step = min(skewRate * PI, maxSkewStep), rounded up
        uint256 stepE6 = FixedPointMathLib.mulDivUp(skewRateE6, blockPriceImpactE6, ONE_E6);
        if (stepE6 > maxSkewStepE6) stepE6 = maxSkewStepE6;

        // Computes the new permanent fee, capped by maxSkewE6. Cast is safe because of the clamp above
        // newPermFee = min(oldPermFee + step, maxSkew)
        newPermFeeE6 = oldPermFeeE6 + uint24(stepE6);
        if (newPermFeeE6 > maxSkewE6) newPermFeeE6 = maxSkewE6;
    }

    /// @notice Fee for a swap trading back toward the block open (the backrun side).
    /// @param baselineFeeE6 Block's baseline fee for this side
    /// @param displacementFromTopE6 Displacement from the block open (>= 0)
    /// @param backrunCaptureFractionE6 LP share of backrun profit
    /// @return feeE6 Fee, clamped to MAX_HOOK_FEE_E6
    function displacementBackrunFee(
        uint24 baselineFeeE6,
        uint256 displacementFromTopE6,
        uint24 backrunCaptureFractionE6
    ) internal pure returns (uint24 feeE6) {
        // Calculate the backrun fee, proportional to the displacement from the block open, rounded up
        uint256 rawFeeE6 = uint256(baselineFeeE6)
            + FixedPointMathLib.mulDivUp(backrunCaptureFractionE6, displacementFromTopE6, ONE_E6);

        feeE6 = clampToMaxHookFeeE6(rawFeeE6);
    }

    /// @notice Fee for a swap pushing further in the price-impact direction (the continuing side).
    /// @param baselineFeeE6 Block's baseline fee for this side
    /// @param displacementFromTopE6 Displacement from the block open (>= 0)
    /// @param midFadeRateE6 Continuing-fee growth rate per unit move
    /// @param maxMidFadeE6 Continuing-side fee cap
    /// @return feeE6 Fee, clamped to MAX_HOOK_FEE_E6
    function displacementContinuingFee(
        uint24 baselineFeeE6,
        uint256 displacementFromTopE6,
        uint24 midFadeRateE6,
        uint24 maxMidFadeE6
    ) internal pure returns (uint24 feeE6) {
        // Compute the fade, capped by maxMidFadeE6
        // fade = min(midFadeRate * displacementFromTop, maxMidFade), rounded up
        uint256 fadeE6 = FixedPointMathLib.mulDivUp(midFadeRateE6, displacementFromTopE6, ONE_E6);
        if (fadeE6 > maxMidFadeE6) fadeE6 = maxMidFadeE6;

        feeE6 = clampToMaxHookFeeE6(uint256(baselineFeeE6) + fadeE6);
    }

    /// @notice Temporary (one-block) fee on the backrun side at the top of a block.
    /// @param newPermFeeE6 Updated permanent skew (this block)
    /// @param oldPermFeeE6 Previous permanent skew (last block)
    /// @param blockPriceImpactE6 Price impact signal (>= 0)
    /// @param backrunCaptureFractionE6 LP share of backrun profit
    /// @param backrunThresholdE6 Price impact level that arms the backrun charge
    /// @return tempFeeE6 Temporary fee on the backrun side
    function temporaryBackrunFee(
        uint24 newPermFeeE6,
        uint24 oldPermFeeE6,
        uint256 blockPriceImpactE6,
        uint24 backrunCaptureFractionE6,
        uint24 backrunThresholdE6
    ) internal pure returns (uint24 tempFeeE6) {
        // tempFee = (newPermFee - oldPermFee) + (blockPriceImpact >= backrunThreshold ? backrunCaptureFraction * blockPriceImpact)
        // newPermFee = min(oldPermFee + step, maxSkew) and oldPermFee <= maxSkew: every config write resets it
        // to restingSpread / 2 <= maxSkew and newPermanentFee never exceeds maxSkew. So new >= old; no underflow.
        unchecked {
            tempFeeE6 = newPermFeeE6 - oldPermFeeE6;
        }
        if (blockPriceImpactE6 >= backrunThresholdE6) {
            uint256 backRunFee =
                FixedPointMathLib.mulDivUp(uint256(backrunCaptureFractionE6), uint256(blockPriceImpactE6), ONE_E6);

            tempFeeE6 = clampToMaxHookFeeE6(uint256(tempFeeE6) + backRunFee);
        }
    }

    /// @notice Composes the top-of-block baselines (permanent + temporary) for a new block.
    /// @param hookState Pool's hook state, read only for its config half
    /// @param oldAskPermFeeE6 Previous block's permanent ask-side fee
    /// @param blockPriceImpactE6 Price impact magnitude
    /// @param blockPriceImpactUp True if price moved up since the previous block
    /// @return newAskPermFeeE6 New permanent ask-side fee to store
    /// @return askBaselineFeeE6 Ask-side baseline for the block, clamped to MAX_HOOK_FEE_E6
    /// @return bidBaselineFeeE6 Bid-side baseline for the block, clamped to MAX_HOOK_FEE_E6
    function newPermAndTempFee(
        VolatileHookState memory hookState,
        uint24 oldAskPermFeeE6,
        uint256 blockPriceImpactE6,
        bool blockPriceImpactUp
    ) internal pure returns (uint24 newAskPermFeeE6, uint24 askBaselineFeeE6, uint24 bidBaselineFeeE6) {
        if (blockPriceImpactUp) {
            newAskPermFeeE6 = newPermanentFee(
                oldAskPermFeeE6, blockPriceImpactE6, hookState.skewRateE6, hookState.maxSkewStepE6, hookState.maxSkewE6
            );
            uint24 bidTempFee = temporaryBackrunFee(
                newAskPermFeeE6,
                oldAskPermFeeE6,
                blockPriceImpactE6,
                hookState.backrunCaptureFractionE6,
                hookState.backrunThresholdE6
            );
            // The perm side is bounded by maxSkewE6 <= MAX_HOOK_FEE_E6 at config time; only the temp side
            // can exceed the ceiling.
            askBaselineFeeE6 = newAskPermFeeE6;
            bidBaselineFeeE6 = clampToMaxHookFeeE6(uint256(hookState.restingSpreadE6 - newAskPermFeeE6) + bidTempFee);
        } else {
            uint24 oldBidPermFee = hookState.restingSpreadE6 - oldAskPermFeeE6;
            uint24 newBidPermFee = newPermanentFee(
                oldBidPermFee, blockPriceImpactE6, hookState.skewRateE6, hookState.maxSkewStepE6, hookState.maxSkewE6
            );
            uint24 askTempFee = temporaryBackrunFee(
                newBidPermFee,
                oldBidPermFee,
                blockPriceImpactE6,
                hookState.backrunCaptureFractionE6,
                hookState.backrunThresholdE6
            );
            newAskPermFeeE6 = hookState.restingSpreadE6 - newBidPermFee;
            bidBaselineFeeE6 = newBidPermFee;
            askBaselineFeeE6 = clampToMaxHookFeeE6(uint256(newAskPermFeeE6) + askTempFee);
        }
    }

    /// @notice Clamps a fee to MAX_HOOK_FEE_E6.
    /// @param feeE6 Unclamped fee
    /// @return Fee clamped to MAX_HOOK_FEE_E6
    function clampToMaxHookFeeE6(uint256 feeE6) internal pure returns (uint24) {
        return uint24(feeE6 > MAX_HOOK_FEE_E6 ? MAX_HOOK_FEE_E6 : feeE6);
    }
}
