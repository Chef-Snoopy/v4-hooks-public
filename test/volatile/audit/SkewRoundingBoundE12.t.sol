// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// Same double round-up as the library, with the move carried at E12 instead of E6.
contract SkewRoundingBoundE12Test is Test {
    uint256 internal constant E18 = 1e18;
    uint256 internal constant ONE_E12 = 1e12;
    uint256 internal constant Q48 = 2 ** 48;

    /// relativeMoveE6 with 1e12 in place of 1e6, up-move branch.
    function _moveE12(uint256 sqrtNew, uint256 sqrtRef) internal pure returns (uint256) {
        uint256 sqrtRatioX96 = sqrtRef * Q48 / sqrtNew;
        uint256 ratioX96 = sqrtRatioX96 * sqrtRatioX96;
        if (ratioX96 == 0) ratioX96 = 1;
        return FixedPointMathLib.divUp((FixedPoint96.Q96 - ratioX96) * ONE_E12, ratioX96);
    }

    /// newPermanentFee's step with an E12 move: skewRate (E6) * move (E12) / 1e12 gives pips (E6).
    function _stepE12(uint24 skewRateE6, uint256 moveE12) internal pure returns (uint256) {
        return FixedPointMathLib.mulDivUp(skewRateE6, moveE12, ONE_E12);
    }

    /// Exact float step in pips, E18-scaled.
    function _stepFloatE18(uint256 sqrtNew, uint256 sqrtRef, uint24 skewRateE6) internal pure returns (uint256) {
        uint256 moveE6E18 =
            FixedPointMathLib.fullMulDiv(sqrtNew * sqrtNew - sqrtRef * sqrtRef, 1e6 * E18, sqrtRef * sqrtRef);
        return moveE6E18 * skewRateE6 / 1e6;
    }

    /// The E6 example that gave error 1.025 (0.975 -> 2) now gives 0.975 -> 1.
    function test_e12_previousExample_staysWithinOnePip() public pure {
        uint256 sqrtRef = FixedPoint96.Q96;
        uint256 sqrtNew = sqrtRef + sqrtRef * 32_499_947 / 1e13;
        uint24 skewRate = 150_000;

        uint256 stepFloat = _stepFloatE18(sqrtNew, sqrtRef, skewRate);
        uint256 step = _stepE12(skewRate, _moveE12(sqrtNew, sqrtRef));

        console.log("float step (E18):", stepFloat);
        console.log("impl step, E12 double round-up:", step);
        assertEq(step, 1);
        assertLt(step * E18 - stepFloat, E18, "error < 1 pip");
    }

    /// Bound: error in [0, 1 + skewRate / 1e12). Fuzzed over price pairs and skew rates.
    function testFuzz_e12_errorBound(uint160 refSeed, uint64 deltaSeed, uint24 skewRate) public pure {
        // Keep sqrtNew^2 inside uint256 for the exact float computation.
        uint256 sqrtRef = bound(uint256(refSeed), TickMath.MIN_SQRT_PRICE, 2 ** 120);
        uint256 sqrtNew = sqrtRef + bound(uint256(deltaSeed), 1, sqrtRef / 2);
        skewRate = uint24(bound(uint256(skewRate), 1, type(uint24).max));

        uint256 stepFloat = _stepFloatE18(sqrtNew, sqrtRef, skewRate);
        uint256 step = _stepE12(skewRate, _moveE12(sqrtNew, sqrtRef));
        uint256 stepE18 = step * E18;

        assertGe(stepE18, stepFloat, "never below float");
        // 1 pip plus skewRate / 1e12 pips, in E18.
        assertLt(stepE18 - stepFloat, E18 + uint256(skewRate) * 1e6, "error < 1 + skewRate/1e12");
    }

    /// The residual: a float step just under an integer can still round to the next integer plus one.
    /// Searches for a price pair where float in (0.9999999, 1) and the E12 double round returns 2.
    function test_e12_slicerBelowInteger_canStillOvershootByOnePip() public pure {
        uint256 sqrtRef = FixedPoint96.Q96;
        uint24 skewRate = 150_000; // step 1.0 at exactly 6.666666.. pips of move
        // Target: move * 1e12 just below 6_666_666_666_666.67, so float < 1 but ceil(move E12) * 0.15 > 1.
        // sqrt(1 + 6.666666666666e-6) - 1 ~= 3.3333277777774e-6. Start slightly below and step up.
        uint256 start = sqrtRef + sqrtRef * 33_333_277_777_774 / 1e19;

        bool found;
        uint256 stepFloat;
        uint256 step;
        for (uint256 i = 0; i < 4000; i++) {
            uint256 sqrtNew = start + i * 1e13;
            stepFloat = _stepFloatE18(sqrtNew, sqrtRef, skewRate);
            if (stepFloat >= E18) break;
            step = _stepE12(skewRate, _moveE12(sqrtNew, sqrtRef));
            if (step == 2) {
                found = true;
                break;
            }
        }
        console.log("found:", found);
        console.log("float step (E18):", stepFloat);
        console.log("impl step:", step);
        if (found) {
            uint256 err = step * E18 - stepFloat;
            console.log("error (E18):", err);
            assertGt(err, E18);
            assertLt(err, E18 + uint256(skewRate) * 1e6);
        }
    }
}
