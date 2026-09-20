// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {VolatileFeeCalculation} from "../../../../src/volatile/libraries/VolatileFeeCalculation.sol";
import {VolatileVectorTestBase} from "../VolatileVectorTestBase.sol";

/// @title VolatileFeeCalculationS7Test
/// @notice Generator scenario S7, SPEC-GAP #1: the block after a quiet gap, priced as one 30 bp step from
///         the last traded block's open (reading A: nothing applied for the quiet blocks).
/// @dev The library takes PI, not block counts, so the row reduces to one top-of-block step from neutral;
///      block independence is hook behaviour. A failure here triages as a spec question, not a bug.
contract VolatileFeeCalculationS7Test is VolatileVectorTestBase {
    uint24 constant SKEW_RATE_E6 = 4_000_000;
    uint24 constant MAX_SKEW_STEP_E6 = 400;
    uint24 constant MAX_SKEW_E6 = 900;

    // PI 3000 from (450, 450): step clips to d_top -> h 850 / 50; g_bid = 400 + 0.5 * 3000 = 1900; f 850 / 1950.
    uint256 constant PI_E6 = 3000;
    uint24 constant H_ASK_E6 = 850;
    uint256 constant H_BID_E6 = 50;
    uint256 constant G_BID_E6 = 1900;
    uint256 constant F_ASK_E6 = 850;
    uint256 constant F_BID_E6 = 1950;

    function test_s7_newPermanentFee_matchesH() public pure {
        uint256 newAskPermFeeE6 = VolatileFeeCalculation.newPermanentFee(
            NEUTRAL_PERM_FEE_E6, _moveFromE6(PI_E6, true), SKEW_RATE_E6, MAX_SKEW_STEP_E6, MAX_SKEW_E6
        );
        assertGeWithinPip(newAskPermFeeE6, H_ASK_E6, "hAsk");
        assertGeWithinPip(RESTING_SPREAD_E6 - newAskPermFeeE6, H_BID_E6, "hBid");
    }

    function test_s7_temporaryBackrunFee_matchesG() public pure {
        uint256 bidTempFeeE6 = VolatileFeeCalculation.temporaryBackrunFee(
            H_ASK_E6, NEUTRAL_PERM_FEE_E6, _moveFromE6(PI_E6, true), BACKRUN_CAPTURE_FRACTION_E6, BACKRUN_THRESHOLD_E6
        );
        assertGeWithinPip(bidTempFeeE6, G_BID_E6, "gBid");
    }

    function test_s7_newPermAndTempFee_fromNeutral() public pure {
        (uint256 newAskPermFeeE6, uint256 askBaselineFeeE6, uint256 bidBaselineFeeE6) = _newPermAndBaselines(
            _feeConfig(SKEW_RATE_E6, MAX_SKEW_STEP_E6, MAX_SKEW_E6), NEUTRAL_PERM_FEE_E6, PI_E6, true
        );
        assertGeWithinPip(newAskPermFeeE6, H_ASK_E6, "hAsk");
        assertGeWithinPip(askBaselineFeeE6, F_ASK_E6, "fAsk");
        assertGeWithinPip(bidBaselineFeeE6, F_BID_E6, "fBid");
    }
}
