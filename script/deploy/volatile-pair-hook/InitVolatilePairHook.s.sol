// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {VolatilePairHook} from "../../../src/volatile/VolatilePairHook.sol";
import {Parameters, PoolParameters} from "./Parameters.sol";

contract InitVolatilePairHookScript is Script, Parameters {
    using PoolIdLibrary for PoolKey;

    /// @dev The hook only accepts dynamic-fee pools, so this is not configurable
    uint24 constant DYNAMIC_FEE = LPFeeLibrary.DYNAMIC_FEE_FLAG;

    function run() public {
        address hookAddress = vm.envAddress("HOOK_ADDRESS");
        string memory poolName = vm.envString("POOL");

        PoolParameters memory pool = getPoolParameters(block.chainid, poolName);

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(pool.currency0),
            currency1: Currency.wrap(pool.currency1),
            fee: DYNAMIC_FEE,
            tickSpacing: pool.tickSpacing,
            hooks: IHooks(hookAddress)
        });

        console2.log("Pool id:");
        console2.logBytes32(PoolId.unwrap(poolKey.toId()));
        console2.log("initializePool calldata (target is the hook):");
        console2.logBytes(abi.encodeCall(VolatilePairHook.initializePool, (poolKey, pool.sqrtPriceX96, pool.feeConfig)));

        vm.broadcast();
        int24 tick = VolatilePairHook(hookAddress).initializePool(poolKey, pool.sqrtPriceX96, pool.feeConfig);
        console2.log("Pool initialized at tick:", tick);
    }
}
