// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VolatileFeeConfiguration} from "./base/VolatileFeeConfiguration.sol";
import {VolatileFeeCalculation} from "./libraries/VolatileFeeCalculation.sol";
import {IVolatileHook} from "./interfaces/IVolatileHook.sol";
import {IDynamicFeeHook} from "../interfaces/IDynamicFeeHook.sol";
import {BaseDynamicFeeHook} from "../base/BaseDynamicFeeHook.sol";
import {VolatileFeeConfig, VolatileHookState} from "./interfaces/IVolatileFeeConfiguration.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

/// @title VolatileHook
/// @notice Dynamic fee hook for volatile pairs (v2 skew + backrun algorithm); UUPS proxy is the
///         registered v4 hook. The fee math lives in VolatileFeeCalculation; this contract loads
///         state, calls it, and stores.
/// @dev Ask = a buy = zeroForOne false; bid = a sell = zeroForOne true.
/// @custom:security-contact security@uniswap.org
contract VolatileHook is BaseDynamicFeeHook, VolatileFeeConfiguration, IVolatileHook {
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @param _manager Uniswap v4 PoolManager
    constructor(IPoolManager _manager) BaseDynamicFeeHook(_manager) {}

    /// @inheritdoc IVolatileHook
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

    /// @notice Computes the swap's dynamic fee and overrides it via the v4 fee flag.
    /// @dev The first swap of a block persists the advanced top-of-block state; every swap then
    ///      prices via `_getFee`.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        (VolatileHookState memory poolState, uint160 currentSqrtPriceX96, bool isNewBlock) =
            _loadTopOfBlockState(poolId);

        if (isNewBlock) {
            VolatileHookState storage stored = _getVolatileFeeConfigurationStorage().hookState[poolId];
            stored.blockNumber = poolState.blockNumber;
            stored.sqrtPriceTopX96 = poolState.sqrtPriceTopX96;
            stored.askPermFeeE6 = poolState.askPermFeeE6;
            stored.askBaselineFeeE6 = poolState.askBaselineFeeE6;
            stored.bidBaselineFeeE6 = poolState.bidBaselineFeeE6;
        }

        uint24 feeE6 = _getFee(poolState, currentSqrtPriceX96, params.zeroForOne);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feeE6 | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// @inheritdoc IDynamicFeeHook
    /// @dev Previews the fee the next swap would pay, reverts if the pool is not initialized
    function getFee(PoolKey calldata key) external view returns (uint24 feeE6ZeroForOne, uint24 feeE6OneForZero) {
        PoolId poolId = key.toId();
        _checkPoolInitialized(poolId);

        (VolatileHookState memory poolState, uint160 currentSqrtPriceX96,) = _loadTopOfBlockState(poolId);

        feeE6ZeroForOne = _getFee(poolState, currentSqrtPriceX96, true);
        feeE6OneForZero = _getFee(poolState, currentSqrtPriceX96, false);
    }

    /// @notice Loads a pool's state, advancing it to this block's baselines in memory without writing.
    /// @dev New block: recomputes baselines from the price impact since the previous open and caches
    ///      the new open. Same block: returns the stored values unchanged.
    /// @param _poolId Pool id
    /// @return poolState Config + state, advanced if isNewBlock
    /// @return currentSqrtPriceX96 Pool's current sqrt price
    /// @return isNewBlock True on the first swap of a new block, or right after a config reset
    function _loadTopOfBlockState(PoolId _poolId)
        private
        view
        returns (VolatileHookState memory poolState, uint160 currentSqrtPriceX96, bool isNewBlock)
    {
        poolState = _getVolatileFeeConfigurationStorage().hookState[_poolId];
        (currentSqrtPriceX96,,,) = poolManager.getSlot0(_poolId);
        uint48 currentBlock = uint48(_getBlockNumberish());

        // sqrtPriceTopX96 == 0 is the post-config-reset sentinel: no open yet, so open now.
        isNewBlock = currentBlock > poolState.blockNumber || poolState.sqrtPriceTopX96 == 0;
        if (!isNewBlock) return (poolState, currentSqrtPriceX96, false);

        // Price impact: this block's open vs. the previous block's open. No previous open ⇒ 0
        // (no lean, no backrun).
        uint256 blockPriceImpactE6;
        bool blockPriceImpactUp = true;
        if (poolState.sqrtPriceTopX96 != 0) {
            (blockPriceImpactE6, blockPriceImpactUp) =
                VolatileFeeCalculation.priceImpact(currentSqrtPriceX96, poolState.sqrtPriceTopX96);
        }
        (uint24 newAskPerm, uint24 askBaseline, uint24 bidBaseline) = VolatileFeeCalculation.newPermAndTempFee(
            poolState, poolState.askPermFeeE6, blockPriceImpactE6, blockPriceImpactUp
        );

        poolState.askPermFeeE6 = newAskPerm;
        poolState.askBaselineFeeE6 = _toFeeUint24(askBaseline);
        poolState.bidBaselineFeeE6 = _toFeeUint24(bidBaseline);
        poolState.sqrtPriceTopX96 = currentSqrtPriceX96;
        poolState.blockNumber = currentBlock;
    }

    /// @notice Fee one swap direction pays, escalated from the block's baseline by in-block displacement.
    /// @dev Never reads the swap amount; size-independence is what makes `getFee` well defined.
    /// @param _poolState Pool's config + top-of-block fee state
    /// @param _currentSqrtPriceX96 Pool's current sqrt price
    /// @param _zeroForOne Swap direction
    /// @return Fee for this direction, clamped to VolatileFeeCalculation.MAX_HOOK_FEE_E6
    function _getFee(VolatileHookState memory _poolState, uint160 _currentSqrtPriceX96, bool _zeroForOne)
        private
        pure
        returns (uint24)
    {
        (uint256 displacementFromTopE6, bool displacedUp) =
            VolatileFeeCalculation.priceImpact(_currentSqrtPriceX96, _poolState.sqrtPriceTopX96);
        // A sell (zeroForOne) pays the bid baseline, a buy pays the ask baseline.
        uint24 baselineFeeE6 = _zeroForOne ? _poolState.bidBaselineFeeE6 : _poolState.askBaselineFeeE6;

        // Trading against the displacement is a backrun.
        if (_zeroForOne == displacedUp) {
            return _toFeeUint24(
                VolatileFeeCalculation.midBlockBackrunFee(
                    baselineFeeE6, displacementFromTopE6, _poolState.backrunCaptureFractionE6
                )
            );
        }
        return _toFeeUint24(
            VolatileFeeCalculation.midBlockContinuingFee(
                baselineFeeE6, displacementFromTopE6, _poolState.midFadeRateE6, _poolState.maxMidFadeE6
            )
        );
    }

    /// @notice Clamps a fee to MAX_HOOK_FEE_E6.
    function _toFeeUint24(uint256 feeE6) private pure returns (uint24) {
        return uint24(feeE6 > VolatileFeeCalculation.MAX_HOOK_FEE_E6 ? VolatileFeeCalculation.MAX_HOOK_FEE_E6 : feeE6);
    }
}
