// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {DualPoolHook} from "../../src/alf/DualPoolHook.sol";
import {LiquidityBucket} from "../../src/alf/types/Distribution.sol";
import {MockERC4626} from "../alf/mocks/MockERC4626.sol";

/// @title DualPoolHookIssues
/// @notice A ready-made pool plus helpers for writing DualPoolHook tests on Uniswap v4. Mirrors the
///         Infinity port's `test/issues/DualPoolHookIssues.t.sol`, adapted to v4 (`Deployers`,
///         flag-mined hook address, v4 `PoolKey` / `SwapParams`, `StateLibrary` for slot0).
/// @dev Default pool (change the constants or `_buckets` to try other layouts):
///        - two 18-decimal mock tokens, price 1:1 (tick 0);
///        - fee 1 bp (`FEE = 100`), tick spacing 10;
///        - buckets 75% at ±10 ticks, 15% at ±30, 10% at ±60 (the fork-test layout);
///        - `SEED` of each token bootstrapped by the owner (this contract);
///        - one MockERC4626 vault per token (set `USE_VAULTS = false` to hold raw ERC-20).
///      The `test_SwapRoundTrip_profit` body is intentionally left empty, to be filled in.
contract DualPoolHookIssues is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;

    // ─────────────────────────────── configuration ───────────────────────────────

    uint24 internal constant FEE = 100; // 1 bp
    int24 internal constant TICK_SPACING = 10;
    uint256 internal constant SEED = 1_000_000 ether;
    bool internal constant USE_VAULTS = true;

    DualPoolHook internal hook;
    MockERC20 internal token0;
    MockERC20 internal token1;
    MockERC4626 internal vault0;
    MockERC4626 internal vault1;
    PoolKey internal poolKey;
    PoolId internal poolId;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public virtual {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        token0 = MockERC20(Currency.unwrap(currency0));
        token1 = MockERC20(Currency.unwrap(currency1));

        if (USE_VAULTS) {
            vault0 = new MockERC4626(ERC20(address(token0)));
            vault1 = new MockERC4626(ERC20(address(token1)));
        }

        // Deploy the hook at a flag-mined address. Owner = `owner`, max min-deposit-blocks max.
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        hook = DualPoolHook(address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | flags)));
        deployCodeTo(
            "DualPoolHook", abi.encode(manager, uint32(1_000_000), owner, type(uint64).max), address(hook)
        );

        poolKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: FEE, tickSpacing: TICK_SPACING, hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();

        vm.prank(owner);
        hook.initializePool(
            poolKey,
            DualPoolHook.PoolConfig({
                sqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
                distribution: _buckets(),
                allowExternalDeposits: true,
                vault0: IERC4626(address(vault0)),
                vault1: IERC4626(address(vault1)),
                minDepositBlocks: 0
            })
        );

        // Owner bootstraps SEED of each token.
        token0.mint(owner, SEED);
        token1.mint(owner, SEED);
        vm.startPrank(owner);
        token0.approve(address(hook), SEED);
        token1.approve(address(hook), SEED);
        hook.bootstrap(poolKey, SEED, SEED);
        vm.stopPrank();
        vm.roll(block.number + 1);
    }

    /// @dev Swap round trip from tick 0 to 10, then 70, then back to 0. Left empty on purpose.
    function test_SwapRoundTrip_profit() public {
        _fund(alice, 10_000_000 ether);
        (uint256 r0Before, uint256 r1Before) = _reserves();
        (uint256 alice0Before, uint256 alice1Before) = _balances(alice);
        emit log_named_decimal_uint("alice token0 before", alice0Before, 18);
        emit log_named_decimal_uint("alice token1 before", alice1Before, 18);

        (uint256 paid, uint256 received) = _swapExactInToTick(alice, false, 10_000_000 ether, 10);

        assertEq(_tick(), 10, "stopped at tick 10");

        // swap to tick 70
        (uint256 paid2, uint256 received2) = _swapExactInToTick(alice, false, 10_000_000 ether, 70);

        assertEq(_tick(), 70, "stopped at tick 70");

        // swap back to tick 0
        (uint256 paid3, uint256 received3) = _swapExactInToTick(alice, true, 10_000_000 ether, 0);
        // assertEq(_tick(), 0, "stopped at tick 0");
        assertEq(_sqrtPrice(), TickMath.getSqrtPriceAtTick(0), "price back at tick 0");

        (uint256 alice0After, uint256 alice1After) = _balances(alice);
        emit log_named_decimal_uint("alice token0 after ", alice0After, 18);
        emit log_named_decimal_uint("alice token1 after ", alice1After, 18);
        // token0 profit is the difference between the before and after balances of token0.
        int256 token0Profit = int256(alice0After) - int256(alice0Before);
        // token1 profit is the difference between the before and after balances of token1.
        int256 token1Profit = int256(alice1After) - int256(alice1Before);
        emit log_named_decimal_int("alice token0 change", token0Profit, 18);
        emit log_named_decimal_int("alice token1 change", token1Profit, 18);
        // because the price is 1:1, the profit can be calculated as the difference in the balances of the two tokens.
        int256 profit = token0Profit + token1Profit;
        emit log_named_decimal_int("alice profit", profit, 18);
        assertGt(profit, 0, "alice made a profit");
    }

    /// @dev The pool's bucket layout. Override or edit to test other distributions.
    function _buckets() internal pure virtual returns (LiquidityBucket[] memory b) {
        b = new LiquidityBucket[](3);
        b[0] = LiquidityBucket({tickLower: -10, tickUpper: 10, weightBps: 7_500});
        b[1] = LiquidityBucket({tickLower: -30, tickUpper: 30, weightBps: 1_500});
        b[2] = LiquidityBucket({tickLower: -60, tickUpper: 60, weightBps: 1_000});
    }

    // ─────────────────────────────── accounts ───────────────────────────────

    /// @dev Give `user` `amount` of both tokens and approve the router and the hook.
    function _fund(address user, uint256 amount) internal {
        token0.mint(user, amount);
        token1.mint(user, amount);
        vm.startPrank(user);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    function _balances(address user) internal view returns (uint256 bal0, uint256 bal1) {
        return (token0.balanceOf(user), token1.balanceOf(user));
    }

    // ─────────────────────────────── swaps ───────────────────────────────

    /// @dev Swap as `user` through the router with an explicit price limit.
    ///      `amountSpecified < 0` is exact input, `> 0` is exact output.
    function _swap(address user, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96)
        internal
        returns (BalanceDelta delta)
    {
        vm.prank(user);
        delta = swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: sqrtPriceLimitX96}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    /// @dev Exact-input swap as `user`, no price limit. Returns the input paid and output received.
    function _swapExactIn(address user, bool zeroForOne, uint256 amountIn)
        internal
        returns (uint256 paid, uint256 received)
    {
        BalanceDelta d = _swap(user, zeroForOne, -int256(amountIn), _noLimit(zeroForOne));
        return _legs(d, zeroForOne);
    }

    /// @dev Exact-output swap as `user`, no price limit. Returns the input paid and output received.
    function _swapExactOut(address user, bool zeroForOne, uint256 amountOut)
        internal
        returns (uint256 paid, uint256 received)
    {
        BalanceDelta d = _swap(user, zeroForOne, int256(amountOut), _noLimit(zeroForOne));
        return _legs(d, zeroForOne);
    }

    /// @dev Exact-input swap as `user` that stops at `tick` if it gets there first.
    function _swapExactInToTick(address user, bool zeroForOne, uint256 amountIn, int24 tick)
        internal
        returns (uint256 paid, uint256 received)
    {
        BalanceDelta d = _swap(user, zeroForOne, -int256(amountIn), TickMath.getSqrtPriceAtTick(tick));
        return _legs(d, zeroForOne);
    }

    function _noLimit(bool zeroForOne) internal pure returns (uint160) {
        return zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT;
    }

    /// @dev Split a swapper delta into (input paid, output received).
    function _legs(BalanceDelta d, bool zeroForOne) internal pure returns (uint256 paid, uint256 received) {
        (int128 inLeg, int128 outLeg) = zeroForOne ? (d.amount0(), d.amount1()) : (d.amount1(), d.amount0());
        paid = uint256(uint128(-inLeg));
        received = uint256(uint128(outLeg));
    }

    // ─────────────────────────────── liquidity ───────────────────────────────

    /// @dev Deposit `shares` as `user` (fund first with {_fund}). Returns the tokens paid.
    function _addLiquidity(address user, uint256 shares) internal returns (uint256 amount0, uint256 amount1) {
        vm.prank(user);
        (amount0, amount1) = hook.addLiquidity(poolKey, shares, type(uint256).max, type(uint256).max, block.timestamp);
    }

    /// @dev Withdraw `shares` as `user`. Returns the tokens received.
    function _removeLiquidity(address user, uint256 shares) internal returns (uint256 amount0, uint256 amount1) {
        vm.prank(user);
        (amount0, amount1) = hook.removeLiquidity(poolKey, shares, 0, 0, block.timestamp);
    }

    // ─────────────────────────────── views ───────────────────────────────

    function _tick() internal view returns (int24 tick) {
        (, tick,,) = manager.getSlot0(poolId);
    }

    function _sqrtPrice() internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = manager.getSlot0(poolId);
    }

    /// @dev Total assets (LP share pricing).
    function _reserves() internal view returns (uint256 r0, uint256 r1) {
        return hook.getReserves(poolKey);
    }

    /// @dev Immediately deployable assets (JIT sizing and quotes).
    function _effective() internal view returns (uint256 e0, uint256 e1) {
        return hook.getEffectiveLiquidity(poolKey);
    }

    /// @dev Indicative quote: the output for exact input (`amountSpecified < 0`), or the input
    ///      for exact output (`> 0`).
    function _quote(bool zeroForOne, int256 amountSpecified) internal view returns (uint256) {
        return hook.getIndicativeQuote(poolKey, zeroForOne, amountSpecified, ZERO_BYTES);
    }

    /// @dev Indicative (amountIn, amountOut) for a swap that stops at `sqrtPriceLimitX96`.
    function _quoteToPrice(bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96)
        internal
        view
        returns (uint256 amountIn, uint256 amountOut)
    {
        return hook.swapToPrice(poolKey, zeroForOne, amountSpecified, sqrtPriceLimitX96, ZERO_BYTES);
    }

    // ─────────────────────────────── owner ───────────────────────────────

    function _setDistribution(LiquidityBucket[] memory buckets) internal {
        vm.prank(owner);
        hook.setDistribution(poolKey, buckets);
    }

    function _setLive(bool live) internal {
        vm.prank(owner);
        hook.setPoolLive(poolKey, live);
    }

    // ─────────────────────────────── example tests ───────────────────────────────

    function test_setup() public view {
        assertTrue(hook.livePools(poolId), "pool live");
        assertEq(_tick(), 0, "starts at tick 0");
        (uint256 r0, uint256 r1) = _reserves();
        assertApproxEqAbs(r0, SEED, 1, "token0 seeded");
        assertApproxEqAbs(r1, SEED, 1, "token1 seeded");
        assertEq(manager.getLiquidity(poolId), 0, "no resident liquidity between swaps");
    }

    function test_exampleSwapExactIn() public {
        _fund(alice, 1_000 ether);
        uint256 quotedOut = _quote(true, -100 ether);

        (uint256 paid, uint256 received) = _swapExactIn(alice, true, 100 ether);

        assertEq(paid, 100 ether, "full input");
        assertApproxEqRel(received, quotedOut, 0.001e18, "quote output close to fill");
        assertLt(_tick(), 0, "price moved down");
    }

    function test_exampleSwapExactOut() public {
        _fund(alice, 1_000 ether);
        (uint256 paid, uint256 received) = _swapExactOut(alice, false, 50 ether);
        assertEq(received, 50 ether, "exact output");
        assertGt(paid, 50 ether, "input includes the fee");
    }

    function test_exampleSwapToTick() public {
        _fund(alice, 10_000_000 ether);
        _swapExactInToTick(alice, true, 10_000_000 ether, -20);
        assertEq(_tick(), -20, "stopped at the limit");
    }
}
