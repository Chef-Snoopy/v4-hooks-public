// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {
    VolatileFeeConfig,
    VolatileFeeState,
    IVolatileFeeConfiguration
} from "../../src/volatile/interfaces/IVolatileFeeConfiguration.sol";
import {VolatileFeeCalculation} from "../../src/volatile/libraries/VolatileFeeCalculation.sol";
import {IDynamicFeeHook} from "../../src/interfaces/IDynamicFeeHook.sol";
import {VolatilePairTestBase} from "./base/VolatilePairTestBase.sol";
import {VolatileFeeConfigurationImplementation} from "./base/VolatileFeeConfigurationImplementation.sol";

/// The role and PoolNotInitialized reverts deliberately overlap `VolatilePairHook.t.sol`, which owns the cases needing a
/// real pool.
contract VolatileFeeConfigurationImplementationTest is VolatilePairTestBase {
    using PoolIdLibrary for PoolKey;

    event FeeConfigUpdated(PoolId indexed poolId, VolatileFeeConfig feeConfig);

    uint24 internal constant ONE_E6 = uint24(VolatileFeeCalculation.ONE_E6);

    /// Must differ from `_defaultConfig`'s 900: reverted updates are checked against it.
    uint24 internal constant SEED_RESTING_SPREAD_E6 = 300;

    VolatileFeeConfigurationImplementation internal feeConfigurationImplementation;

    PoolId internal testPoolId;
    PoolId internal secondPoolId = PoolId.wrap(keccak256("second pool"));

    function setUp() public override {
        feeConfigurationImplementation = new VolatileFeeConfigurationImplementation(configManager);

        testPoolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(feeConfigurationImplementation))
        });
        testPoolId = testPoolKey.toId();

        feeConfigurationImplementation.initializeFeeConfig(testPoolId, _seedParams());
        feeConfigurationImplementation.initializeFeeConfig(secondPoolId, _seedParams());
    }

    // -------------------------------------------------------------------------
    // Validator: eight rejection branches, checked in a fixed order; one hand-written test at each boundary
    // -------------------------------------------------------------------------

    function test_updateFeeConfig_revertsWithRestingSpreadCannotBeZero() public {
        VolatileFeeConfig memory params = _defaultConfig();
        params.restingSpreadE6 = 0;
        params.maxSkewE6 = 0;

        vm.prank(configManager);
        vm.expectRevert(IVolatileFeeConfiguration.RestingSpreadCannotBeZero.selector);
        feeConfigurationImplementation.updateFeeConfig(testPoolId, params);
    }

    function test_updateFeeConfig_revertsWithMaxSkewTooLarge() public {
        VolatileFeeConfig memory params = _defaultConfig();
        params.maxSkewE6 = RESTING_SPREAD_E6 + 1;

        vm.prank(configManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVolatileFeeConfiguration.MaxSkewTooLarge.selector, RESTING_SPREAD_E6 + 1, RESTING_SPREAD_E6
            )
        );
        feeConfigurationImplementation.updateFeeConfig(testPoolId, params);
    }

    function test_updateFeeConfig_acceptsMaxSkewEqualToRestingSpread() public {
        VolatileFeeConfig memory params = _defaultConfig();
        params.maxSkewE6 = RESTING_SPREAD_E6;

        vm.prank(configManager);
        feeConfigurationImplementation.updateFeeConfig(testPoolId, params);

        (,,,,,, uint24 maxSkewE6,,,) = feeConfigurationImplementation.feeConfig(testPoolId);
        assertEq(maxSkewE6, RESTING_SPREAD_E6);
    }

    function test_updateFeeConfig_revertsWithMaxSkewTooSmall() public {
        VolatileFeeConfig memory params = _defaultConfig();
        params.maxSkewE6 = NEUTRAL_FEE_E6 - 1; // 449: 2 * 449 = 898 < 900

        vm.prank(configManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVolatileFeeConfiguration.MaxSkewTooSmall.selector, NEUTRAL_FEE_E6 - 1, RESTING_SPREAD_E6
            )
        );
        feeConfigurationImplementation.updateFeeConfig(testPoolId, params);
    }

    function test_updateFeeConfig_acceptsMaxSkewAtNeutralCenter() public {
        VolatileFeeConfig memory params = _defaultConfig();
        params.maxSkewE6 = NEUTRAL_FEE_E6; // 450: 2 * 450 == 900
        params.maxSkewStepE6 = 0; // default step of 300 causes MaxSkewStepTooLarge revert

        vm.prank(configManager);
        feeConfigurationImplementation.updateFeeConfig(testPoolId, params);

        _assertConfigEq(testPoolId, params);
    }

    function test_updateFeeConfig_revertsWithBackrunCaptureFractionTooLarge() public {
        VolatileFeeConfig memory params = _defaultConfig();
        params.backrunCaptureFractionE6 = ONE_E6 + 1;

        vm.prank(configManager);
        vm.expectRevert(
            abi.encodeWithSelector(IVolatileFeeConfiguration.BackrunCaptureFractionTooLarge.selector, ONE_E6 + 1)
        );
        feeConfigurationImplementation.updateFeeConfig(testPoolId, params);
    }

    function test_updateFeeConfig_acceptsBackrunCaptureAtOne() public {
        VolatileFeeConfig memory params = _defaultConfig();
        params.backrunCaptureFractionE6 = ONE_E6;

        vm.prank(configManager);
        feeConfigurationImplementation.updateFeeConfig(testPoolId, params);

        (, uint24 backrunCaptureFractionE6,,,,,,,,) = feeConfigurationImplementation.feeConfig(testPoolId);
        assertEq(backrunCaptureFractionE6, ONE_E6);
    }

    function test_updateFeeConfig_revertsWithRestoreFractionTooLarge() public {
        VolatileFeeConfig memory params = _defaultConfig();
        params.restoreFractionE6 = ONE_E6 + 1;

        vm.prank(configManager);
        vm.expectRevert(abi.encodeWithSelector(IVolatileFeeConfiguration.InvalidRestoreFraction.selector, ONE_E6 + 1));
        feeConfigurationImplementation.updateFeeConfig(testPoolId, params);
    }

    /// Pins `_boundFeeConfig`, which every volatile suite draws valid configs from, to the validator.
    function test_fuzz_updateFeeConfig_storesGeneratedConfig(ConfigSeed memory seed) public {
        VolatileFeeConfig memory params = _boundFeeConfig(seed);

        vm.prank(configManager);
        feeConfigurationImplementation.updateFeeConfig(testPoolId, params);

        _assertConfigEq(testPoolId, params);
    }

    function test_fuzz_updateFeeConfig_rejectsZeroRestingSpread(ConfigSeed memory seed) public {
        VolatileFeeConfig memory params = _boundFeeConfig(seed);
        params.restingSpreadE6 = 0;

        vm.prank(configManager);
        vm.expectRevert(IVolatileFeeConfiguration.RestingSpreadCannotBeZero.selector);
        feeConfigurationImplementation.updateFeeConfig(testPoolId, params);

        _assertConfigEq(testPoolId, _seedParams());
    }

    function test_fuzz_updateFeeConfig_rejectsMaxSkewAboveRestingSpread(ConfigSeed memory seed, uint24 maxSkewSeed)
        public
    {
        VolatileFeeConfig memory params = _boundFeeConfig(seed);
        params.maxSkewE6 = uint24(bound(maxSkewSeed, uint256(params.restingSpreadE6) + 1, type(uint24).max));

        vm.prank(configManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVolatileFeeConfiguration.MaxSkewTooLarge.selector, params.maxSkewE6, params.restingSpreadE6
            )
        );
        feeConfigurationImplementation.updateFeeConfig(testPoolId, params);

        _assertConfigEq(testPoolId, _seedParams());
    }

    function test_fuzz_updateFeeConfig_rejectsMaxSkewBelowNeutralCenter(ConfigSeed memory seed, uint24 maxSkewSeed)
        public
    {
        VolatileFeeConfig memory params = _boundFeeConfig(seed);
        // (RS - 1) / 2 is the largest ceiling with 2 * maxSkew < RS
        params.maxSkewE6 = uint24(bound(maxSkewSeed, 0, (uint256(params.restingSpreadE6) - 1) / 2));

        vm.prank(configManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVolatileFeeConfiguration.MaxSkewTooSmall.selector, params.maxSkewE6, params.restingSpreadE6
            )
        );
        feeConfigurationImplementation.updateFeeConfig(testPoolId, params);

        _assertConfigEq(testPoolId, _seedParams());
    }

    function test_fuzz_updateFeeConfig_rejectsBackrunCaptureAboveOne(ConfigSeed memory seed, uint24 captureSeed)
        public
    {
        VolatileFeeConfig memory params = _boundFeeConfig(seed);
        params.backrunCaptureFractionE6 = uint24(bound(captureSeed, uint256(ONE_E6) + 1, type(uint24).max));

        vm.prank(configManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVolatileFeeConfiguration.BackrunCaptureFractionTooLarge.selector, params.backrunCaptureFractionE6
            )
        );
        feeConfigurationImplementation.updateFeeConfig(testPoolId, params);

        _assertConfigEq(testPoolId, _seedParams());
    }

    /// restingSpreadE6 == 0 is the PoolNotInitialized sentinel; sound only because every write rejects a zero pie.
    function test_fuzz_sentinel_hasNoFalseNegative(ConfigSeed memory seed) public {
        VolatileFeeConfig memory params = _boundFeeConfig(seed);
        PoolId fresh = PoolId.wrap(keccak256(abi.encode("fresh pool", params.restingSpreadE6, params.maxSkewE6)));

        vm.prank(configManager);
        vm.expectRevert(abi.encodeWithSelector(IDynamicFeeHook.PoolNotInitialized.selector, fresh));
        feeConfigurationImplementation.updateFeeConfig(fresh, params);

        feeConfigurationImplementation.initializeFeeConfig(fresh, params);

        (uint24 storedRestingSpreadE6,,,,,,,,,) = feeConfigurationImplementation.feeConfig(fresh);
        assertTrue(storedRestingSpreadE6 != 0);
        vm.prank(configManager);
        feeConfigurationImplementation.updateFeeConfig(fresh, params);
    }

    // -------------------------------------------------------------------------
    // Validator: ceilings on restingSpreadE6, maxSkewE6, maxSkewStepE6 and maxMidFadeE6
    // -------------------------------------------------------------------------

    function test_updateFeeConfig_acceptsRestingSpreadAtTwiceMaxHookFee() public {
        VolatileFeeConfig memory params = _defaultConfig();
        params.restingSpreadE6 = MAX_RESTING_SPREAD_E6;
        params.maxSkewE6 = MAX_HOOK_FEE_E6;
        params.maxSkewStepE6 = 0; // default step of 300 causes MaxSkewStepTooLarge revert

        vm.prank(configManager);
        feeConfigurationImplementation.updateFeeConfig(testPoolId, params);

        _assertConfigEq(testPoolId, params);
    }

    /// The default maxSkew also fails MaxSkewTooSmall against this rs; the check order fixes the error.
    function test_updateFeeConfig_revertsWithRestingSpreadTooLarge() public {
        VolatileFeeConfig memory params = _defaultConfig();
        params.restingSpreadE6 = MAX_RESTING_SPREAD_E6 + 1;

        vm.prank(configManager);
        vm.expectRevert(
            abi.encodeWithSelector(IVolatileFeeConfiguration.RestingSpreadTooLarge.selector, MAX_RESTING_SPREAD_E6 + 1)
        );
        feeConfigurationImplementation.updateFeeConfig(testPoolId, params);
    }

    /// Reachable only with rs > MAX_HOOK_FEE_E6; below that MaxSkewTooLarge fires first.
    function test_updateFeeConfig_revertsWithMaxSkewAboveMaxHookFee() public {
        VolatileFeeConfig memory params = _defaultConfig();
        params.restingSpreadE6 = MAX_HOOK_FEE_E6 + 1;
        params.maxSkewE6 = MAX_HOOK_FEE_E6 + 1;

        vm.prank(configManager);
        vm.expectRevert(
            abi.encodeWithSelector(IVolatileFeeConfiguration.MaxSkewAboveMaxHookFee.selector, MAX_HOOK_FEE_E6 + 1)
        );
        feeConfigurationImplementation.updateFeeConfig(testPoolId, params);
    }

    /// Two widths: the default 900 catches a band computed as maxSkew - rs / 2 (450); the odd pie's 1 catches
    /// 2 * (maxSkew - rs / 2) (2).
    function test_updateFeeConfig_acceptsMaxSkewStepEqualToBand() public {
        uint24 bandE6 = 2 * MAX_SKEW_E6 - RESTING_SPREAD_E6; // 2 * 900 - 900 == 900
        VolatileFeeConfig memory atBand = _defaultConfig();
        atBand.maxSkewStepE6 = bandE6;

        vm.prank(configManager);
        feeConfigurationImplementation.updateFeeConfig(testPoolId, atBand);
        _assertConfigEq(testPoolId, atBand);

        uint24 oddRsE6 = RESTING_SPREAD_E6 + 1; // 901
        uint24 oddMaxSkewE6 = (oddRsE6 + 1) / 2; // ceil(901 / 2) == 451; band 2 * 451 - 901 == 1
        VolatileFeeConfig memory oddBand = _configWithRestingSpread(oddRsE6);
        oddBand.maxSkewE6 = oddMaxSkewE6;
        oddBand.maxSkewStepE6 = 1;

        vm.prank(configManager);
        feeConfigurationImplementation.updateFeeConfig(testPoolId, oddBand);
        _assertConfigEq(testPoolId, oddBand);
    }

    function test_updateFeeConfig_revertsWithMaxSkewStepTooLarge() public {
        uint24 bandE6 = 2 * MAX_SKEW_E6 - RESTING_SPREAD_E6; // 900
        VolatileFeeConfig memory overBand = _defaultConfig();
        overBand.maxSkewStepE6 = bandE6 + 1;

        vm.prank(configManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVolatileFeeConfiguration.MaxSkewStepTooLarge.selector, bandE6 + 1, MAX_SKEW_E6, RESTING_SPREAD_E6
            )
        );
        feeConfigurationImplementation.updateFeeConfig(testPoolId, overBand);

        uint24 oddRsE6 = RESTING_SPREAD_E6 + 1; // 901
        uint24 oddMaxSkewE6 = (oddRsE6 + 1) / 2; // 451; band 1
        VolatileFeeConfig memory oddBandOverStep = _configWithRestingSpread(oddRsE6);
        oddBandOverStep.maxSkewE6 = oddMaxSkewE6;
        oddBandOverStep.maxSkewStepE6 = 2;

        vm.prank(configManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVolatileFeeConfiguration.MaxSkewStepTooLarge.selector, uint24(2), oddMaxSkewE6, oddRsE6
            )
        );
        feeConfigurationImplementation.updateFeeConfig(testPoolId, oddBandOverStep);
    }

    function test_updateFeeConfig_acceptsMaxMidFadeAtMaxHookFee() public {
        VolatileFeeConfig memory params = _defaultConfig();
        params.maxMidFadeE6 = MAX_HOOK_FEE_E6;

        vm.prank(configManager);
        feeConfigurationImplementation.updateFeeConfig(testPoolId, params);
        _assertConfigEq(testPoolId, params);
    }

    function test_updateFeeConfig_revertsWithMaxMidFadeTooLarge() public {
        VolatileFeeConfig memory params = _defaultConfig();
        params.maxMidFadeE6 = MAX_HOOK_FEE_E6 + 1;

        vm.prank(configManager);
        vm.expectRevert(
            abi.encodeWithSelector(IVolatileFeeConfiguration.MaxMidFadeTooLarge.selector, MAX_HOOK_FEE_E6 + 1)
        );
        feeConfigurationImplementation.updateFeeConfig(testPoolId, params);
    }

    function test_fuzz_updateFeeConfig_rejectsRestingSpreadAboveTwiceMaxHookFee(ConfigSeed memory seed, uint24 rsSeed)
        public
    {
        VolatileFeeConfig memory params = _boundFeeConfig(seed);
        params.restingSpreadE6 = uint24(bound(rsSeed, uint256(MAX_RESTING_SPREAD_E6) + 1, type(uint24).max));

        vm.prank(configManager);
        vm.expectRevert(
            abi.encodeWithSelector(IVolatileFeeConfiguration.RestingSpreadTooLarge.selector, params.restingSpreadE6)
        );
        feeConfigurationImplementation.updateFeeConfig(testPoolId, params);

        _assertConfigEq(testPoolId, _seedParams());
    }

    function test_fuzz_updateFeeConfig_rejectsMaxSkewAboveMaxHookFee(
        ConfigSeed memory seed,
        uint24 rsSeed,
        uint24 maxSkewSeed
    ) public {
        VolatileFeeConfig memory params = _boundFeeConfig(seed);
        params.restingSpreadE6 = uint24(bound(rsSeed, uint256(MAX_HOOK_FEE_E6) + 1, MAX_RESTING_SPREAD_E6));
        // maxSkew <= rs and 2 * maxSkew > rs hold, so this is the first check to fire
        params.maxSkewE6 = uint24(bound(maxSkewSeed, uint256(MAX_HOOK_FEE_E6) + 1, params.restingSpreadE6));

        vm.prank(configManager);
        vm.expectRevert(
            abi.encodeWithSelector(IVolatileFeeConfiguration.MaxSkewAboveMaxHookFee.selector, params.maxSkewE6)
        );
        feeConfigurationImplementation.updateFeeConfig(testPoolId, params);

        _assertConfigEq(testPoolId, _seedParams());
    }

    function test_fuzz_updateFeeConfig_rejectsMaxSkewStepAboveBand(ConfigSeed memory seed, uint24 stepSeed) public {
        VolatileFeeConfig memory params = _boundFeeConfig(seed);
        uint256 bandE6 = 2 * uint256(params.maxSkewE6) - params.restingSpreadE6;
        params.maxSkewStepE6 = uint24(bandE6 + bound(stepSeed, 1, type(uint24).max - bandE6));

        vm.prank(configManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVolatileFeeConfiguration.MaxSkewStepTooLarge.selector,
                params.maxSkewStepE6,
                params.maxSkewE6,
                params.restingSpreadE6
            )
        );
        feeConfigurationImplementation.updateFeeConfig(testPoolId, params);

        _assertConfigEq(testPoolId, _seedParams());
    }

    function test_fuzz_updateFeeConfig_rejectsMaxMidFadeAboveMaxHookFee(ConfigSeed memory seed, uint24 maxMidFadeSeed)
        public
    {
        VolatileFeeConfig memory params = _boundFeeConfig(seed);
        params.maxMidFadeE6 = uint24(bound(maxMidFadeSeed, uint256(MAX_HOOK_FEE_E6) + 1, type(uint24).max));

        vm.prank(configManager);
        vm.expectRevert(
            abi.encodeWithSelector(IVolatileFeeConfiguration.MaxMidFadeTooLarge.selector, params.maxMidFadeE6)
        );
        feeConfigurationImplementation.updateFeeConfig(testPoolId, params);

        _assertConfigEq(testPoolId, _seedParams());
    }

    function test_fuzz_updateFeeConfig_rejectsRestoreFractionAboveOne(ConfigSeed memory seed, uint24 fractionSeed)
        public
    {
        VolatileFeeConfig memory params = _boundFeeConfig(seed);
        params.restoreFractionE6 = uint24(bound(fractionSeed, uint256(ONE_E6) + 1, type(uint24).max));

        vm.prank(configManager);
        vm.expectRevert(
            abi.encodeWithSelector(IVolatileFeeConfiguration.InvalidRestoreFraction.selector, params.restoreFractionE6)
        );
        feeConfigurationImplementation.updateFeeConfig(testPoolId, params);

        _assertConfigEq(testPoolId, _seedParams());
    }

    /// Draws each validated field from [0, one past its largest accepted value]: every rejection stays reachable and
    /// the store branch runs on roughly 6% of draws.
    function test_fuzz_updateFeeConfig_storesWithinBoundsOrRevertsWithValidatorError(VolatileFeeConfig memory raw)
        public
    {
        raw.restingSpreadE6 = uint24(bound(raw.restingSpreadE6, 0, uint256(MAX_RESTING_SPREAD_E6) + 1));
        raw.backrunCaptureFractionE6 = uint24(bound(raw.backrunCaptureFractionE6, 0, uint256(ONE_E6) + 1));
        raw.maxSkewE6 = uint24(bound(raw.maxSkewE6, 0, uint256(MAX_HOOK_FEE_E6) + 1));
        // the widest band is MAX_HOOK_FEE_E6, at rs = maxSkew = MAX_HOOK_FEE_E6
        raw.maxSkewStepE6 = uint24(bound(raw.maxSkewStepE6, 0, uint256(MAX_HOOK_FEE_E6) + 1));
        raw.maxMidFadeE6 = uint24(bound(raw.maxMidFadeE6, 0, uint256(MAX_HOOK_FEE_E6) + 1));
        raw.restoreFractionE6 = uint24(bound(raw.restoreFractionE6, 0, uint256(ONE_E6) + 1));

        vm.prank(configManager);
        (bool success, bytes memory returndata) = address(feeConfigurationImplementation)
            .call(abi.encodeCall(feeConfigurationImplementation.updateFeeConfig, (testPoolId, raw)));

        if (success) {
            _assertConfigEq(testPoolId, raw);

            (
                uint24 storedRestingSpreadE6,
                uint24 storedCaptureE6,,
                uint24 storedMaxMidFadeE6,,
                uint24 storedMaxSkewStepE6,
                uint24 storedMaxSkewE6,,
                uint24 storedRestoreFractionE6,
            ) = feeConfigurationImplementation.feeConfig(testPoolId);
            assertTrue(storedRestingSpreadE6 != 0);
            assertLe(storedRestingSpreadE6, MAX_RESTING_SPREAD_E6);
            assertLe(storedCaptureE6, ONE_E6);
            assertLe(storedMaxSkewE6, storedRestingSpreadE6);
            assertGe(2 * uint256(storedMaxSkewE6), storedRestingSpreadE6);
            assertLe(storedMaxSkewE6, MAX_HOOK_FEE_E6);
            assertLe(storedMaxSkewStepE6, 2 * uint256(storedMaxSkewE6) - storedRestingSpreadE6);
            assertLe(storedMaxMidFadeE6, MAX_HOOK_FEE_E6);
            assertLe(storedRestoreFractionE6, ONE_E6);
        } else {
            bytes4 selector = bytes4(returndata);
            assertTrue(
                selector == IVolatileFeeConfiguration.RestingSpreadCannotBeZero.selector
                    || selector == IVolatileFeeConfiguration.RestingSpreadTooLarge.selector
                    || selector == IVolatileFeeConfiguration.BackrunCaptureFractionTooLarge.selector
                    || selector == IVolatileFeeConfiguration.MaxSkewTooLarge.selector
                    || selector == IVolatileFeeConfiguration.MaxSkewTooSmall.selector
                    || selector == IVolatileFeeConfiguration.MaxSkewAboveMaxHookFee.selector
                    || selector == IVolatileFeeConfiguration.MaxSkewStepTooLarge.selector
                    || selector == IVolatileFeeConfiguration.MaxMidFadeTooLarge.selector
                    || selector == IVolatileFeeConfiguration.InvalidRestoreFraction.selector,
                "unexpected revert selector"
            );
            _assertConfigEq(testPoolId, _seedParams());
        }
    }

    // -------------------------------------------------------------------------
    // updateFeeConfig
    // -------------------------------------------------------------------------

    function test_updateFeeConfig_revertsForUninitializedPool() public {
        PoolId unknown = PoolId.wrap(keccak256("never initialized"));

        vm.prank(configManager);
        vm.expectRevert(abi.encodeWithSelector(IDynamicFeeHook.PoolNotInitialized.selector, unknown));
        feeConfigurationImplementation.updateFeeConfig(unknown, _defaultConfig());
    }

    function test_updateFeeConfig_revertsWithNotConfigManager() public {
        bytes32 role = feeConfigurationImplementation.CONFIG_MANAGER_ROLE();

        vm.prank(address(this));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), role)
        );
        feeConfigurationImplementation.updateFeeConfig(testPoolId, _defaultConfig());
    }

    function test_updateFeeConfig_succeeds() public {
        _assertConfigEq(testPoolId, _seedParams());

        VolatileFeeConfig memory params = _defaultConfig();

        vm.expectEmit(true, false, false, true);
        emit FeeConfigUpdated(testPoolId, params);
        vm.prank(configManager);
        feeConfigurationImplementation.updateFeeConfig(testPoolId, params);

        _assertConfigEq(testPoolId, params);
        _assertStateIsNeutral(testPoolId, RESTING_SPREAD_E6);
    }

    function test_updateFeeConfig_resetsStateWithExistingSwapHistory() public {
        VolatileFeeState memory dirty;
        dirty.blockNumber = 12_345; // nonzero, so the reset to 0 is observable
        dirty.sqrtPriceTopX96 = uint160(2 ** 96 + 1000);
        dirty.askPermFeeE6 = SEED_RESTING_SPREAD_E6;
        dirty.tempFeeE6 = 750;
        dirty.tempOnBid = true;
        feeConfigurationImplementation.setFeeState(testPoolId, dirty);

        (uint40 blockNumber, uint160 sqrtPriceTopX96, uint24 askPermFeeE6, uint24 tempFeeE6, bool tempOnBid) =
            feeConfigurationImplementation.feeState(testPoolId);
        assertEq(sqrtPriceTopX96, uint160(2 ** 96 + 1000));
        assertEq(askPermFeeE6, SEED_RESTING_SPREAD_E6);
        assertEq(tempFeeE6, 750);
        assertTrue(tempOnBid);
        assertEq(blockNumber, 12_345);

        _advanceBlocks(100);
        vm.prank(configManager);
        feeConfigurationImplementation.updateFeeConfig(testPoolId, _defaultConfig());

        _assertStateIsNeutral(testPoolId, RESTING_SPREAD_E6);
    }

    function test_updateFeeConfig_oddRestingSpreadPutsSparePipOnBid() public {
        VolatileFeeConfig memory params = _configWithRestingSpread(RESTING_SPREAD_E6 + 1); // 901

        vm.prank(configManager);
        feeConfigurationImplementation.updateFeeConfig(testPoolId, params);

        (,, uint24 askPermFeeE6,,) = feeConfigurationImplementation.feeState(testPoolId);
        uint24 bidPermFeeE6 = params.restingSpreadE6 - askPermFeeE6; // feeState NatSpec: bid perm = RS - askPerm
        assertEq(bidPermFeeE6 - askPermFeeE6, params.restingSpreadE6 % 2);
    }

    function test_updateFeeConfig_gas() public {
        vm.prank(configManager);
        feeConfigurationImplementation.updateFeeConfig(testPoolId, _defaultConfig());
        vm.snapshotGasLastCall("updateFeeConfig");
    }

    // -------------------------------------------------------------------------
    // batchUpdateFeeConfig
    // -------------------------------------------------------------------------

    function test_batchUpdateFeeConfig_revertsWithLengthMismatch() public {
        (PoolId[] memory poolIds, VolatileFeeConfig[] memory feeConfigs) = _batchOfTwo();
        PoolId[] memory shortPoolIds = new PoolId[](1);
        shortPoolIds[0] = poolIds[0];

        vm.prank(configManager);
        vm.expectRevert(IVolatileFeeConfiguration.LengthMismatch.selector);
        feeConfigurationImplementation.batchUpdateFeeConfig(shortPoolIds, feeConfigs);
    }

    function test_batchUpdateFeeConfig_revertsWithNotConfigManager() public {
        (PoolId[] memory poolIds, VolatileFeeConfig[] memory feeConfigs) = _batchOfTwo();
        bytes32 role = feeConfigurationImplementation.CONFIG_MANAGER_ROLE();

        vm.prank(address(this));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), role)
        );
        feeConfigurationImplementation.batchUpdateFeeConfig(poolIds, feeConfigs);
    }

    function test_batchUpdateFeeConfig_revertsForUninitializedPool() public {
        PoolId unknown = PoolId.wrap(keccak256("never initialized"));
        (PoolId[] memory poolIds, VolatileFeeConfig[] memory feeConfigs) = _batchOfTwo();
        poolIds[1] = unknown;

        vm.prank(configManager);
        vm.expectRevert(abi.encodeWithSelector(IDynamicFeeHook.PoolNotInitialized.selector, unknown));
        feeConfigurationImplementation.batchUpdateFeeConfig(poolIds, feeConfigs);

        _assertConfigEq(poolIds[0], _seedParams());
    }

    function test_batchUpdateFeeConfig_revertsWhenOneConfigInvalid() public {
        (PoolId[] memory poolIds, VolatileFeeConfig[] memory feeConfigs) = _batchOfTwo();
        feeConfigs[1].maxSkewE6 = feeConfigs[1].restingSpreadE6 + 1;

        vm.prank(configManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVolatileFeeConfiguration.MaxSkewTooLarge.selector,
                feeConfigs[1].maxSkewE6,
                feeConfigs[1].restingSpreadE6
            )
        );
        feeConfigurationImplementation.batchUpdateFeeConfig(poolIds, feeConfigs);

        _assertConfigEq(poolIds[0], _seedParams());
        _assertConfigEq(poolIds[1], _seedParams());
    }

    function test_batchUpdateFeeConfig_succeeds() public {
        (PoolId[] memory poolIds, VolatileFeeConfig[] memory feeConfigs) = _batchOfTwo();

        vm.expectEmit(true, false, false, true);
        emit FeeConfigUpdated(poolIds[0], feeConfigs[0]);
        vm.expectEmit(true, false, false, true);
        emit FeeConfigUpdated(poolIds[1], feeConfigs[1]);
        vm.prank(configManager);
        feeConfigurationImplementation.batchUpdateFeeConfig(poolIds, feeConfigs);

        for (uint256 i = 0; i < poolIds.length; i++) {
            _assertConfigEq(poolIds[i], feeConfigs[i]);
            _assertStateIsNeutral(poolIds[i], feeConfigs[i].restingSpreadE6);
        }
    }

    function test_batchUpdateFeeConfig_emptyArraysSucceeds() public {
        vm.prank(configManager);
        feeConfigurationImplementation.batchUpdateFeeConfig(new PoolId[](0), new VolatileFeeConfig[](0));
    }

    function test_batchUpdateFeeConfig_gas() public {
        (PoolId[] memory poolIds, VolatileFeeConfig[] memory feeConfigs) = _batchOfTwo();

        vm.prank(configManager);
        feeConfigurationImplementation.batchUpdateFeeConfig(poolIds, feeConfigs);
        vm.snapshotGasLastCall("batchUpdateFeeConfig");
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _seedParams() internal pure returns (VolatileFeeConfig memory) {
        return _configWithRestingSpread(SEED_RESTING_SPREAD_E6);
    }

    function _batchOfTwo() internal view returns (PoolId[] memory poolIds, VolatileFeeConfig[] memory feeConfigs) {
        poolIds = new PoolId[](2);
        poolIds[0] = testPoolId;
        poolIds[1] = secondPoolId;

        feeConfigs = new VolatileFeeConfig[](2);
        feeConfigs[0] = _defaultConfig();
        feeConfigs[1] = _configWithRestingSpread(RESTING_SPREAD_E6 * 2);
        feeConfigs[1].backrunCaptureFractionE6 = BACKRUN_CAPTURE_FRACTION_E6 / 2;
    }

    function _assertConfigEq(PoolId poolId, VolatileFeeConfig memory expected) internal view {
        (, bytes memory data) = address(feeConfigurationImplementation)
            .staticcall(abi.encodeCall(feeConfigurationImplementation.feeConfig, (poolId)));
        VolatileFeeConfig memory stored = abi.decode(data, (VolatileFeeConfig));
        assertEq(keccak256(abi.encode(stored)), keccak256(abi.encode(expected)), "config");
    }

    function _assertStateIsNeutral(PoolId poolId, uint24 restingSpreadE6) internal view {
        (uint40 blockNumber, uint160 sqrtPriceTopX96, uint24 askPermFeeE6, uint24 tempFeeE6, bool tempOnBid) =
            feeConfigurationImplementation.feeState(poolId);
        assertEq(blockNumber, 0, "blockNumber");
        assertEq(sqrtPriceTopX96, 0, "sqrtPriceTopX96");
        assertEq(askPermFeeE6, restingSpreadE6 / 2, "askPermFeeE6");
        assertEq(tempFeeE6, 0, "tempFeeE6");
        assertFalse(tempOnBid, "tempOnBid");
    }
}
