// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {
    IVolatileFeeConfiguration,
    VolatileFeeConfig,
    VolatileFeeState
} from "../interfaces/IVolatileFeeConfiguration.sol";
import {IDynamicFeeHook} from "../../interfaces/IDynamicFeeHook.sol";
import {VolatileFeeCalculation} from "../libraries/VolatileFeeCalculation.sol";
import {HookRoles} from "../../base/HookRoles.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BlockNumberish} from "@uniswap/blocknumberish/src/BlockNumberish.sol";

/// @title VolatileFeeConfiguration
/// @notice Per-pool volatile fee config and state, managed by the config manager.
abstract contract VolatileFeeConfiguration is HookRoles, BlockNumberish, IVolatileFeeConfiguration {
    /// @custom:storage-location erc7201:uniswap.storage.VolatileFeeConfiguration
    struct VolatileFeeConfigurationStorage {
        /// @dev The fee config for each pool
        mapping(PoolId => VolatileFeeConfig) feeConfig;
        /// @dev The fee state for each pool
        mapping(PoolId => VolatileFeeState) feeState;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("uniswap.storage.VolatileFeeConfiguration")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant VOLATILE_FEE_CONFIGURATION_STORAGE_LOCATION =
        0x5d4cd891dc52dbf2064bf3b556cd164a438eebc4f9a9ba71ffb5a8f1380e1e00;

    /// @notice Accessor for this contract's ERC-7201 namespaced storage
    /// @return $ Storage pointer to the namespaced slot
    function _getVolatileFeeConfigurationStorage() internal pure returns (VolatileFeeConfigurationStorage storage $) {
        assembly ("memory-safe") {
            $.slot := VOLATILE_FEE_CONFIGURATION_STORAGE_LOCATION
        }
    }

    /// @inheritdoc IVolatileFeeConfiguration
    function updateFeeConfig(PoolId poolId_, VolatileFeeConfig calldata feeConfig_)
        external
        onlyRole(CONFIG_MANAGER_ROLE)
    {
        _checkPoolInitialized(poolId_);
        _updateFeeConfig(poolId_, feeConfig_);
    }

    /// @inheritdoc IVolatileFeeConfiguration
    function batchUpdateFeeConfig(PoolId[] calldata poolIds_, VolatileFeeConfig[] calldata feeConfigs_)
        external
        onlyRole(CONFIG_MANAGER_ROLE)
    {
        if (poolIds_.length != feeConfigs_.length) revert LengthMismatch();
        for (uint256 i; i < poolIds_.length; i++) {
            _checkPoolInitialized(poolIds_[i]);
            _updateFeeConfig(poolIds_[i], feeConfigs_[i]);
        }
    }

    /// @inheritdoc IVolatileFeeConfiguration
    function feeConfig(PoolId poolId)
        public
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
        )
    {
        VolatileFeeConfig storage config = _getVolatileFeeConfigurationStorage().feeConfig[poolId];
        restingSpreadE6 = config.restingSpreadE6;
        backrunCaptureFractionE6 = config.backrunCaptureFractionE6;
        midFadeRateE6 = config.midFadeRateE6;
        maxMidFadeE6 = config.maxMidFadeE6;
        skewRateE6 = config.skewRateE6;
        maxSkewStepE6 = config.maxSkewStepE6;
        maxSkewE6 = config.maxSkewE6;
        backrunThresholdE6 = config.backrunThresholdE6;
        restoreFractionE6 = config.restoreFractionE6;
        restoreThresholdE6 = config.restoreThresholdE6;
    }

    /// @inheritdoc IVolatileFeeConfiguration
    function feeState(PoolId poolId)
        public
        view
        returns (uint40 blockNumber, uint160 sqrtPriceTopX96, uint24 askPermFeeE6, uint24 tempFeeE6, bool tempOnBid)
    {
        VolatileFeeState storage state = _getVolatileFeeConfigurationStorage().feeState[poolId];
        blockNumber = state.blockNumber;
        sqrtPriceTopX96 = state.sqrtPriceTopX96;
        askPermFeeE6 = state.askPermFeeE6;
        tempFeeE6 = state.tempFeeE6;
        tempOnBid = state.tempOnBid;
    }

    /// @notice Validates the config, stores it, and resets the pool's fee state to neutral.
    /// @dev Resets block state, skew, permanent fee and temporary fee state.
    /// @param _poolId Pool to configure
    /// @param _feeConfig New config
    function _updateFeeConfig(PoolId _poolId, VolatileFeeConfig calldata _feeConfig) internal {
        _validateRestingSpreadE6(_feeConfig.restingSpreadE6);
        _validateFractionE6(_feeConfig.backrunCaptureFractionE6);
        _validateMaxSkewE6(_feeConfig.maxSkewE6, _feeConfig.restingSpreadE6);
        _validateMaxSkewStepE6(_feeConfig.maxSkewStepE6, _feeConfig.maxSkewE6, _feeConfig.restingSpreadE6);
        _validateMaxMidFadeE6(_feeConfig.maxMidFadeE6);
        _validateFractionE6(_feeConfig.restoreFractionE6);
        _validateThresholdE6(_feeConfig.backrunThresholdE6);
        _validateThresholdE6(_feeConfig.restoreThresholdE6);

        VolatileFeeConfigurationStorage storage $ = _getVolatileFeeConfigurationStorage();
        $.feeConfig[_poolId] = _feeConfig;
        // Clear block price and temporary fee, and reset the ask perm fee to restingSpread / 2 (rounded down).
        // The bid gets the remainder, so an odd spread puts the spare pip on the bid.
        // blockNumber 0 makes the next swap, even in this block, start fresh from the current pool price.
        $.feeState[_poolId] = VolatileFeeState({
            blockNumber: 0,
            sqrtPriceTopX96: 0,
            askPermFeeE6: _feeConfig.restingSpreadE6 / 2,
            tempFeeE6: 0,
            tempOnBid: false
        });
        emit FeeConfigUpdated(_poolId, _feeConfig);
    }

    /// @notice Reverts PoolNotInitialized unless the pool has a stored config.
    /// @dev Config is only ever seeded by the hook's pool-initialization entrypoint, which enforces
    ///      the hook address and dynamic fee and initializes the pool on the PoolManager in the same
    ///      call. A nonzero resting spread (validated nonzero on every write) therefore proves the
    ///      pool exists, uses this hook, and has a dynamic fee.
    /// @param _poolId Pool to check
    function _checkPoolInitialized(PoolId _poolId) internal view {
        if (_getVolatileFeeConfigurationStorage().feeConfig[_poolId].restingSpreadE6 == 0) {
            revert IDynamicFeeHook.PoolNotInitialized(_poolId);
        }
    }

    /// @notice Validates the resting spread, the permanent ask + bid fee pie
    /// @param _restingSpreadE6 The resting spread to validate
    function _validateRestingSpreadE6(uint24 _restingSpreadE6) internal pure {
        // restingSpreadE6 == 0 marks an uninitialized pool.
        if (_restingSpreadE6 == 0) revert RestingSpreadCannotBeZero();
        // Each side's fee is capped at MAX_FEE_E6, so the pie cannot exceed two ceilings.
        if (_restingSpreadE6 > 2 * VolatileFeeCalculation.MAX_FEE_E6) {
            revert RestingSpreadTooLarge(_restingSpreadE6);
        }
    }

    /// @notice Validates the skew ceiling against the resting spread and the fee ceiling
    /// @param _maxSkewE6 The skew ceiling to validate
    /// @param _restingSpreadE6 The resting spread the ceiling must fit inside
    function _validateMaxSkewE6(uint24 _maxSkewE6, uint24 _restingSpreadE6) internal pure {
        // A skew ceiling above the resting spread would let one side's fee exceed the whole spread.
        if (_maxSkewE6 > _restingSpreadE6) revert MaxSkewTooLarge(_maxSkewE6, _restingSpreadE6);
        // A ceiling below the neutral center rs / 2 would clamp the leaning side down, underflowing
        // newLeanPermFee - oldLeanPermFee in temporaryBackrunFee.
        if (2 * uint256(_maxSkewE6) < _restingSpreadE6) revert MaxSkewTooSmall(_maxSkewE6, _restingSpreadE6);
        // A perm fee can reach maxSkew, so anything above the fee ceiling is skew band the clamp
        // silently removes.
        if (_maxSkewE6 > VolatileFeeCalculation.MAX_FEE_E6) revert MaxSkewAboveMaxFee(_maxSkewE6);
    }

    /// @notice Validates the per-block skew step against the width of the permanent-fee band
    /// @dev Call after _validateMaxSkewE6, which guarantees 2 * maxSkew >= restingSpread
    /// @param _maxSkewStepE6 The step cap to validate
    /// @param _maxSkewE6 The validated skew ceiling
    /// @param _restingSpreadE6 The validated resting spread
    function _validateMaxSkewStepE6(uint24 _maxSkewStepE6, uint24 _maxSkewE6, uint24 _restingSpreadE6) internal pure {
        // Width of the perm-fee band; larger steps clamp to the same result.
        if (_maxSkewStepE6 > 2 * uint256(_maxSkewE6) - _restingSpreadE6) {
            revert MaxSkewStepTooLarge(_maxSkewStepE6, _maxSkewE6, _restingSpreadE6);
        }
    }

    /// @notice Validates the continuing-fade cap against the fee ceiling
    /// @param _maxMidFadeE6 The fade cap to validate
    function _validateMaxMidFadeE6(uint24 _maxMidFadeE6) internal pure {
        // The charged fee is clamped at MAX_FEE_E6, so a larger fade cap is dead band.
        if (_maxMidFadeE6 > VolatileFeeCalculation.MAX_FEE_E6) revert MaxMidFadeTooLarge(_maxMidFadeE6);
    }

    /// @notice Validates a fraction (backrunCaptureFractionE6 or restoreFractionE6) against 100% (1e6)
    /// @param _fractionE6 The fraction to validate
    function _validateFractionE6(uint24 _fractionE6) internal pure {
        // Capture cannot take more than the whole price move, and restore cannot add back more than the
        // permanent fee went down by.
        if (_fractionE6 > VolatileFeeCalculation.ONE_E6) revert FractionTooLarge(_fractionE6);
    }

    /// @notice Validates a threshold (backrunThresholdE6 or restoreThresholdE6) against 100% (1e6)
    /// @param _thresholdE6 The threshold to validate
    function _validateThresholdE6(uint24 _thresholdE6) internal pure {
        // A down move is always below 100%, so a threshold at or above it would only ever apply to up moves.
        if (_thresholdE6 >= VolatileFeeCalculation.ONE_E6) revert ThresholdTooLarge(_thresholdE6);
    }
}
