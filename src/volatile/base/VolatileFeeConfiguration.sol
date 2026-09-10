// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    IVolatileFeeConfiguration,
    VolatileFeeConfig,
    VolatileHookState
} from "../interfaces/IVolatileFeeConfiguration.sol";
import {IDynamicFeeHook} from "../../interfaces/IDynamicFeeHook.sol";
import {VolatileFeeCalculation} from "../libraries/VolatileFeeCalculation.sol";
import {HookRoles} from "../../base/HookRoles.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BlockNumberish} from "@uniswap/blocknumberish/src/BlockNumberish.sol";

/// @title VolatileFeeConfiguration
/// @notice Per-pool volatile fee config and state, managed by the config manager.
abstract contract VolatileFeeConfiguration is HookRoles, BlockNumberish, IVolatileFeeConfiguration {
    /// @notice Scalar for E6 precision (1e6 = 100%)
    uint256 internal constant ONE_E6 = 1e6;

    /// @custom:storage-location erc7201:uniswap.storage.VolatileFeeConfiguration
    struct VolatileFeeConfigurationStorage {
        /// @notice Per-pool config + state
        mapping(PoolId => VolatileHookState) hookState;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("uniswap.storage.VolatileFeeConfiguration")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant VOLATILE_FEE_CONFIGURATION_STORAGE_LOCATION =
        0x5d4cd891dc52dbf2064bf3b556cd164a438eebc4f9a9ba71ffb5a8f1380e1e00;

    /// @notice Accessor for this contract's ERC-7201 namespaced storage
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
        emit FeeConfigUpdated(poolId_, feeConfig_);
    }

    /// @inheritdoc IVolatileFeeConfiguration
    function batchUpdateFeeConfig(PoolId[] calldata poolIds_, VolatileFeeConfig[] calldata feeConfigs_)
        external
        onlyRole(CONFIG_MANAGER_ROLE)
    {
        if (poolIds_.length != feeConfigs_.length) revert LengthMismatch();
        for (uint256 i = 0; i < poolIds_.length; i++) {
            _checkPoolInitialized(poolIds_[i]);
            _updateFeeConfig(poolIds_[i], feeConfigs_[i]);
            emit FeeConfigUpdated(poolIds_[i], feeConfigs_[i]);
        }
    }

    /// @notice Fee config for a pool.
    /// @param poolId Pool to query
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
            uint24 backrunThresholdE6
        )
    {
        VolatileHookState storage config = _getVolatileFeeConfigurationStorage().hookState[poolId];
        return (
            config.restingSpreadE6,
            config.backrunCaptureFractionE6,
            config.midFadeRateE6,
            config.maxMidFadeE6,
            config.skewRateE6,
            config.maxSkewStepE6,
            config.maxSkewE6,
            config.backrunThresholdE6
        );
    }

    /// @notice Fee state for a pool.
    /// @param poolId Pool to query
    function feeState(PoolId poolId)
        public
        view
        returns (
            uint48 blockNumber,
            uint160 sqrtPriceTopX96,
            uint24 askPermFeeE6,
            uint24 askBaselineFeeE6,
            uint24 bidBaselineFeeE6
        )
    {
        VolatileHookState storage state = _getVolatileFeeConfigurationStorage().hookState[poolId];
        return
            (
                state.blockNumber,
                state.sqrtPriceTopX96,
                state.askPermFeeE6,
                state.askBaselineFeeE6,
                state.bidBaselineFeeE6
            );
    }

    /// @notice Validates the config, stores it, and resets the pool's fee state to neutral.
    /// @dev Bounds hold askPermFeeE6 in [restingSpreadE6 - maxSkewE6, maxSkewE6]; the reset to
    ///      restingSpreadE6 / 2 re-establishes it on every write.
    ///      Also resets sqrtPriceTopX96 to 0, so price impact is treated as 0 until the first swap.
    /// @param _poolId Pool to configure
    /// @param _feeConfig New config
    function _updateFeeConfig(PoolId _poolId, VolatileFeeConfig calldata _feeConfig) internal {
        uint256 rs = _feeConfig.restingSpreadE6;
        uint256 maxSkew = _feeConfig.maxSkewE6;
        // restingSpreadE6 == 0 marks an uninitialized pool.
        if (rs == 0) revert RestingSpreadCannotBeZero();
        // Each side's fee is capped at MAX_HOOK_FEE_E6, so the pie cannot exceed two ceilings.
        if (rs > 2 * VolatileFeeCalculation.MAX_HOOK_FEE_E6) revert RestingSpreadTooLarge(_feeConfig.restingSpreadE6);
        // The pool cannot capture more than 100% of the price move.
        if (_feeConfig.backrunCaptureFractionE6 > ONE_E6) {
            revert BackrunCaptureFractionTooLarge(_feeConfig.backrunCaptureFractionE6);
        }
        // A skew ceiling above the resting spread would let one side's fee exceed the whole spread.
        if (maxSkew > rs) revert MaxSkewTooLarge(_feeConfig.maxSkewE6, _feeConfig.restingSpreadE6);
        // A ceiling below the neutral center rs / 2 would clamp the leaning side down, underflowing
        // newPermFee - oldPermFee in temporaryBackrunFee.
        if (2 * maxSkew < rs) revert MaxSkewTooSmall(_feeConfig.maxSkewE6, _feeConfig.restingSpreadE6);
        // A perm fee can reach maxSkew, so anything above the fee ceiling is skew band the clamp
        // silently removes.
        if (maxSkew > VolatileFeeCalculation.MAX_HOOK_FEE_E6) revert MaxSkewAboveMaxHookFee(_feeConfig.maxSkewE6);
        // Width of the perm-fee band; larger steps clamp to the same result.
        if (_feeConfig.maxSkewStepE6 > 2 * maxSkew - rs) {
            revert MaxSkewStepTooLarge(_feeConfig.maxSkewStepE6, _feeConfig.maxSkewE6, _feeConfig.restingSpreadE6);
        }
        // baseline + fade is a uint24 add with baseline up to MAX_HOOK_FEE_E6; a fade above ~15.7e6
        // reverts the swap.
        if (_feeConfig.maxMidFadeE6 > VolatileFeeCalculation.MAX_HOOK_FEE_E6) {
            revert MaxMidFadeTooLarge(_feeConfig.maxMidFadeE6);
        }

        uint24 halfE6 = _feeConfig.restingSpreadE6 / 2;
        _getVolatileFeeConfigurationStorage().hookState[_poolId] = VolatileHookState({
            blockNumber: uint48(_getBlockNumberish()),
            sqrtPriceTopX96: 0,
            askPermFeeE6: halfE6,
            askBaselineFeeE6: halfE6,
            bidBaselineFeeE6: _feeConfig.restingSpreadE6 - halfE6,
            restingSpreadE6: _feeConfig.restingSpreadE6,
            backrunCaptureFractionE6: _feeConfig.backrunCaptureFractionE6,
            midFadeRateE6: _feeConfig.midFadeRateE6,
            maxMidFadeE6: _feeConfig.maxMidFadeE6,
            skewRateE6: _feeConfig.skewRateE6,
            maxSkewStepE6: _feeConfig.maxSkewStepE6,
            maxSkewE6: _feeConfig.maxSkewE6,
            backrunThresholdE6: _feeConfig.backrunThresholdE6
        });
    }

    /// @notice Reverts PoolNotInitialized unless the pool has a stored config.
    /// @param _poolId Pool to check
    function _checkPoolInitialized(PoolId _poolId) internal view {
        // restingSpreadE6 == 0 only before the pool's first _updateFeeConfig call, which forbids a
        // zero resting spread on every write afterward.
        if (_getVolatileFeeConfigurationStorage().hookState[_poolId].restingSpreadE6 == 0) {
            revert IDynamicFeeHook.PoolNotInitialized(_poolId);
        }
    }
}
