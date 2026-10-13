// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice Static per-pool config for the volatile fee algorithm, set by the config manager.
/// @dev Fee-like fields are E6 pips; 1e6 = 100%. restingSpreadE6 == 0 means unconfigured.
struct VolatileFeeConfig {
    uint24 restingSpreadE6; // permanent pie: ask + bid fee
    uint24 backrunCaptureFractionE6; // LP share of backrun profit
    uint24 midFadeRateE6; // continuing-fee growth rate per unit move
    uint24 maxMidFadeE6; // cap on the continuing fade
    uint24 skewRateE6; // leaning side's permanent fee step per unit of price impact
    uint24 maxSkewStepE6; // cap on the leaning side's permanent fee step per block; <= 2 * maxSkewE6 - restingSpreadE6
    uint24 maxSkewE6; // cap on either side's permanent fee; restingSpreadE6 / 2 <= maxSkewE6 <= restingSpreadE6
    uint24 backrunThresholdE6; // price impact threshold at which the backrun fee component is active
    uint24 restoreFractionE6; // share of what the backrun side's permanent fee went down by that the temp fee adds back; 1e6 = all of it
    uint24 restoreThresholdE6; // price impact threshold at which the restore fee component is active
}

/// @notice Per-pool fee state, advanced on the first swap of each block. Packs into one slot.
/// @dev Only the ask-side permanent fee is stored; bid perm = restingSpreadE6 - askPermFeeE6. Baselines
///      are not stored either: the leaning side's baseline is its permanent fee and the backrun side's
///      is its permanent fee plus tempFeeE6 (VolatileFeeCalculation.baselineFee). sqrtPriceTopX96 is
///      this block's open for mid-block displacement, and the previous block's open for the next
///      block's price impact.
struct VolatileFeeState {
    uint40 blockNumber; // block of the last update
    uint160 sqrtPriceTopX96; // block-open price, reset on last update
    uint24 askPermFeeE6; // permanent ask-side fee (sticky skew)
    uint24 tempFeeE6; // one-block backrun charge on the side named by tempOnBid
    bool tempOnBid; // true: tempFeeE6 is on the bid side; false: on the ask side
}

/// @notice Interface for the volatile fee configuration (config-manager-owned per-pool params).
interface IVolatileFeeConfiguration {
    /// @notice Thrown when restingSpreadE6 is 0, the sentinel for an unconfigured pool
    error RestingSpreadCannotBeZero();

    /// @notice Thrown when maxSkewE6 exceeds restingSpreadE6, which would let one side's fee exceed the whole spread
    /// @param maxSkewE6 The submitted skew ceiling
    /// @param restingSpreadE6 The submitted resting spread
    error MaxSkewTooLarge(uint24 maxSkewE6, uint24 restingSpreadE6);

    /// @notice Thrown when maxSkewE6 is below restingSpreadE6 / 2, the neutral center the leaning side starts from
    /// @param maxSkewE6 The submitted skew ceiling
    /// @param restingSpreadE6 The submitted resting spread
    error MaxSkewTooSmall(uint24 maxSkewE6, uint24 restingSpreadE6);

    /// @notice Thrown when restingSpreadE6 exceeds 2 * MAX_FEE_E6, the sum of both sides' fee ceilings
    /// @param restingSpreadE6 The submitted resting spread
    error RestingSpreadTooLarge(uint24 restingSpreadE6);

    /// @notice Thrown when maxSkewE6 exceeds MAX_FEE_E6; the excess is skew band the fee clamp would remove
    /// @param maxSkewE6 The submitted skew ceiling
    error MaxSkewAboveMaxFee(uint24 maxSkewE6);

    /// @notice Thrown when maxSkewStepE6 exceeds 2 * maxSkewE6 - restingSpreadE6, the width of the permanent-fee band
    /// @param maxSkewStepE6 The submitted per-block skew step cap
    /// @param maxSkewE6 The submitted skew ceiling
    /// @param restingSpreadE6 The submitted resting spread
    error MaxSkewStepTooLarge(uint24 maxSkewStepE6, uint24 maxSkewE6, uint24 restingSpreadE6);

    /// @notice Thrown when maxMidFadeE6 exceeds MAX_FEE_E6; baseline + fade must fit a uint24
    /// @param maxMidFadeE6 The submitted continuing-fade cap
    error MaxMidFadeTooLarge(uint24 maxMidFadeE6);

    /// @notice Thrown when backrunCaptureFractionE6 or restoreFractionE6 exceeds 1e6 (100%)
    /// @param fractionE6 The submitted fraction
    error FractionTooLarge(uint24 fractionE6);

    /// @notice Thrown when backrunThresholdE6 or restoreThresholdE6 is 1e6 (100%) or more; a down move can never reach it
    /// @param thresholdE6 The submitted threshold
    error ThresholdTooLarge(uint24 thresholdE6);

    /// @notice Thrown when poolIds and feeConfigs arrays have different lengths
    error LengthMismatch();

    /// @notice Emitted when a pool's fee config is updated
    /// @param poolId The pool whose config changed
    /// @param feeConfig The new fee config
    event FeeConfigUpdated(PoolId indexed poolId, VolatileFeeConfig feeConfig);

    /// @notice Sets a pool's fee config.
    /// @param poolId Pool to update
    /// @param feeConfig New fee config
    function updateFeeConfig(PoolId poolId, VolatileFeeConfig calldata feeConfig) external;

    /// @notice Sets fee config for multiple pools.
    /// @param poolIds Pools to update
    /// @param feeConfigs New config per pool, matched to poolIds by index
    function batchUpdateFeeConfig(PoolId[] calldata poolIds, VolatileFeeConfig[] calldata feeConfigs) external;

    /// @notice Fee config for a pool.
    /// @param poolId Pool to query
    /// @return restingSpreadE6 Permanent pie: ask + bid fee
    /// @return backrunCaptureFractionE6 LP share of backrun profit
    /// @return midFadeRateE6 Continuing-fee growth rate per unit move
    /// @return maxMidFadeE6 Cap on the continuing fade
    /// @return skewRateE6 Baseline lean per unit of price impact
    /// @return maxSkewStepE6 Max skew change per block
    /// @return maxSkewE6 Skew ceiling
    /// @return backrunThresholdE6 Price impact threshold at which the backrun fee component is active
    /// @return restoreFractionE6 Share of the backrun side's permanent fee drop that the temp fee adds back; 1e6 = all of it
    /// @return restoreThresholdE6 Price impact threshold at which the restore fee component is active
    function feeConfig(PoolId poolId)
        external
        view
        returns (
            uint24 restingSpreadE6,
            uint24 backrunCaptureFractionE6,
            uint24 midFadeRateE6,
            uint24 maxMidFadeE6,
            uint24 skewRateE6,
            uint24 maxSkewStepE6,
            uint24 maxSkewE6,
            uint24 backrunThresholdE6,
            uint24 restoreFractionE6,
            uint24 restoreThresholdE6
        );

    /// @notice Fee state for a pool.
    /// @param poolId Pool to query
    /// @return blockNumber Block of the last update. 0 if no swaps since last config update
    /// @return sqrtPriceTopX96 Block-open sqrt price. 0 if no swaps since last config update
    /// @return askPermFeeE6 Permanent ask-side fee; bid perm = restingSpreadE6 - askPermFeeE6
    /// @return tempFeeE6 One-block backrun charge; baselines follow via VolatileFeeCalculation.baselineFee
    /// @return tempOnBid True if tempFeeE6 is on the bid side, false if on the ask side
    function feeState(PoolId poolId)
        external
        view
        returns (uint40 blockNumber, uint160 sqrtPriceTopX96, uint24 askPermFeeE6, uint24 tempFeeE6, bool tempOnBid);
}
