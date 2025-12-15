// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ForkTestBase } from "../helpers/ForkTestBase.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency, CurrencyLibrary } from "v4-core/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IUnlockCallback } from "v4-core/interfaces/callback/IUnlockCallback.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { CurrencySettler } from "../../../lib/v4-core/test/utils/CurrencySettler.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";

/**
 * @title V4PositionQuery
 * @notice Fork tests for querying V4 position details
 * @dev Run with: forge test --mp test/fork/v4/V4PositionQuery.t.sol --fork-url $ETH_RPC_URL -vvv
 *
 * These tests help us implement position tracking in UltraAlignmentVault.sol
 */
contract V4PositionQueryTest is ForkTestBase, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;

    // ========== Types ==========

    struct ModifyLiquidityCallbackData {
        PoolKey key;
        IPoolManager.ModifyLiquidityParams params;
        address sender;
    }

    // ========== State ==========

    IPoolManager poolManager;
    address stateView;
    bool v4Available;

    // Track last liquidity delta from callback
    BalanceDelta lastDelta;
    int256 lastLiquidityDelta;

    function setUp() public {
        loadAddresses();
        v4Available = UNISWAP_V4_POOL_MANAGER != address(0);

        if (v4Available) {
            poolManager = IPoolManager(UNISWAP_V4_POOL_MANAGER);
            stateView = UNISWAP_V4_STATE_VIEW;
        }
    }

    // ========== Tests ==========

    function test_queryPositionLiquidity_success() public {
        if (!v4Available) {
            emit log_string("SKIPPED: V4 not available");
            return;
        }

        emit log_string("=== V4 Query Position Liquidity Test ===");
        emit log_string("");

        // Use Native ETH/USDC 0.05% pool
        PoolKey memory key = _createNativeETHPoolKey(USDC, 500);

        // Get current tick
        (,int24 tick,,) = StateLibrary.getSlot0(poolManager, key.toId());
        int24 tickSpacing = 10;
        int24 tickLower = (tick / tickSpacing) * tickSpacing - tickSpacing;
        int24 tickUpper = (tick / tickSpacing) * tickSpacing + tickSpacing;

        emit log_named_int("tickLower", tickLower);
        emit log_named_int("tickUpper", tickUpper);

        // Add liquidity
        uint256 ethAmount = 1 ether;
        vm.deal(address(this), ethAmount);
        uint256 usdcAmount = 3500e6;
        deal(USDC, address(this), usdcAmount);
        IERC20(USDC).approve(address(poolManager), usdcAmount);

        int256 liquidityDelta = 1e15;
        _modifyLiquidity(key, tickLower, tickUpper, liquidityDelta);

        // Query position
        (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128) =
            StateLibrary.getPositionInfo(
                poolManager,
                key.toId(),
                address(this),
                tickLower,
                tickUpper,
                0 // salt
            );

        emit log_string("");
        emit log_named_uint("Position liquidity", liquidity);
        emit log_named_uint("Position feeGrowthInside0", feeGrowthInside0LastX128);
        emit log_named_uint("Position feeGrowthInside1", feeGrowthInside1LastX128);

        // Verify position exists
        assertEq(liquidity, uint128(uint256(liquidityDelta)), "Liquidity should match");

        emit log_string("");
        emit log_string("[SUCCESS] Position liquidity queried successfully!");
    }

    function test_queryPositionFeeGrowth_success() public {
        if (!v4Available) {
            emit log_string("SKIPPED: V4 not available");
            return;
        }

        emit log_string("=== V4 Query Fee Growth Test ===");
        emit log_string("");

        // Use Native ETH/USDC 0.05% pool
        PoolKey memory key = _createNativeETHPoolKey(USDC, 500);

        // Get current tick
        (,int24 tick,,) = StateLibrary.getSlot0(poolManager, key.toId());
        int24 tickSpacing = 10;
        int24 tickLower = (tick / tickSpacing) * tickSpacing - tickSpacing;
        int24 tickUpper = (tick / tickSpacing) * tickSpacing + tickSpacing;

        // Add liquidity
        uint256 ethAmount = 1 ether;
        vm.deal(address(this), ethAmount);
        uint256 usdcAmount = 3500e6;
        deal(USDC, address(this), usdcAmount);
        IERC20(USDC).approve(address(poolManager), usdcAmount);

        int256 liquidityDelta = 1e15;
        _modifyLiquidity(key, tickLower, tickUpper, liquidityDelta);

        // Query position before any swaps
        (, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128) =
            StateLibrary.getPositionInfo(
                poolManager,
                key.toId(),
                address(this),
                tickLower,
                tickUpper,
                0
            );

        emit log_named_uint("feeGrowthInside0 (before swaps)", feeGrowthInside0LastX128);
        emit log_named_uint("feeGrowthInside1 (before swaps)", feeGrowthInside1LastX128);

        // TODO: In a full test, we'd execute swaps here and verify fee growth increases
        // For now, we demonstrate that fee growth accumulators exist and can be queried

        emit log_string("");
        emit log_string("[SUCCESS] Fee growth accumulators queried!");
        emit log_string("Note: Fee growth increases as swaps occur through the position");
    }

    function test_queryMultiplePositionsSameOwner_success() public {
        if (!v4Available) {
            emit log_string("SKIPPED: V4 not available");
            return;
        }

        emit log_string("=== V4 Multiple Positions Same Owner Test ===");
        emit log_string("");

        // Use Native ETH/USDC 0.05% pool
        PoolKey memory key = _createNativeETHPoolKey(USDC, 500);

        // Get current tick
        (,int24 tick,,) = StateLibrary.getSlot0(poolManager, key.toId());
        int24 tickSpacing = 10;

        // Create Position 1: Below current price
        int24 tick1Lower = (tick / tickSpacing) * tickSpacing - (tickSpacing * 3);
        int24 tick1Upper = (tick / tickSpacing) * tickSpacing - (tickSpacing * 2);

        // Create Position 2: Around current price
        int24 tick2Lower = (tick / tickSpacing) * tickSpacing - tickSpacing;
        int24 tick2Upper = (tick / tickSpacing) * tickSpacing + tickSpacing;

        emit log_named_int("Position 1 tickLower", tick1Lower);
        emit log_named_int("Position 1 tickUpper", tick1Upper);
        emit log_named_int("Position 2 tickLower", tick2Lower);
        emit log_named_int("Position 2 tickUpper", tick2Upper);

        // Fund account
        uint256 ethAmount = 2 ether;
        vm.deal(address(this), ethAmount);
        uint256 usdcAmount = 7000e6;
        deal(USDC, address(this), usdcAmount);
        IERC20(USDC).approve(address(poolManager), usdcAmount);

        // Add liquidity to both positions
        int256 liquidityDelta = 1e15;
        _modifyLiquidity(key, tick1Lower, tick1Upper, liquidityDelta);
        _modifyLiquidity(key, tick2Lower, tick2Upper, liquidityDelta);

        // Query both positions
        (uint128 liquidity1,,) = StateLibrary.getPositionInfo(
            poolManager,
            key.toId(),
            address(this),
            tick1Lower,
            tick1Upper,
            0
        );

        (uint128 liquidity2,,) = StateLibrary.getPositionInfo(
            poolManager,
            key.toId(),
            address(this),
            tick2Lower,
            tick2Upper,
            0
        );

        emit log_string("");
        emit log_named_uint("Position 1 liquidity", liquidity1);
        emit log_named_uint("Position 2 liquidity", liquidity2);

        // Both positions should exist
        assertEq(liquidity1, uint128(uint256(liquidityDelta)), "Position 1 liquidity");
        assertEq(liquidity2, uint128(uint256(liquidityDelta)), "Position 2 liquidity");

        emit log_string("");
        emit log_string("[SUCCESS] Multiple positions tracked independently!");
        emit log_string("Vault can manage multiple positions in same pool");
    }

    function test_queryPositionAfterRemovingLiquidity_success() public {
        if (!v4Available) {
            emit log_string("SKIPPED: V4 not available");
            return;
        }

        emit log_string("=== V4 Query After Removing Liquidity Test ===");
        emit log_string("");

        // Use Native ETH/USDC 0.05% pool
        PoolKey memory key = _createNativeETHPoolKey(USDC, 500);

        // Get current tick
        (,int24 tick,,) = StateLibrary.getSlot0(poolManager, key.toId());
        int24 tickSpacing = 10;
        int24 tickLower = (tick / tickSpacing) * tickSpacing - tickSpacing;
        int24 tickUpper = (tick / tickSpacing) * tickSpacing + tickSpacing;

        // Add liquidity
        uint256 ethAmount = 1 ether;
        vm.deal(address(this), ethAmount);
        uint256 usdcAmount = 3500e6;
        deal(USDC, address(this), usdcAmount);
        IERC20(USDC).approve(address(poolManager), usdcAmount);

        int256 liquidityDelta = 1e15;
        _modifyLiquidity(key, tickLower, tickUpper, liquidityDelta);

        // Query position after adding
        (uint128 liquidityAfterAdd,,) = StateLibrary.getPositionInfo(
            poolManager,
            key.toId(),
            address(this),
            tickLower,
            tickUpper,
            0
        );

        emit log_named_uint("Liquidity after add", liquidityAfterAdd);

        // Remove half the liquidity
        int256 removeDelta = -int256(liquidityDelta / 2);
        _modifyLiquidity(key, tickLower, tickUpper, removeDelta);

        // Query position after removing
        (uint128 liquidityAfterRemove,,) = StateLibrary.getPositionInfo(
            poolManager,
            key.toId(),
            address(this),
            tickLower,
            tickUpper,
            0
        );

        emit log_named_uint("Liquidity after remove", liquidityAfterRemove);

        // Verify liquidity decreased
        assertEq(
            liquidityAfterRemove,
            uint128(uint256(liquidityDelta / 2)),
            "Liquidity should be halved"
        );

        emit log_string("");
        emit log_string("[SUCCESS] Position updated after liquidity removal!");
    }

    function test_calculatePositionValue() public {
        if (!v4Available) {
            emit log_string("SKIPPED: V4 not available");
            return;
        }

        emit log_string("=== V4 Calculate Position Value Test ===");
        emit log_string("");

        // Use Native ETH/USDC 0.05% pool
        PoolKey memory key = _createNativeETHPoolKey(USDC, 500);

        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta = 1e15;

        // Setup position range
        {
            (, int24 tick,,) = StateLibrary.getSlot0(poolManager, key.toId());
            int24 tickSpacing = 10;
            tickLower = (tick / tickSpacing) * tickSpacing - tickSpacing;
            tickUpper = (tick / tickSpacing) * tickSpacing + tickSpacing;

            emit log_named_int("Current tick", tick);
            emit log_named_int("Position tickLower", tickLower);
            emit log_named_int("Position tickUpper", tickUpper);
        }

        uint256 ethSpent;
        uint256 usdcSpent;

        // Add liquidity and track amounts spent
        {
            vm.deal(address(this), 1 ether);
            deal(USDC, address(this), 3500e6);
            IERC20(USDC).approve(address(poolManager), 3500e6);

            uint256 ethBefore = address(this).balance;
            uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));

            _modifyLiquidity(key, tickLower, tickUpper, liquidityDelta);

            ethSpent = ethBefore - address(this).balance;
            usdcSpent = usdcBefore - IERC20(USDC).balanceOf(address(this));

            emit log_string("");
            emit log_named_uint("ETH deposited", ethSpent);
            emit log_named_uint("USDC deposited", usdcSpent);
        }

        // Query position and verify
        {
            (uint128 liquidity,,) = StateLibrary.getPositionInfo(
                poolManager,
                key.toId(),
                address(this),
                tickLower,
                tickUpper,
                0
            );

            emit log_named_uint("Position liquidity", liquidity);

            // Verify position
            assertEq(liquidity, uint128(uint256(liquidityDelta)), "Liquidity matches");
            assertGt(ethSpent, 0, "Spent ETH");
            assertGt(usdcSpent, 0, "Spent USDC");
        }

        emit log_string("");
        emit log_string("[SUCCESS] Position value calculation verified!");
        emit log_string("For precise token amounts, use SqrtPriceMath.getAmount0Delta/getAmount1Delta");
    }

    // ========== Unlock Callback ==========

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "Only PoolManager");

        ModifyLiquidityCallbackData memory params = abi.decode(data, (ModifyLiquidityCallbackData));

        // Modify liquidity
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            params.key,
            params.params,
            ""
        );

        // Store deltas
        lastDelta = delta;
        lastLiquidityDelta = params.params.liquidityDelta;

        // Settle currencies
        _settleDelta(params.key, delta, params.sender);

        return abi.encode(delta);
    }

    function _settleDelta(PoolKey memory key, BalanceDelta delta, address sender) internal {
        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();

        if (delta0 < 0) {
            key.currency0.settle(poolManager, sender, uint128(-delta0), false);
        } else if (delta0 > 0) {
            key.currency0.take(poolManager, sender, uint128(delta0), false);
        }

        if (delta1 < 0) {
            key.currency1.settle(poolManager, sender, uint128(-delta1), false);
        } else if (delta1 > 0) {
            key.currency1.take(poolManager, sender, uint128(delta1), false);
        }
    }

    // ========== Helper Functions ==========

    function _modifyLiquidity(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta
    ) internal {
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: liquidityDelta,
            salt: 0
        });

        ModifyLiquidityCallbackData memory callbackData = ModifyLiquidityCallbackData({
            key: key,
            params: params,
            sender: address(this)
        });

        poolManager.unlock(abi.encode(callbackData));
    }

    function _createNativeETHPoolKey(address token, uint24 fee) internal pure returns (PoolKey memory) {
        bool isToken0 = uint160(address(0)) < uint160(token);

        return PoolKey({
            currency0: isToken0 ? CurrencyLibrary.ADDRESS_ZERO : Currency.wrap(token),
            currency1: isToken0 ? Currency.wrap(token) : CurrencyLibrary.ADDRESS_ZERO,
            fee: fee,
            tickSpacing: _getTickSpacing(fee),
            hooks: IHooks(address(0))
        });
    }

    function _getTickSpacing(uint24 fee) internal pure returns (int24) {
        if (fee == 100) return 1;
        if (fee == 500) return 10;
        if (fee == 3000) return 60;
        if (fee == 10000) return 200;
        revert("Unknown fee tier");
    }

    receive() external payable {}
}
