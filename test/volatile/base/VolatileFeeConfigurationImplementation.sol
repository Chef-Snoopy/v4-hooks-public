// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {VolatileFeeConfiguration} from "../../../src/volatile/base/VolatileFeeConfiguration.sol";
import {VolatileFeeConfig, VolatileHookState} from "../../../src/volatile/interfaces/IVolatileFeeConfiguration.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

contract VolatileFeeConfigurationImplementation is VolatileFeeConfiguration {
    constructor(address _configManager) initializer {
        _grantRole(CONFIG_MANAGER_ROLE, _configManager);
    }

    function setFeeState(PoolId poolId, VolatileHookState calldata _feeState) external {
        VolatileHookState storage state = _getVolatileFeeConfigurationStorage().hookState[poolId];
        state.blockNumber = _feeState.blockNumber;
        state.sqrtPriceTopX96 = _feeState.sqrtPriceTopX96;
        state.askPermFeeE6 = _feeState.askPermFeeE6;
        state.askBaselineFeeE6 = _feeState.askBaselineFeeE6;
        state.bidBaselineFeeE6 = _feeState.bidBaselineFeeE6;
    }

    /// Skips the role and PoolNotInitialized checks, so it can seed a first config; `updateFeeConfig` cannot.
    function initializeFeeConfig(PoolId poolId, VolatileFeeConfig calldata config) external {
        _updateFeeConfig(poolId, config);
    }
}
