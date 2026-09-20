// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {VolatileFeeCalculation} from "../../../../src/volatile/libraries/VolatileFeeCalculation.sol";
import {VolatileFeeConfig} from "../../../../src/volatile/interfaces/IVolatileFeeConfiguration.sol";
import {VolatileVectorTestBase} from "../VolatileVectorTestBase.sol";

/// @title VolatileFeeCalculationS9Test
/// @notice Generator scenario S9, config edges: an odd resting spread, a skew ceiling at the neutral centre,
///         and a zero skew rate with the gate on and off; one block from neutral per case.
/// @dev Per-case config, so vectors are hardcoded. The odd-RS case splits reference and contract by design
///      (see `_cases`): its floored bid 450 sits below the contract's neutral bid 451, so the temporary-fee
///      test takes the new leaning fee from newPermanentFee, not the vector, or the restitution term would
///      underflow.
contract VolatileFeeCalculationS9Test is VolatileVectorTestBase {
    struct Case {
        string name;
        uint24 restingSpreadE6;
        uint24 skewRateE6;
        uint24 maxSkewStepE6;
        uint24 maxSkewE6;
        uint24 backrunThresholdE6;
        uint24 backrunCaptureFractionE6;
        uint256 piE6;
        uint256 hAskE6;
        uint256 hBidE6;
        uint256 gAskE6;
        uint256 gBidE6;
        uint256 fAskE6;
        uint256 fBidE6;
    }

    function test_s9_newPermanentFee_matchesH() public pure {
        Case[] memory cases = _cases();
        for (uint256 i = 0; i < cases.length; i++) {
            bool up = cases[i].piE6 > 0;
            uint256 newLeanPermFeeE6 = VolatileFeeCalculation.newPermanentFee(
                up ? _neutralAskE6(cases[i]) : _neutralBidE6(cases[i]),
                _moveFromE6(cases[i].piE6, up),
                cases[i].skewRateE6,
                cases[i].maxSkewStepE6,
                cases[i].maxSkewE6
            );
            (uint256 newAskPermFeeE6, uint256 newBidPermFeeE6) = up
                ? (newLeanPermFeeE6, cases[i].restingSpreadE6 - newLeanPermFeeE6)
                : (cases[i].restingSpreadE6 - newLeanPermFeeE6, newLeanPermFeeE6);
            assertGeWithinPip(newAskPermFeeE6, cases[i].hAskE6, _label(cases[i].name, "hAsk"));
            assertGeWithinPip(newBidPermFeeE6, cases[i].hBidE6, _label(cases[i].name, "hBid"));
        }
    }

    function test_s9_temporaryBackrunFee_matchesG() public pure {
        Case[] memory cases = _cases();
        for (uint256 i = 0; i < cases.length; i++) {
            bool up = cases[i].piE6 > 0;
            uint24 oldLeanPermFeeE6 = up ? _neutralAskE6(cases[i]) : _neutralBidE6(cases[i]);
            uint24 newLeanPermFeeE6 = VolatileFeeCalculation.newPermanentFee(
                oldLeanPermFeeE6,
                _moveFromE6(cases[i].piE6, up),
                cases[i].skewRateE6,
                cases[i].maxSkewStepE6,
                cases[i].maxSkewE6
            );
            uint256 tempFeeE6 = VolatileFeeCalculation.temporaryBackrunFee(
                newLeanPermFeeE6,
                oldLeanPermFeeE6,
                _moveFromE6(cases[i].piE6, up),
                cases[i].backrunCaptureFractionE6,
                cases[i].backrunThresholdE6
            );
            assertGeWithinPip(tempFeeE6, up ? cases[i].gBidE6 : cases[i].gAskE6, _label(cases[i].name, "g backrun"));
        }
    }

    function test_s9_newPermAndTempFee_fromNeutral() public pure {
        Case[] memory cases = _cases();
        for (uint256 i = 0; i < cases.length; i++) {
            VolatileFeeConfig memory config;
            config.restingSpreadE6 = cases[i].restingSpreadE6;
            config.skewRateE6 = cases[i].skewRateE6;
            config.maxSkewStepE6 = cases[i].maxSkewStepE6;
            config.maxSkewE6 = cases[i].maxSkewE6;
            config.backrunThresholdE6 = cases[i].backrunThresholdE6;
            config.backrunCaptureFractionE6 = cases[i].backrunCaptureFractionE6;
            (uint256 newAskPermFeeE6, uint256 askBaselineFeeE6, uint256 bidBaselineFeeE6) =
                _newPermAndBaselines(config, _neutralAskE6(cases[i]), cases[i].piE6, cases[i].piE6 > 0);
            assertGeWithinPip(newAskPermFeeE6, cases[i].hAskE6, _label(cases[i].name, "hAsk"));
            assertGeWithinPip(askBaselineFeeE6, cases[i].fAskE6, _label(cases[i].name, "fAsk"));
            assertGeWithinPip(bidBaselineFeeE6, cases[i].fBidE6, _label(cases[i].name, "fBid"));
        }
    }

    function _neutralAskE6(Case memory c) internal pure returns (uint24) {
        return c.restingSpreadE6 / 2;
    }

    function _neutralBidE6(Case memory c) internal pure returns (uint24) {
        return c.restingSpreadE6 - c.restingSpreadE6 / 2;
    }

    function _cases() internal pure returns (Case[] memory cases) {
        cases = new Case[](4);
        // Odd RS: true math 450.5 / 450.5, contract 450 / 451, reference floored to 450 / 450; bid lands one pip over.
        cases[0] = Case({
            name: "odd RS, neutral",
            restingSpreadE6: 901,
            skewRateE6: 1_000_000,
            maxSkewStepE6: 300,
            maxSkewE6: 901,
            backrunThresholdE6: 1000,
            backrunCaptureFractionE6: 500_000,
            piE6: 0,
            hAskE6: 450,
            hBidE6: 450,
            gAskE6: 0,
            gBidE6: 0,
            fAskE6: 450,
            fBidE6: 450
        });
        // h_max = RS/2 is the validator's minimum and leaves a zero-width band, so it also forces d_top = 0:
        // skew frozen, capture only.
        cases[1] = Case({
            name: "h_max = RS/2",
            restingSpreadE6: 900,
            skewRateE6: 4_000_000,
            maxSkewStepE6: 0,
            maxSkewE6: 450,
            backrunThresholdE6: 1000,
            backrunCaptureFractionE6: 500_000,
            piE6: 2000,
            hAskE6: 450,
            hBidE6: 450,
            gAskE6: 0,
            gBidE6: 1000,
            fAskE6: 450,
            fBidE6: 1450
        });
        cases[2] = Case({
            name: "alpha_top = 0, PI >= cutoff",
            restingSpreadE6: 900,
            skewRateE6: 0,
            maxSkewStepE6: 400,
            maxSkewE6: 900,
            backrunThresholdE6: 1000,
            backrunCaptureFractionE6: 500_000,
            piE6: 2000,
            hAskE6: 450,
            hBidE6: 450,
            gAskE6: 0,
            gBidE6: 1000,
            fAskE6: 450,
            fBidE6: 1450
        });
        cases[3] = Case({
            name: "alpha_top = 0, PI < cutoff",
            restingSpreadE6: 900,
            skewRateE6: 0,
            maxSkewStepE6: 400,
            maxSkewE6: 900,
            backrunThresholdE6: 1000,
            backrunCaptureFractionE6: 500_000,
            piE6: 900,
            hAskE6: 450,
            hBidE6: 450,
            gAskE6: 0,
            gBidE6: 0,
            fAskE6: 450,
            fBidE6: 450
        });
    }
}
