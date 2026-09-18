// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {VolatilePairTestBase} from "./base/VolatilePairTestBase.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

/// Sequence properties with no unit counterpart, on the base's mocked PoolManager.
contract VolatilePairHookInvariantsTest is VolatilePairTestBase {
    using PoolIdLibrary for PoolKey;

    struct SwapNoise {
        address sender;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
        bytes hookData;
    }

    // -------------------------------------------------------------------------
    // Totality and the fee ceiling over arbitrary sequences
    // -------------------------------------------------------------------------

    /// Up-moves are unbounded here; a charge above MAX_HOOK_FEE_E6 compounds with a protocol fee to a dead 100%
    /// (extremeMove.t.sol).
    function testFuzz_anySequence_neverRevertsAndStaysWithinCeiling(
        ConfigSeed memory configSeed,
        SwapStep[8] memory steps,
        ConfigSeed[8] memory resetSeeds,
        uint8 resetMask
    ) public {
        _setConfig(_boundFeeConfig(configSeed));
        for (uint256 i = 0; i < steps.length; i++) {
            if ((resetMask >> i) & 1 == 1) _setConfig(_boundFeeConfig(resetSeeds[i]));
            _setAmmPrice(_boundSqrtPriceAbsolute(steps[i].priceSeed));
            // 0 re-quotes the cached open; 1 stands for every new block
            _advanceBlocks(steps[i].blockGap & 1);

            (uint24 quotedBidE6, uint24 quotedAskE6) = hook.getFee(testPoolKey);
            assertLe(quotedBidE6, MAX_HOOK_FEE_E6, "bid ceiling");
            assertLe(quotedAskE6, MAX_HOOK_FEE_E6, "ask ceiling");

            (,, uint24 fee) = hook.beforeSwap(
                address(this), testPoolKey, SwapParams(steps[i].zeroForOne, -1e18, 0), Constants.ZERO_BYTES
            );
            assertTrue(LPFeeLibrary.isOverride(fee), "override flag");
            assertEq(
                LPFeeLibrary.removeOverrideFlag(fee), steps[i].zeroForOne ? quotedBidE6 : quotedAskE6, "getFee parity"
            );
        }
    }

    // -------------------------------------------------------------------------
    // Swap-parameter independence
    // -------------------------------------------------------------------------

    function testFuzz_beforeSwap_feeAndStateDependOnlyOnDirection(
        ConfigSeed memory configSeed,
        SwapStep[3] memory history,
        SwapStep memory last,
        SwapNoise memory noise
    ) public {
        _setConfig(_boundFeeConfig(configSeed));
        for (uint256 i = 0; i < history.length; i++) {
            _setAmmPrice(_boundSqrtPriceAbsolute(history[i].priceSeed));
            _advanceBlocks(history[i].blockGap & 1);
            hook.beforeSwap(
                address(this), testPoolKey, SwapParams(history[i].zeroForOne, -1e18, 0), Constants.ZERO_BYTES
            );
        }
        _setAmmPrice(_boundSqrtPriceAbsolute(last.priceSeed));
        _advanceBlocks(last.blockGap & 1); // 1 puts both compared calls on the top-of-block write path

        (uint24 quotedBidE6, uint24 quotedAskE6) = hook.getFee(testPoolKey);
        PoolId poolId = testPoolKey.toId();

        uint256 snapshot = vm.snapshotState();
        (,, uint24 noisyFee) = hook.beforeSwap(
            noise.sender,
            testPoolKey,
            SwapParams(last.zeroForOne, noise.amountSpecified, noise.sqrtPriceLimitX96),
            noise.hookData
        );
        bytes32 noisyState = _rawStateHash(poolId);
        vm.revertToState(snapshot);
        (,, uint24 canonicalFee) =
            hook.beforeSwap(address(this), testPoolKey, SwapParams(last.zeroForOne, -1e18, 0), Constants.ZERO_BYTES);

        assertEq(noisyFee, canonicalFee, "fee read something other than the direction");
        assertEq(
            LPFeeLibrary.removeOverrideFlag(noisyFee), last.zeroForOne ? quotedBidE6 : quotedAskE6, "getFee parity"
        );
        assertEq(noisyState, _rawStateHash(poolId), "state written read something other than the direction");
    }
}
