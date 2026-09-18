// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {VolatileFeeConfig} from "./IVolatileFeeConfiguration.sol";
import {IDynamicFeeHook} from "../../interfaces/IDynamicFeeHook.sol";

/// @notice Interface for VolatilePairHook
interface IVolatilePairHook is IDynamicFeeHook {
    /// @notice Thrown when poolKey.fee is not the dynamic-fee sentinel
    /// @param lpFee The fee that was provided
    error MustUseDynamicFee(uint24 lpFee);

    /// @notice Thrown when poolKey.hooks is not this contract
    /// @param hookAddress The address that was provided
    error InvalidHookAddress(address hookAddress);

    /// @notice Emitted when a pool is initialized through this hook
    /// @param poolKey The pool that was initialized
    /// @param sqrtPriceX96 The initial sqrt price
    /// @param feeConfig The fee config applied to the pool
    event PoolInitialized(PoolKey indexed poolKey, uint160 sqrtPriceX96, VolatileFeeConfig feeConfig);

    /// @notice Initializes a pool on the PoolManager and sets its fee config.
    /// @param poolKey Pool key; fee must be the dynamic-fee sentinel and hooks must be this contract
    /// @param sqrtPriceX96 Initial sqrt price
    /// @param feeConfig Fee config to seed for the pool
    /// @return tick Resulting tick
    function initializePool(PoolKey calldata poolKey, uint160 sqrtPriceX96, VolatileFeeConfig calldata feeConfig)
        external
        returns (int24 tick);
}
