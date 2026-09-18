// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {VolatileFeeConfiguration} from "../../../src/volatile/base/VolatileFeeConfiguration.sol";
import {VolatileFeeConfig, VolatileFeeState} from "../../../src/volatile/interfaces/IVolatileFeeConfiguration.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

contract VolatileFeeConfigurationImplementation is VolatileFeeConfiguration {
    constructor(address _configManager) initializer {
        _grantRole(CONFIG_MANAGER_ROLE, _configManager);
    }

    function setFeeState(PoolId poolId, VolatileFeeState calldata _feeState) external {
        _getVolatileFeeConfigurationStorage().feeState[poolId] = _feeState;
    }

    /// Skips the role and PoolNotInitialized checks, so it can seed a first config; `updateFeeConfig` cannot.
    function initializeFeeConfig(PoolId poolId, VolatileFeeConfig calldata config) external {
        _updateFeeConfig(poolId, config);
    }
}
