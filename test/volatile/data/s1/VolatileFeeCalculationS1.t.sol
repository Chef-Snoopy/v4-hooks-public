// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {VolatileFeeCalculation} from "../../../../src/volatile/libraries/VolatileFeeCalculation.sol";
import {VolatileFeeConfig} from "../../../../src/volatile/interfaces/IVolatileFeeConfiguration.sol";
import {VolatileVectorTestBase} from "../VolatileVectorTestBase.sol";

/// @title VolatileFeeCalculationS1Test
/// @notice Spec Worked Example B (generator scenario S1): five block opens from the neutral state.
/// @dev Columns: block,price,piE6,hAskE6,hBidE6,gAskE6,gBidE6,fAskE6,fBidE6. Blocks 4 and 5 have
///      fractional PI; block 4 hBid and block 5 gBid land one pip over the floored reference.
contract VolatileFeeCalculationS1Test is VolatileVectorTestBase {
    string constant DATA_PATH = "test/volatile/data/s1/s1_example_b.csv";
    uint256 constant PRICE_ONE = 1;

    uint24 constant SKEW_RATE_E6 = 150_000;
    uint24 constant MAX_SKEW_STEP_E6 = 300;
    uint24 constant MAX_SKEW_E6 = 900;

    struct Row {
        uint256 blockNumber;
        uint256 price;
        uint256 piE6;
        uint24 hAskE6;
        uint24 hBidE6;
        uint256 gAskE6;
        uint256 gBidE6;
        uint256 fAskE6;
        uint256 fBidE6;
    }

    function test_s1_relativeMoveE6_matchesPI() public view {
        Row[] memory rows = _rows();
        for (uint256 i = 1; i < rows.length; i++) {
            (uint256 moveE6, bool increased) = VolatileFeeCalculation.relativeMoveE6(
                _sqrtPriceX96(rows[i].price, PRICE_ONE), _sqrtPriceX96(rows[i - 1].price, PRICE_ONE)
            );
            assertGeWithinPip(moveE6, rows[i].piE6, _label(_name(rows[i]), "PI"));
            assertEq(increased, rows[i].price > rows[i - 1].price, _label(_name(rows[i]), "direction"));
        }
    }

    /// @notice Leaning side steps by min(alpha_top * PI, d_top), clamped at h_max; other side = RS - lean.
    function test_s1_newPermanentFee_matchesH() public view {
        Row[] memory rows = _rows();
        for (uint256 i = 1; i < rows.length; i++) {
            bool up = rows[i].price > rows[i - 1].price;
            uint256 newLeanPermFeeE6 = VolatileFeeCalculation.newPermanentFee(
                up ? rows[i - 1].hAskE6 : rows[i - 1].hBidE6, rows[i].piE6, SKEW_RATE_E6, MAX_SKEW_STEP_E6, MAX_SKEW_E6
            );
            (uint256 newAskPermFeeE6, uint256 newBidPermFeeE6) = up
                ? (newLeanPermFeeE6, RESTING_SPREAD_E6 - newLeanPermFeeE6)
                : (RESTING_SPREAD_E6 - newLeanPermFeeE6, newLeanPermFeeE6);
            assertGeWithinPip(newAskPermFeeE6, rows[i].hAskE6, _label(_name(rows[i]), "hAsk"));
            assertGeWithinPip(newBidPermFeeE6, rows[i].hBidE6, _label(_name(rows[i]), "hBid"));
        }
    }

    /// @notice Backrun side's g = leaning side's permanent step + (PI >= cutoff ? c * PI : 0).
    function test_s1_temporaryBackrunFee_matchesG() public view {
        Row[] memory rows = _rows();
        for (uint256 i = 1; i < rows.length; i++) {
            bool up = rows[i].price > rows[i - 1].price;
            (uint24 newLeanE6, uint24 oldLeanE6, uint256 expectedBackrunTemp) = up
                ? (rows[i].hAskE6, rows[i - 1].hAskE6, rows[i].gBidE6)
                : (rows[i].hBidE6, rows[i - 1].hBidE6, rows[i].gAskE6);
            uint256 tempFeeE6 = VolatileFeeCalculation.temporaryBackrunFee(
                newLeanE6, oldLeanE6, rows[i].piE6, BACKRUN_CAPTURE_FRACTION_E6, BACKRUN_THRESHOLD_E6
            );
            assertGeWithinPip(tempFeeE6, expectedBackrunTemp, _label(_name(rows[i]), "g backrun"));
        }
    }

    function test_s1_newPermAndTempFee_singleShot() public view {
        Row[] memory rows = _rows();
        VolatileFeeConfig memory config = _feeConfig(SKEW_RATE_E6, MAX_SKEW_STEP_E6, MAX_SKEW_E6);
        for (uint256 i = 1; i < rows.length; i++) {
            (uint256 newAskPermFeeE6, uint256 askBaselineFeeE6, uint256 bidBaselineFeeE6) =
                _newPermAndBaselines(config, rows[i - 1].hAskE6, rows[i].piE6, rows[i].price > rows[i - 1].price);
            assertGeWithinPip(newAskPermFeeE6, rows[i].hAskE6, _label(_name(rows[i]), "hAsk"));
            assertGeWithinPip(askBaselineFeeE6, rows[i].fAskE6, _label(_name(rows[i]), "fAsk"));
            assertGeWithinPip(bidBaselineFeeE6, rows[i].fBidE6, _label(_name(rows[i]), "fBid"));
        }
    }

    function test_s1_newPermAndTempFee_chainedFromPrices() public view {
        Row[] memory rows = _rows();
        VolatileFeeConfig memory config = _feeConfig(SKEW_RATE_E6, MAX_SKEW_STEP_E6, MAX_SKEW_E6);
        uint24 askPermFeeE6 = RESTING_SPREAD_E6 / 2;
        uint160 sqrtPriceTopX96 = _sqrtPriceX96(rows[0].price, PRICE_ONE);
        for (uint256 i = 1; i < rows.length; i++) {
            (uint256 piE6, bool up) =
                VolatileFeeCalculation.relativeMoveE6(_sqrtPriceX96(rows[i].price, PRICE_ONE), sqrtPriceTopX96);
            assertGeWithinPip(piE6, rows[i].piE6, _label(_name(rows[i]), "PI"));

            (uint24 newAskPermFeeE6, uint256 askBaselineFeeE6, uint256 bidBaselineFeeE6) =
                _newPermAndBaselines(config, askPermFeeE6, piE6, up);
            assertGeWithinPip(newAskPermFeeE6, rows[i].hAskE6, _label(_name(rows[i]), "hAsk"));
            assertGeWithinPip(askBaselineFeeE6, rows[i].fAskE6, _label(_name(rows[i]), "fAsk"));
            assertGeWithinPip(bidBaselineFeeE6, rows[i].fBidE6, _label(_name(rows[i]), "fBid"));

            askPermFeeE6 = newAskPermFeeE6;
            sqrtPriceTopX96 = _sqrtPriceX96(rows[i].price, PRICE_ONE);
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
                price: vm.parseUint(cols[1]),
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
