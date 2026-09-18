// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VolatileFeeConfiguration} from "./base/VolatileFeeConfiguration.sol";
import {VolatileFeeCalculation} from "./libraries/VolatileFeeCalculation.sol";
import {IVolatilePairHook} from "./interfaces/IVolatilePairHook.sol";
import {IDynamicFeeHook} from "../interfaces/IDynamicFeeHook.sol";
import {BaseDynamicFeeHook} from "../base/BaseDynamicFeeHook.sol";
import {VolatileFeeConfig, VolatileFeeState} from "./interfaces/IVolatileFeeConfiguration.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

/// @title VolatilePairHook
/// @notice Dynamic fee hook for volatile pairs (v2 skew + backrun algorithm); UUPS proxy is the
///         registered v4 hook. The fee math lives in VolatileFeeCalculation; this contract loads
///         state, calls it, and stores.
/// @dev Ask = a buy = zeroForOne false; bid = a sell = zeroForOne true.
/// @custom:security-contact security@uniswap.org
contract VolatilePairHook is BaseDynamicFeeHook, VolatileFeeConfiguration, IVolatilePairHook {
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @param _manager Uniswap v4 PoolManager
    constructor(IPoolManager _manager) BaseDynamicFeeHook(_manager) {}

    /// @inheritdoc IVolatilePairHook
    function initializePool(PoolKey calldata poolKey, uint160 sqrtPriceX96, VolatileFeeConfig calldata feeConfiguration)
        external
        onlyRole(POOL_INITIALIZER_ROLE)
        returns (int24 tick)
    {
        if (!poolKey.fee.isDynamicFee()) {
            revert MustUseDynamicFee(poolKey.fee);
        }
        if (poolKey.hooks != IHooks(address(this))) {
            revert InvalidHookAddress(address(poolKey.hooks));
        }
        _updateFeeConfig(poolKey.toId(), feeConfiguration);
        tick = poolManager.initialize(poolKey, sqrtPriceX96);
        emit PoolInitialized(poolKey, sqrtPriceX96, feeConfiguration);
    }

    /// @inheritdoc IDynamicFeeHook
    function getFee(PoolKey calldata key) external view returns (uint24 feeE6ZeroForOne, uint24 feeE6OneForZero) {
        PoolId poolId = key.toId();
        _checkPoolInitialized(poolId);

        (VolatileFeeState memory poolState, VolatileFeeConfig memory config, uint160 currentSqrtPriceX96,) =
            _loadTopOfBlockState(poolId);

        feeE6ZeroForOne = _getFee(poolState, config, currentSqrtPriceX96, true);
        feeE6OneForZero = _getFee(poolState, config, currentSqrtPriceX96, false);
    }

    /// @notice Computes the swap's dynamic fee and overrides it via the v4 fee flag
    /// @param key Pool key of the pool that a swap will be made against
    /// @param params Uni V4 swap parameters
    /// @return selector Always IHooks.beforeSwap selector
    /// @return delta Always zero for this hook
    /// @return lpFeeOverride Fee for this swap direction with the override flag set
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4 selector, BeforeSwapDelta delta, uint24 lpFeeOverride)
    {
        PoolId poolId = key.toId();
        (
            VolatileFeeState memory poolState,
            VolatileFeeConfig memory config,
            uint160 currentSqrtPriceX96,
            bool isNewBlock
        ) = _loadTopOfBlockState(poolId);

        // Persists top of block state if this is the first swap of a new block.
        if (isNewBlock) _getVolatileFeeConfigurationStorage().feeState[poolId] = poolState;

        uint24 feeE6 = _getFee(poolState, config, currentSqrtPriceX96, params.zeroForOne);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feeE6 | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// @notice Loads a pool's config and state, advancing the state to this block's skew and temp fee
    ///         in memory without writing.
    /// @dev New block: steps the permanent skew and prices the backrun charge from the price impact
    ///      since the previous open, then caches the new open. Same block: returns the stored values
    ///      unchanged.
    /// @param _poolId Pool id
    /// @return poolState Fee state, advanced if isNewBlock
    /// @return config Fee config
    /// @return currentSqrtPriceX96 Pool's current sqrt price
    /// @return isNewBlock True on the first swap of a new block, or right after a config reset
    function _loadTopOfBlockState(PoolId _poolId)
        private
        view
        returns (
            VolatileFeeState memory poolState,
            VolatileFeeConfig memory config,
            uint160 currentSqrtPriceX96,
            bool isNewBlock
        )
    {
        VolatileFeeConfigurationStorage storage $ = _getVolatileFeeConfigurationStorage();
        poolState = $.feeState[_poolId];
        config = $.feeConfig[_poolId];
        (currentSqrtPriceX96,,,) = poolManager.getSlot0(_poolId);
        uint40 currentBlock = uint40(_getBlockNumberish());

        // If the stored pool state is fresh, return it
        if (currentBlock <= poolState.blockNumber) return (poolState, config, currentSqrtPriceX96, false);
        isNewBlock = true;

        // Otherwise, cache the cached pool state
        // Update fee states only when there's a previous price to compare against
        if (poolState.sqrtPriceTopX96 != 0) {
            (uint256 blockPriceImpactE6, bool blockPriceImpactUp) =
                VolatileFeeCalculation.relativeMoveE6(currentSqrtPriceX96, poolState.sqrtPriceTopX96);
            (poolState.askPermFeeE6, poolState.tempFeeE6, poolState.tempOnBid) = VolatileFeeCalculation.newPermAndTempFee(
                config, poolState.askPermFeeE6, blockPriceImpactE6, blockPriceImpactUp
            );
        }
        poolState.sqrtPriceTopX96 = currentSqrtPriceX96;
        poolState.blockNumber = currentBlock;
    }

    /// @notice Fee one swap direction pays, escalated from the block's baseline by in-block displacement.
    /// @dev Never reads the swap amount; size-independence is what makes `getFee` well defined.
    /// @param _poolState Pool's top-of-block fee state
    /// @param _config Pool's fee config
    /// @param _currentSqrtPriceX96 Pool's current sqrt price
    /// @param _zeroForOne Swap direction
    /// @return Fee for this direction, clamped to VolatileFeeCalculation.MAX_HOOK_FEE_E6
    function _getFee(
        VolatileFeeState memory _poolState,
        VolatileFeeConfig memory _config,
        uint160 _currentSqrtPriceX96,
        bool _zeroForOne
    ) private pure returns (uint24) {
        (uint256 displacementFromTopE6, bool displacedUp) = VolatileFeeCalculation.relativeMoveE6(
            _currentSqrtPriceX96, _poolState.sqrtPriceTopX96
        );
        // A sell (zeroForOne) pays the bid baseline, a buy pays the ask baseline.
        uint24 baselineFeeE6 = VolatileFeeCalculation.baselineFee(_poolState, _config.restingSpreadE6, _zeroForOne);

        if (_zeroForOne == displacedUp) {
            // Trading against the displacement is a backrun.
            return VolatileFeeCalculation.displacementBackrunFee(
                baselineFeeE6, displacementFromTopE6, _config.backrunCaptureFractionE6
            );
        } else {
            // Trading in the same direction the displacement is a continuation, we apply a trend fee
            return VolatileFeeCalculation.displacementContinuingFee(
                baselineFeeE6, displacementFromTopE6, _config.midFadeRateE6, _config.maxMidFadeE6
            );
        }
    }
}
