// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {VolatileFeeCalculation} from "../../../../src/volatile/libraries/VolatileFeeCalculation.sol";
import {VolatileVectorTestBase} from "../VolatileVectorTestBase.sol";

/// @title VolatileFeeCalculationS6Test
/// @notice Generator scenario S6, mid-block fees: eight swaps displaced from the block open, on the neutral
///         baseline and on baselines carried in from S1 and S5.
/// @dev Columns: case,baseAskE6,baseBidE6,dvE6,fAskE6,fBidE6. base = the block's first-swap baselines;
///      dvE6 = signed displacement from the block open; f = each side's fee at that displacement. Roles
///      follow the sign of dv and are assigned by the test; the library sees only (baseline, |dv|).
///      `s1_block2_baseline` pins the backrun charge growing from h + g (1450 + 1500), not h alone;
///      `crossed_below_open` is SPEC-GAP #2 (roles per current sign) and the continuing cap's equality
///      point (alpha_mid * 1000 == d_mid).
contract VolatileFeeCalculationS6Test is VolatileVectorTestBase {
    string constant DATA_PATH = "test/volatile/data/s6/s6_midblock.csv";

    uint24 constant MID_FADE_RATE_E6 = 200_000;
    uint24 constant MAX_MID_FADE_E6 = 200;

    struct Row {
        string name;
        uint24 baseAskE6;
        uint24 baseBidE6;
        int256 dvE6;
        uint256 fAskE6;
        uint256 fBidE6;
    }

    /// @notice Backrun side pays baseline + c * |dv|, uncapped: 5000 pips add 2500.
    function test_s6_displacementBackrunFee_matchesF() public view {
        Row[] memory rows = _rows();
        for (uint256 i = 0; i < rows.length; i++) {
            (uint24 baselineFeeE6, uint256 expectedFeeE6) =
                rows[i].dvE6 > 0 ? (rows[i].baseBidE6, rows[i].fBidE6) : (rows[i].baseAskE6, rows[i].fAskE6);
            uint256 feeE6 = VolatileFeeCalculation.displacementBackrunFee(
                baselineFeeE6, _abs(rows[i].dvE6), BACKRUN_CAPTURE_FRACTION_E6
            );
            assertGeWithinPip(feeE6, expectedFeeE6, _label(rows[i].name, "f backrun"));
        }
    }

    /// @notice Continuing side pays baseline + min(alpha_mid * |dv|, d_mid): 100 on 500 pips, 200 from 1000 up.
    function test_s6_displacementContinuingFee_matchesF() public view {
        Row[] memory rows = _rows();
        for (uint256 i = 0; i < rows.length; i++) {
            (uint24 baselineFeeE6, uint256 expectedFeeE6) =
                rows[i].dvE6 > 0 ? (rows[i].baseAskE6, rows[i].fAskE6) : (rows[i].baseBidE6, rows[i].fBidE6);
            uint256 feeE6 = VolatileFeeCalculation.displacementContinuingFee(
                baselineFeeE6, _abs(rows[i].dvE6), MID_FADE_RATE_E6, MAX_MID_FADE_E6
            );
            assertGeWithinPip(feeE6, expectedFeeE6, _label(rows[i].name, "f continuing"));
        }
    }

    function _rows() internal view returns (Row[] memory rows) {
        string[] memory lines = _dataLines(DATA_PATH);
        rows = new Row[](lines.length);
        for (uint256 i = 0; i < lines.length; i++) {
            string[] memory cols = vm.split(lines[i], ",");
            rows[i] = Row({
                name: cols[0],
                baseAskE6: uint24(vm.parseUint(cols[1])),
                baseBidE6: uint24(vm.parseUint(cols[2])),
                dvE6: vm.parseInt(cols[3]),
                fAskE6: vm.parseUint(cols[4]),
                fBidE6: vm.parseUint(cols[5])
            });
        }
    }
}
