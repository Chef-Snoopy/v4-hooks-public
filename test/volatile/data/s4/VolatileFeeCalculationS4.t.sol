// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {VolatileFeeCalculation} from "../../../../src/volatile/libraries/VolatileFeeCalculation.sol";
import {RelativeMove} from "../../../../src/volatile/libraries/RelativeMoveLibrary.sol";
import {VolatileFeeConfig} from "../../../../src/volatile/interfaces/IVolatileFeeConfiguration.sol";
import {VolatileVectorTestBase} from "../VolatileVectorTestBase.sol";

/// @title VolatileFeeCalculationS4Test
/// @notice Generator scenario S4, skew saturation: the same 20 bp up-move three blocks running pins the ask
///         at h_max, then a sub-cutoff move lands on the pinned state.
/// @dev Columns: block,priceE3,piE6,hAskE6,hBidE6,gAskE6,gBidE6,fAskE6,fBidE6. Every block clips to d_top,
///      so the rows pin d_top and h_max but not alpha_top.
contract VolatileFeeCalculationS4Test is VolatileVectorTestBase {
    string constant DATA_PATH = "test/volatile/data/s4/s4_saturation.csv";
    uint256 constant PRICE_ONE_E3 = 1e3;

    uint24 constant SKEW_RATE_E6 = 4_000_000;
    uint24 constant MAX_SKEW_STEP_E6 = 400;
    uint24 constant MAX_SKEW_E6 = 900;

    struct Row {
        uint256 blockNumber;
        uint256 priceE3;
        uint256 piE6;
        uint24 hAskE6;
        uint24 hBidE6;
        uint256 gAskE6;
        uint256 gBidE6;
        uint256 fAskE6;
        uint256 fBidE6;
    }

    function test_s4_relativeMove_matchesPI() public view {
        Row[] memory rows = _rows();
        for (uint256 i = 1; i < rows.length; i++) {
            RelativeMove move = VolatileFeeCalculation.relativeMove(
                _sqrtPriceX96(rows[i].priceE3, PRICE_ONE_E3), _sqrtPriceX96(rows[i - 1].priceE3, PRICE_ONE_E3)
            );
            assertMoveMatchesPI(move, rows[i].piE6, _label(_name(rows[i]), "PI"));
            assertEq(move.increased(), rows[i].priceE3 > rows[i - 1].priceE3, _label(_name(rows[i]), "direction"));
        }
    }

    function test_s4_newPermanentFee_matchesH() public view {
        Row[] memory rows = _rows();
        for (uint256 i = 1; i < rows.length; i++) {
            bool up = rows[i].priceE3 > rows[i - 1].priceE3;
            uint256 newLeanPermFeeE6 = VolatileFeeCalculation.newPermanentFee(
                up ? rows[i - 1].hAskE6 : rows[i - 1].hBidE6,
                _moveFromE6(rows[i].piE6, up),
                SKEW_RATE_E6,
                MAX_SKEW_STEP_E6,
                MAX_SKEW_E6
            );
            (uint256 newAskPermFeeE6, uint256 newBidPermFeeE6) = up
                ? (newLeanPermFeeE6, RESTING_SPREAD_E6 - newLeanPermFeeE6)
                : (RESTING_SPREAD_E6 - newLeanPermFeeE6, newLeanPermFeeE6);
            assertGeWithinPip(newAskPermFeeE6, rows[i].hAskE6, _label(_name(rows[i]), "hAsk"));
            assertGeWithinPip(newBidPermFeeE6, rows[i].hBidE6, _label(_name(rows[i]), "hBid"));
        }
    }

    /// @notice Same PI three blocks running gives g 1400 / 1050 / 1000: restitution shrinks 400 -> 50 -> 0
    ///         as the ask pins, so a fee computed from PI alone fails here.
    function test_s4_temporaryBackrunFee_matchesG() public view {
        Row[] memory rows = _rows();
        for (uint256 i = 1; i < rows.length; i++) {
            bool up = rows[i].priceE3 > rows[i - 1].priceE3;
            (uint24 newLeanE6, uint24 oldLeanE6, uint256 expectedBackrunTemp) = up
                ? (rows[i].hAskE6, rows[i - 1].hAskE6, rows[i].gBidE6)
                : (rows[i].hBidE6, rows[i - 1].hBidE6, rows[i].gAskE6);
            uint256 tempFeeE6 = VolatileFeeCalculation.temporaryBackrunFee(
                newLeanE6,
                oldLeanE6,
                _moveFromE6(rows[i].piE6, up),
                BACKRUN_CAPTURE_FRACTION_E6,
                BACKRUN_THRESHOLD_E6,
                RESTORE_FRACTION_E6,
                RESTORE_THRESHOLD_E6
            );
            assertGeWithinPip(tempFeeE6, expectedBackrunTemp, _label(_name(rows[i]), "g backrun"));
        }
    }

    function test_s4_newPermAndTempFee_singleShot() public view {
        Row[] memory rows = _rows();
        VolatileFeeConfig memory config = _feeConfig(SKEW_RATE_E6, MAX_SKEW_STEP_E6, MAX_SKEW_E6);
        for (uint256 i = 1; i < rows.length; i++) {
            (uint256 newAskPermFeeE6, uint256 askBaselineFeeE6, uint256 bidBaselineFeeE6) =
                _newPermAndBaselines(config, rows[i - 1].hAskE6, rows[i].piE6, rows[i].priceE3 > rows[i - 1].priceE3);
            assertGeWithinPip(newAskPermFeeE6, rows[i].hAskE6, _label(_name(rows[i]), "hAsk"));
            assertGeWithinPip(askBaselineFeeE6, rows[i].fAskE6, _label(_name(rows[i]), "fAsk"));
            assertGeWithinPip(bidBaselineFeeE6, rows[i].fBidE6, _label(_name(rows[i]), "fBid"));
        }
    }

    function test_s4_newPermAndTempFee_chainedFromPrices() public view {
        Row[] memory rows = _rows();
        VolatileFeeConfig memory config = _feeConfig(SKEW_RATE_E6, MAX_SKEW_STEP_E6, MAX_SKEW_E6);
        uint24 askPermFeeE6 = RESTING_SPREAD_E6 / 2;
        uint160 sqrtPriceTopX96 = _sqrtPriceX96(rows[0].priceE3, PRICE_ONE_E3);
        for (uint256 i = 1; i < rows.length; i++) {
            RelativeMove move =
                VolatileFeeCalculation.relativeMove(_sqrtPriceX96(rows[i].priceE3, PRICE_ONE_E3), sqrtPriceTopX96);
            assertMoveMatchesPI(move, rows[i].piE6, _label(_name(rows[i]), "PI"));

            (uint24 newAskPermFeeE6, uint256 askBaselineFeeE6, uint256 bidBaselineFeeE6) =
                _newPermAndBaselines(config, askPermFeeE6, move);
            assertGeWithinPip(newAskPermFeeE6, rows[i].hAskE6, _label(_name(rows[i]), "hAsk"));
            assertGeWithinPip(askBaselineFeeE6, rows[i].fAskE6, _label(_name(rows[i]), "fAsk"));
            assertGeWithinPip(bidBaselineFeeE6, rows[i].fBidE6, _label(_name(rows[i]), "fBid"));

            askPermFeeE6 = newAskPermFeeE6;
            sqrtPriceTopX96 = _sqrtPriceX96(rows[i].priceE3, PRICE_ONE_E3);
        }
    }

    function _name(Row memory row) internal pure returns (string memory) {
        return string.concat("block ", vm.toString(row.blockNumber));
    }

    function _rows() internal view returns (Row[] memory rows) {
        string[] memory lines = _dataLines(DATA_PATH);
        rows = new Row[](lines.length);
        for (uint256 i = 0; i < lines.length; i++) {
            string[] memory cols = vm.split(lines[i], ",");
            rows[i] = Row({
                blockNumber: vm.parseUint(cols[0]),
                priceE3: vm.parseUint(cols[1]),
                piE6: vm.parseUint(cols[2]),
                hAskE6: uint24(vm.parseUint(cols[3])),
                hBidE6: uint24(vm.parseUint(cols[4])),
                gAskE6: vm.parseUint(cols[5]),
                gBidE6: vm.parseUint(cols[6]),
                fAskE6: vm.parseUint(cols[7]),
                fBidE6: vm.parseUint(cols[8])
            });
        }
    }
}
