// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseUUPSHook} from "../../src/base/BaseUUPSHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/// A UUPS hook declaring beforeSwap only, so it cannot validate against the proxy's frozen flag set.
contract VolatileDifferentFlagsMock is BaseUUPSHook {
    constructor(IPoolManager _manager) BaseUUPSHook(_manager) {}

    function _authorizeUpgrade(address) internal view override {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}
