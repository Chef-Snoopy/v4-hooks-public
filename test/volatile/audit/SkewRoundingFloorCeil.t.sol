// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// Move rounded DOWN (E6 or E12), step rounded UP. Error = step_impl - step_float in pips.
contract SkewRoundingFloorCeilTest is Test {
    uint256 internal constant E18 = 1e18;
    uint256 internal constant Q48 = 2 ** 48;

    function _moveFloor(uint256 sqrtNew, uint256 sqrtRef, uint256 scale) internal pure returns (uint256) {
        uint256 sqrtRatioX96 = sqrtRef * Q48 / sqrtNew;
        uint256 ratioX96 = sqrtRatioX96 * sqrtRatioX96;
        if (ratioX96 == 0) ratioX96 = 1;
        return (FixedPoint96.Q96 - ratioX96) * scale / ratioX96; // floor
    }

    function _stepCeil(uint24 skewRateE6, uint256 move, uint256 scale) internal pure returns (uint256) {
        return FixedPointMathLib.mulDivUp(skewRateE6, move, scale);
    }

    function _stepFloatE18(uint256 sqrtNew, uint256 sqrtRef, uint24 skewRateE6) internal pure returns (uint256) {
        uint256 moveE6E18 =
            FixedPointMathLib.fullMulDiv(sqrtNew * sqrtNew - sqrtRef * sqrtRef, 1e6 * E18, sqrtRef * sqrtRef);
        return moveE6E18 * skewRateE6 / 1e6;
    }

    /// Floor at E6 then ceil can land BELOW the float: move 6.99 pips, float 1.0485, impl 1.
    function test_floorE6_thenCeil_canGoBelowFloat() public pure {
        uint256 sqrtRef = FixedPoint96.Q96;
        uint256 sqrtNew = sqrtRef + sqrtRef * 34_949_939 / 1e13; // sqrt(1 + 6.99e-6) - 1
        uint24 skewRate = 150_000;

        uint256 stepFloat = _stepFloatE18(sqrtNew, sqrtRef, skewRate);
        uint256 pi = _moveFloor(sqrtNew, sqrtRef, 1e6);
        uint256 step = _stepCeil(skewRate, pi, 1e6);

        console.log("PI floored (E6):", pi);
        console.log("float step (E18):", stepFloat);
        console.log("impl step:", step);
        assertEq(pi, 6);
        assertEq(step, 1);
        assertLt(step * E18, stepFloat, "impl below float");
        console.log("shortfall (E18):", stepFloat - step * E18);
    }

    /// Bound at E6: error in (-skewRate/1e6, 1).
    function testFuzz_floorE6_thenCeil_bound(uint160 refSeed, uint64 deltaSeed, uint24 skewRate) public pure {
        uint256 sqrtRef = bound(uint256(refSeed), TickMath.MIN_SQRT_PRICE, 2 ** 120);
        uint256 sqrtNew = sqrtRef + bound(uint256(deltaSeed), 1, sqrtRef / 2);
        skewRate = uint24(bound(uint256(skewRate), 1, type(uint24).max));

        int256 stepFloat = int256(_stepFloatE18(sqrtNew, sqrtRef, skewRate));
        int256 step = int256(_stepCeil(skewRate, _moveFloor(sqrtNew, sqrtRef, 1e6), 1e6) * E18);
        int256 err = step - stepFloat;

        assertGt(err, -int256(uint256(skewRate)) * 1e12, "error > -skewRate/1e6 pips");
        assertLt(err, int256(E18), "error < 1 pip");
    }

    /// Bound at E12: error in (-skewRate/1e12, 1).
    function testFuzz_floorE12_thenCeil_bound(uint160 refSeed, uint64 deltaSeed, uint24 skewRate) public pure {
        uint256 sqrtRef = bound(uint256(refSeed), TickMath.MIN_SQRT_PRICE, 2 ** 120);
        uint256 sqrtNew = sqrtRef + bound(uint256(deltaSeed), 1, sqrtRef / 2);
        skewRate = uint24(bound(uint256(skewRate), 1, type(uint24).max));

        int256 stepFloat = int256(_stepFloatE18(sqrtNew, sqrtRef, skewRate));
        int256 step = int256(_stepCeil(skewRate, _moveFloor(sqrtNew, sqrtRef, 1e12), 1e12) * E18);
        int256 err = step - stepFloat;

        assertGt(err, -int256(uint256(skewRate)) * 1e6, "error > -skewRate/1e12 pips");
        assertLt(err, int256(E18), "error < 1 pip");
    }

    /// Dust: a 1 unit sqrt price change gives 0 at both scales, but the final ceil still turns any
    /// move the floor does not erase into a full pip.
    function test_floorThenCeil_dustStep() public pure {
        uint256 sqrtRef = FixedPoint96.Q96;
        uint24 skewRate = 100_000;

        uint256 oneUnit = sqrtRef + 1;
        console.log("1 unit, E6:  step", _stepCeil(skewRate, _moveFloor(oneUnit, sqrtRef, 1e6), 1e6));
        console.log("1 unit, E12: step", _stepCeil(skewRate, _moveFloor(oneUnit, sqrtRef, 1e12), 1e12));

        uint256 onePipE6 = sqrtRef + sqrtRef * 5 / 1e7; // ~1e-6 relative price move
        uint256 onePipE12 = sqrtRef + sqrtRef * 5 / 1e13; // ~1e-12 relative price move
        console.log("1e-6 move,  E6:  step", _stepCeil(skewRate, _moveFloor(onePipE6, sqrtRef, 1e6), 1e6));
        console.log("1e-12 move, E12: step", _stepCeil(skewRate, _moveFloor(onePipE12, sqrtRef, 1e12), 1e12));

        assertEq(_stepCeil(skewRate, _moveFloor(oneUnit, sqrtRef, 1e6), 1e6), 0);
        assertEq(_stepCeil(skewRate, _moveFloor(oneUnit, sqrtRef, 1e12), 1e12), 0);
        assertEq(_stepCeil(skewRate, _moveFloor(onePipE6, sqrtRef, 1e6), 1e6), 1);
        assertEq(_stepCeil(skewRate, _moveFloor(onePipE12, sqrtRef, 1e12), 1e12), 1);
    }
}
