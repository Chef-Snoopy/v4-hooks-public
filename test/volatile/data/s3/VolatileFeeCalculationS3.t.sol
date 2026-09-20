// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {VolatileFeeCalculation} from "../../../../src/volatile/libraries/VolatileFeeCalculation.sol";
import {VolatileFeeConfig} from "../../../../src/volatile/interfaces/IVolatileFeeConfiguration.sol";
import {VolatileVectorTestBase} from "../VolatileVectorTestBase.sol";

/// @title VolatileFeeCalculationS3Test
/// @notice Generator scenario S3, the skew-step cap: |PI| below, at, and above d_top / alpha_top, plus a
///         mirrored down move, each row from the neutral state.
/// @dev Columns: piE6,hAskE6,hBidE6,gAskE6,gBidE6,fAskE6,fBidE6. Every |PI| is below cutoff, so g is the
///      skew step alone. PI 300 and 400 both land at RS/2 + d_top, pinning the cap inclusive.
contract VolatileFeeCalculationS3Test is VolatileVectorTestBase {
    string constant DATA_PATH = "test/volatile/data/s3/s3_dtop.csv";

    uint24 constant SKEW_RATE_E6 = 1_000_000;
    uint24 constant MAX_SKEW_STEP_E6 = 300;
    uint24 constant MAX_SKEW_E6 = 900;

    struct Row {
        int256 piE6;
        uint24 hAskE6;
        uint24 hBidE6;
        uint256 gAskE6;
        uint256 gBidE6;
        uint256 fAskE6;
        uint256 fBidE6;
    }

    function test_s3_newPermanentFee_matchesH() public view {
        Row[] memory rows = _rows();
        for (uint256 i = 0; i < rows.length; i++) {
            uint256 newLeanPermFeeE6 = VolatileFeeCalculation.newPermanentFee(
                NEUTRAL_PERM_FEE_E6,
                _moveFromE6(_abs(rows[i].piE6), rows[i].piE6 > 0),
                SKEW_RATE_E6,
                MAX_SKEW_STEP_E6,
                MAX_SKEW_E6
            );
            (uint256 newAskPermFeeE6, uint256 newBidPermFeeE6) = rows[i].piE6 > 0
                ? (newLeanPermFeeE6, RESTING_SPREAD_E6 - newLeanPermFeeE6)
                : (RESTING_SPREAD_E6 - newLeanPermFeeE6, newLeanPermFeeE6);
            assertGeWithinPip(newAskPermFeeE6, rows[i].hAskE6, _label(_name(rows[i]), "hAsk"));
            assertGeWithinPip(newBidPermFeeE6, rows[i].hBidE6, _label(_name(rows[i]), "hBid"));
        }
    }

    function test_s3_temporaryBackrunFee_matchesG() public view {
        Row[] memory rows = _rows();
        for (uint256 i = 0; i < rows.length; i++) {
            (uint24 newLeanPermFeeE6, uint256 expectedBackrunTemp) =
                rows[i].piE6 > 0 ? (rows[i].hAskE6, rows[i].gBidE6) : (rows[i].hBidE6, rows[i].gAskE6);
            uint256 tempFeeE6 = VolatileFeeCalculation.temporaryBackrunFee(
                newLeanPermFeeE6,
                NEUTRAL_PERM_FEE_E6,
                _moveFromE6(_abs(rows[i].piE6), rows[i].piE6 > 0),
                BACKRUN_CAPTURE_FRACTION_E6,
                BACKRUN_THRESHOLD_E6
            );
            assertGeWithinPip(tempFeeE6, expectedBackrunTemp, _label(_name(rows[i]), "g backrun"));
        }
    }

    function test_s3_newPermAndTempFee_fromNeutral() public view {
        Row[] memory rows = _rows();
        VolatileFeeConfig memory config = _feeConfig(SKEW_RATE_E6, MAX_SKEW_STEP_E6, MAX_SKEW_E6);
        for (uint256 i = 0; i < rows.length; i++) {
            (uint256 newAskPermFeeE6, uint256 askBaselineFeeE6, uint256 bidBaselineFeeE6) =
                _newPermAndBaselines(config, NEUTRAL_PERM_FEE_E6, _abs(rows[i].piE6), rows[i].piE6 > 0);
            assertGeWithinPip(newAskPermFeeE6, rows[i].hAskE6, _label(_name(rows[i]), "hAsk"));
            assertGeWithinPip(askBaselineFeeE6, rows[i].fAskE6, _label(_name(rows[i]), "fAsk"));
            assertGeWithinPip(bidBaselineFeeE6, rows[i].fBidE6, _label(_name(rows[i]), "fBid"));
        }
    }

    function _name(Row memory row) internal pure returns (string memory) {
        return string.concat("PI ", vm.toString(row.piE6));
    }

    function _rows() internal view returns (Row[] memory rows) {
        string[] memory lines = _dataLines(DATA_PATH);
        rows = new Row[](lines.length);
        for (uint256 i = 0; i < lines.length; i++) {
            string[] memory cols = vm.split(lines[i], ",");
            rows[i] = Row({
                piE6: vm.parseInt(cols[0]),
                hAskE6: uint24(vm.parseUint(cols[1])),
                hBidE6: uint24(vm.parseUint(cols[2])),
                gAskE6: vm.parseUint(cols[3]),
                gBidE6: vm.parseUint(cols[4]),
                fAskE6: vm.parseUint(cols[5]),
                fBidE6: vm.parseUint(cols[6])
            });
        }
    }
}
