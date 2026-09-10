// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {VolatileFeeCalculation} from "../../../src/volatile/libraries/VolatileFeeCalculation.sol";
import {VolatileFeeConfig} from "../../../src/volatile/interfaces/IVolatileFeeConfiguration.sol";

/// All `*E6` values are pips; 1e6 = 100%.
abstract contract VolatileFuzzTestBase is Test {
    uint24 internal constant MAX_HOOK_FEE_E6 = uint24(VolatileFeeCalculation.MAX_HOOK_FEE_E6); // 999_998

    uint24 internal constant MAX_RESTING_SPREAD_E6 = 2 * MAX_HOOK_FEE_E6; // 1_999_996

    /// `priceImpact` against 2**96 is 16_778_216 = 2**24 + 1000: truncated to uint24 the move would read 1000.
    uint160 internal constant SQRT_PRICE_UP_16_778_216_E6 = 334059372310633655172500143626;

    struct ConfigSeed {
        uint24 restingSpreadSeed;
        uint24 backrunCaptureSeed;
        uint24 midFadeRateSeed;
        uint24 maxMidFadeSeed;
        uint24 skewRateSeed;
        uint24 maxSkewStepSeed;
        uint24 maxSkewSeed;
        uint24 backrunThresholdSeed;
    }

    /// Passes every `_updateFeeConfig` check. At RS = MAX_RESTING_SPREAD_E6 the reset split is 999_998 / 999_998 with a
    /// zero step band.
    function _boundFeeConfig(ConfigSeed memory s) internal pure returns (VolatileFeeConfig memory config) {
        uint24 restingSpreadE6 = uint24(bound(uint256(s.restingSpreadSeed), 1, MAX_RESTING_SPREAD_E6));
        // ceil(RS / 2): the bid's reset perm fee RS - RS / 2 must not exceed the ceiling
        uint256 maxSkewLoE6 = (uint256(restingSpreadE6) + 1) / 2;
        uint256 maxSkewHiE6 = FixedPointMathLib.min(restingSpreadE6, MAX_HOOK_FEE_E6);
        uint24 maxSkewE6 = uint24(bound(uint256(s.maxSkewSeed), maxSkewLoE6, maxSkewHiE6));
        config = VolatileFeeConfig({
            restingSpreadE6: restingSpreadE6,
            backrunCaptureFractionE6: uint24(bound(uint256(s.backrunCaptureSeed), 0, VolatileFeeCalculation.ONE_E6)),
            midFadeRateE6: s.midFadeRateSeed,
            maxMidFadeE6: uint24(bound(uint256(s.maxMidFadeSeed), 0, MAX_HOOK_FEE_E6)),
            skewRateE6: s.skewRateSeed,
            // 2 * maxSkew - RS is the width of the perm-fee band [RS - maxSkew, maxSkew]
            maxSkewStepE6: uint24(bound(uint256(s.maxSkewStepSeed), 0, 2 * uint256(maxSkewE6) - restingSpreadE6)),
            maxSkewE6: maxSkewE6,
            backrunThresholdE6: s.backrunThresholdSeed
        });
    }
}
