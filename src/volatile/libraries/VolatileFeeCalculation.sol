// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {RelativeMove, RelativeMoveLibrary} from "./RelativeMoveLibrary.sol";
import {VolatileFeeConfig, VolatileFeeState} from "../interfaces/IVolatileFeeConfiguration.sol";

/// @title VolatileFeeCalculation
/// @notice Pure math for the volatile dynamic-fee algorithm. All `*E6` values are E6 pips; 1e6 = 100%.
/// @dev A price move is carried as an exact ratio (RelativeMove) and rounded once, up, where it is scaled
///      into a fee or a skew step. The Q48 sqrt-ratio intermediate in relativeMove rounds down, which can only
///      enlarge the move, by at most 2**-47 relative. Both round in favour of LPs.
library VolatileFeeCalculation {
    /// @notice 1e6 is 100% in pips format
    uint256 internal constant ONE_E6 = 1e6;

    /// @notice Maximum LP fee the hook can charge. Pool.swap combines the LP fee with the protocol fee.
    ///         Hook fee of 999_999 compounds to 1e6 for any nonzero protocol fee, whereas 999_998 hits
    ///         999_999 for any non-zero protocol fee.
    uint256 internal constant MAX_HOOK_FEE_E6 = 1e6 - 2;

    /// @notice Scale for the sqrt-ratio intermediate calculation
    uint256 internal constant Q48 = 2 ** 48;

    /// @notice Relative move between two sqrt prices, as an exact ratio of the reference price.
    /// @param sqrtPriceNewX96 Current/new sqrt price
    /// @param sqrtPriceRefX96 Reference sqrt price (denominator)
    /// @return move The ratio |P_new - P_ref| / P_ref and whether the price increased
    function relativeMove(uint160 sqrtPriceNewX96, uint160 sqrtPriceRefX96) internal pure returns (RelativeMove move) {
        if (sqrtPriceNewX96 == sqrtPriceRefX96) return RelativeMoveLibrary.pack(0, FixedPoint96.Q96, false);
        bool increased = sqrtPriceNewX96 > sqrtPriceRefX96;

        // Q48 sqrt-price ratio of smaller/larger price.
        uint256 sqrtRatioX48 = increased
            ? uint256(sqrtPriceRefX96) * Q48 / sqrtPriceNewX96  // ref is smaller
            : uint256(sqrtPriceNewX96) * Q48 / sqrtPriceRefX96; // new is smaller
        uint256 ratioX96 = sqrtRatioX48 * sqrtRatioX48;
        // An extreme up-move can round ratioX96 down to 0; clamp so the division downstream never panics.
        // The resulting move is enormous and gets clamped to the max fee downstream (fail-safe, never reverts).
        if (ratioX96 == 0) ratioX96 = 1;

        // Relative to the reference price:
        //   up   (ref smaller): move = P_new/P_ref - 1 = (Q96 - ratioX96) / ratioX96
        //   down (ref larger):  move = 1 - P_new/P_ref = (Q96 - ratioX96) / Q96
        return RelativeMoveLibrary.pack(FixedPoint96.Q96 - ratioX96, increased ? ratioX96 : FixedPoint96.Q96, increased);
    }

    /// @notice Applies the per-block permanent skew step to the leaning side's fee.
    /// @param oldPermFeeE6 Previous block's permanent fee for the leaning side
    /// @param blockPriceImpact Price impact since the previous block open
    /// @param skewRateE6 Lean per unit of price impact
    /// @param maxSkewStepE6 Per-block skew step cap
    /// @param maxSkewE6 Skew ceiling
    /// @return newPermFeeE6 New permanent fee for the leaning side
    function newPermanentFee(
        uint24 oldPermFeeE6,
        RelativeMove blockPriceImpact,
        uint24 skewRateE6,
        uint24 maxSkewStepE6,
        uint24 maxSkewE6
    ) internal pure returns (uint24 newPermFeeE6) {
        // Compute the step, capped by maxSkewStep
        // step = min(skewRate * PI, maxSkewStep), rounded up once
        uint256 stepE6 = blockPriceImpact.mulUp(skewRateE6);
        if (stepE6 > maxSkewStepE6) stepE6 = maxSkewStepE6;

        // Computes the new permanent fee, capped by maxSkewE6. Cast is safe because of the clamp above
        // newPermFee = min(oldPermFee + step, maxSkew)
        newPermFeeE6 = oldPermFeeE6 + uint24(stepE6);
        if (newPermFeeE6 > maxSkewE6) newPermFeeE6 = maxSkewE6;
    }

    /// @notice Fee for a swap trading back toward the block open (the backrun side).
    /// @param baselineFeeE6 Block's baseline fee for this side
    /// @param displacementFromTop Displacement from the block open
    /// @param backrunCaptureFractionE6 LP share of backrun profit
    /// @return feeE6 Fee, clamped to MAX_HOOK_FEE_E6
    function displacementBackrunFee(
        uint24 baselineFeeE6,
        RelativeMove displacementFromTop,
        uint24 backrunCaptureFractionE6
    ) internal pure returns (uint24 feeE6) {
        // Calculate the backrun fee, proportional to the displacement from the block open, rounded up once
        uint256 rawFeeE6 = uint256(baselineFeeE6) + displacementFromTop.mulUp(backrunCaptureFractionE6);

        feeE6 = clampToMaxHookFeeE6(rawFeeE6);
    }

    /// @notice Fee for a swap pushing further in the price-impact direction (the continuing side).
    /// @param baselineFeeE6 Block's baseline fee for this side
    /// @param displacementFromTop Displacement from the block open
    /// @param midFadeRateE6 Continuing-fee growth rate per unit move
    /// @param maxMidFadeE6 Continuing-side fee cap
    /// @return feeE6 Fee, clamped to MAX_HOOK_FEE_E6
    function displacementContinuingFee(
        uint24 baselineFeeE6,
        RelativeMove displacementFromTop,
        uint24 midFadeRateE6,
        uint24 maxMidFadeE6
    ) internal pure returns (uint24 feeE6) {
        // Compute the fade, capped by maxMidFadeE6
        // fade = min(midFadeRate * displacementFromTop, maxMidFade), rounded up once
        uint256 fadeE6 = displacementFromTop.mulUp(midFadeRateE6);
        if (fadeE6 > maxMidFadeE6) fadeE6 = maxMidFadeE6;

        feeE6 = clampToMaxHookFeeE6(uint256(baselineFeeE6) + fadeE6);
    }

    /// @notice Temporary (one-block) fee on the backrun side at the top of a block.
    /// @param newPermFeeE6 Updated permanent skew (this block)
    /// @param oldPermFeeE6 Previous permanent skew (last block)
    /// @param blockPriceImpact Price impact since the previous block open
    /// @param backrunCaptureFractionE6 LP share of backrun profit
    /// @param backrunThresholdE6 Price impact level that arms the backrun charge
    /// @return tempFeeE6 Temporary fee on the backrun side
    function temporaryBackrunFee(
        uint24 newPermFeeE6,
        uint24 oldPermFeeE6,
        RelativeMove blockPriceImpact,
        uint24 backrunCaptureFractionE6,
        uint24 backrunThresholdE6,
        uint24 restoreFractionE6,
        uint24 restoreThresholdE6
    ) internal pure returns (uint24 tempFeeE6) {
        // tempFee has 2 components:
        if (blockPriceImpact.gte(restoreThresholdE6)) {
            // restore term = restoreFraction * (newPermFee - oldPermFee), applied only when the price moved more than the restoreThresholdE6
            uint256 feeDelta;
            unchecked {
                // newPermFee = min(oldPermFee + step, maxSkew) and oldPermFee <= maxSkew: every config write resets it
                // to restingSpread / 2 <= maxSkew and newPermanentFee never exceeds maxSkew. So new >= old; no underflow.
                feeDelta = uint256(newPermFeeE6 - oldPermFeeE6); // cast to u256 for muldiv
            }

            // feeDelta is capped at u24max, restoreFraction is capped at 1e6 so the product must be capped at u24max
            tempFeeE6 = uint24(FixedPointMathLib.mulDivUp(feeDelta, uint256(restoreFractionE6), uint256(ONE_E6)));
        }

        if (blockPriceImpact.gte(backrunThresholdE6)) {
            uint256 backrunFee = blockPriceImpact.mulUp(backrunCaptureFractionE6);
            tempFeeE6 = clampToMaxHookFeeE6(uint256(tempFeeE6) + backrunFee);
        }
    }

    /// @notice Advances the permanent skew for a new block and prices its one-block backrun charge.
    /// @dev The side the price moved toward leans (its permanent fee steps up) and the other side is the
    ///      backrun side, which carries the temp fee. Baselines follow from `baselineFee`.
    /// @param config Pool's fee config
    /// @param oldAskPermFeeE6 Previous block's permanent ask-side fee
    /// @param blockPriceImpact Price impact since the previous block open, with its direction
    /// @return newAskPermFeeE6 New permanent ask-side fee to store
    /// @return tempFeeE6 Temporary fee for the block, clamped to MAX_HOOK_FEE_E6
    /// @return tempOnBid True if the temp fee is on the bid side, false if on the ask side
    function newPermAndTempFee(VolatileFeeConfig memory config, uint24 oldAskPermFeeE6, RelativeMove blockPriceImpact)
        internal
        pure
        returns (uint24 newAskPermFeeE6, uint24 tempFeeE6, bool tempOnBid)
    {
        // An up move makes buying dearer: the ask leans and the bid is the backrun side.
        tempOnBid = blockPriceImpact.increased();
        uint24 oldLeanPermFeeE6 = tempOnBid ? oldAskPermFeeE6 : config.restingSpreadE6 - oldAskPermFeeE6;
        uint24 newLeanPermFeeE6 = newPermanentFee(
            oldLeanPermFeeE6, blockPriceImpact, config.skewRateE6, config.maxSkewStepE6, config.maxSkewE6
        );
        tempFeeE6 = temporaryBackrunFee(
            newLeanPermFeeE6,
            oldLeanPermFeeE6,
            blockPriceImpact,
            config.backrunCaptureFractionE6,
            config.backrunThresholdE6,
            config.restoreFractionE6,
            config.restoreThresholdE6
        );
        newAskPermFeeE6 = tempOnBid ? newLeanPermFeeE6 : config.restingSpreadE6 - newLeanPermFeeE6;
    }

    /// @notice One side's top-of-block baseline from the stored skew and temp fee.
    /// @dev The leaning side's baseline is its permanent fee; the backrun side's adds the temp fee. Both
    ///      permanent fees are <= maxSkewE6 <= MAX_HOOK_FEE_E6 by the config bounds, so only the temp
    ///      side can exceed the ceiling and needs the clamp.
    /// @param state Pool's fee state
    /// @param restingSpreadE6 Permanent pie: ask + bid fee
    /// @param zeroForOne Swap direction; a sell (true) pays the bid side, a buy (false) the ask side
    /// @return baselineFeeE6 Baseline for that side, clamped to MAX_HOOK_FEE_E6
    function baselineFee(VolatileFeeState memory state, uint24 restingSpreadE6, bool zeroForOne)
        internal
        pure
        returns (uint24 baselineFeeE6)
    {
        uint24 permFeeE6 = zeroForOne ? restingSpreadE6 - state.askPermFeeE6 : state.askPermFeeE6;
        if (zeroForOne != state.tempOnBid) return permFeeE6;
        baselineFeeE6 = clampToMaxHookFeeE6(uint256(permFeeE6) + state.tempFeeE6);
    }

    /// @notice Clamps a fee to MAX_HOOK_FEE_E6.
    /// @param feeE6 Unclamped fee
    /// @return Fee clamped to MAX_HOOK_FEE_E6
    function clampToMaxHookFeeE6(uint256 feeE6) internal pure returns (uint24) {
        return uint24(feeE6 > MAX_HOOK_FEE_E6 ? MAX_HOOK_FEE_E6 : feeE6);
    }
}
