// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ForkTestBase } from "../helpers/ForkTestBase.sol";
import { UniswapHelpers } from "../helpers/UniswapHelpers.sol";

/**
 * @title V3PoolQuery
 * @notice Fork tests for querying Uniswap V3 pool state
 * @dev Run with: forge test --mp test/fork/v3/V3PoolQuery.t.sol --fork-url $ETH_RPC_URL -vvv
 *
 * Purpose: Validate assumptions about:
 * - Querying V3 pool slot0 (sqrtPriceX96, tick, observations)
 * - Querying pool liquidity
 * - Querying fee protocol settings
 * - Comparing pools across different fee tiers
 * - Tick spacing validation
 *
 * These tests help us implement _checkTargetAssetPriceAndPurchasePower() for V3 pools
 * and _quoteV3Swap() in UltraAlignmentVault.sol
 */
contract V3PoolQueryTest is ForkTestBase {
    function setUp() public {
        loadAddresses();
    }

    /**
     * @notice Test querying slot0 from WETH/USDC 0.3% pool
     * @dev slot0 contains: sqrtPriceX96, tick, observationIndex, observationCardinality, etc.
     */
    function test_queryPoolSlot0_returnsValidData() public {
        (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        ) = getV3Slot0(WETH_USDC_V3_03);

        // Verify sqrtPriceX96 is in valid range (not zero, not extreme)
        assertGt(sqrtPriceX96, 0, "sqrtPriceX96 should be > 0");
        assertLt(sqrtPriceX96, type(uint160).max / 2, "sqrtPriceX96 should be reasonable");

        // Verify tick is within valid bounds
        int24 MIN_TICK = -887272;
        int24 MAX_TICK = 887272;
        assertGt(tick, MIN_TICK, "Tick should be > MIN_TICK");
        assertLt(tick, MAX_TICK, "Tick should be < MAX_TICK");

        // Pool should be unlocked (not in the middle of a transaction)
        assertTrue(unlocked, "Pool should be unlocked");

        // Log slot0 data for inspection
        emit log_named_string("Pool", "WETH/USDC 0.3%");
        emit log_named_uint("sqrtPriceX96", sqrtPriceX96);
        emit log_named_int("tick", tick);
        emit log_named_uint("observationIndex", observationIndex);
        emit log_named_uint("observationCardinality", observationCardinality);
        emit log_named_uint("observationCardinalityNext", observationCardinalityNext);
        emit log_named_uint("feeProtocol", feeProtocol);

        // Convert sqrtPriceX96 to human-readable price
        uint256 price = sqrtPriceX96ToPrice(sqrtPriceX96);
        emit log_named_uint("Price (scaled by 1e18)", price);

        // For WETH/USDC, price should be in reasonable range
        // Exact validation depends on token ordering (which is token0 vs token1)
        assertGt(price, 0, "Price should be > 0");
    }

    /**
     * @notice Test querying liquidity from V3 pool
     * @dev Liquidity represents the available liquidity at the current tick
     */
    function test_queryPoolLiquidity_success() public {
        uint128 liquidity = getV3Liquidity(WETH_USDC_V3_03);

        // WETH/USDC 0.3% pool should have substantial liquidity
        assertGt(liquidity, 0, "Liquidity should be > 0");

        emit log_named_string("Pool", "WETH/USDC 0.3%");
        emit log_named_uint("Liquidity", liquidity);

        // Compare liquidity across different fee tiers
        uint128 liquidity_005 = getV3Liquidity(WETH_USDC_V3_005);
        uint128 liquidity_1 = getV3Liquidity(WETH_USDC_V3_1);

        emit log_named_uint("Liquidity 0.05%", liquidity_005);
        emit log_named_uint("Liquidity 0.3%", liquidity);
        emit log_named_uint("Liquidity 1%", liquidity_1);

        // All pools should have liquidity
        assertGt(liquidity_005, 0, "0.05% pool should have liquidity");
        assertGt(liquidity_1, 0, "1% pool should have liquidity");

        // 0.3% pool typically has most liquidity for WETH/USDC
        // (This may not always be true, but is generally the case)
    }

    /**
     * @notice Test querying fee protocol settings
     * @dev Fee protocol determines what portion of fees go to protocol vs LPs
     */
    function test_queryPoolFeeProtocol_success() public {
        (,,,,, uint8 feeProtocol,) = getV3Slot0(WETH_USDC_V3_03);

        // Fee protocol is packed: lower 4 bits for token0, upper 4 bits for token1
        uint8 feeProtocol0 = feeProtocol % 16;
        uint8 feeProtocol1 = feeProtocol >> 4;

        emit log_named_uint("feeProtocol (packed)", feeProtocol);
        emit log_named_uint("feeProtocol0", feeProtocol0);
        emit log_named_uint("feeProtocol1", feeProtocol1);

        // Fee protocol should be in valid range (0-10)
        // 0 means 0%, 1 means 1/10 = 10%, 2 means 1/5 = 20%, etc.
        assertLe(feeProtocol0, 10, "feeProtocol0 should be <= 10");
        assertLe(feeProtocol1, 10, "feeProtocol1 should be <= 10");
    }

    /**
     * @notice Compare pools across different fee tiers
     * @dev Verify we can query 0.05%, 0.3%, and 1% pools
     */
    function test_comparePoolsAcrossFeeTiers() public {
        // Query all three fee tiers for WETH/USDC
        (uint160 sqrtPrice_005, int24 tick_005,,,,,) = getV3Slot0(WETH_USDC_V3_005);
        (uint160 sqrtPrice_03, int24 tick_03,,,,,) = getV3Slot0(WETH_USDC_V3_03);
        (uint160 sqrtPrice_1, int24 tick_1,,,,,) = getV3Slot0(WETH_USDC_V3_1);

        // All pools should have valid prices
        assertGt(sqrtPrice_005, 0, "0.05% pool should have price");
        assertGt(sqrtPrice_03, 0, "0.3% pool should have price");
        assertGt(sqrtPrice_1, 0, "1% pool should have price");

        // Convert to human-readable prices
        uint256 price_005 = sqrtPriceX96ToPrice(sqrtPrice_005);
        uint256 price_03 = sqrtPriceX96ToPrice(sqrtPrice_03);
        uint256 price_1 = sqrtPriceX96ToPrice(sqrtPrice_1);

        emit log_named_string("Fee Tier Comparison", "WETH/USDC");
        emit log_named_uint("0.05% Price", price_005);
        emit log_named_uint("0.3% Price", price_03);
        emit log_named_uint("1% Price", price_1);
        emit log_named_int("0.05% Tick", tick_005);
        emit log_named_int("0.3% Tick", tick_03);
        emit log_named_int("1% Tick", tick_1);

        // Prices should be similar across fee tiers (within 1%)
        // Arbitrage keeps them aligned
        uint256 maxPrice = UniswapHelpers.max(price_005, UniswapHelpers.max(price_03, price_1));
        uint256 minPrice = UniswapHelpers.min(price_005, UniswapHelpers.min(price_03, price_1));
        uint256 priceDiff = percentDiff(maxPrice, minPrice);

        emit log_named_uint("Price Difference %", priceDiff / 1e16);

        // Prices should be within 1% of each other
        assertLt(priceDiff, 0.01e18, "Prices across fee tiers should be within 1%");
    }

    /**
     * @notice Test that tick spacing matches fee tier
     * @dev Each fee tier has a specific tick spacing:
     *      - 0.05% (500) → tick spacing 10
     *      - 0.3% (3000) → tick spacing 60
     *      - 1% (10000) → tick spacing 200
     */
    function test_queryTickSpacing_matchesFeeTier() public {
        // Query tick spacing from pools
        // Note: tickSpacing is not directly in slot0, need to call pool.tickSpacing()

        // Query tick spacing for each pool
        (bool success_005, bytes memory data_005) = WETH_USDC_V3_005.staticcall(
            abi.encodeWithSignature("tickSpacing()")
        );
        require(success_005, "tickSpacing call failed for 0.05%");
        int24 tickSpacing_005 = abi.decode(data_005, (int24));

        (bool success_03, bytes memory data_03) = WETH_USDC_V3_03.staticcall(
            abi.encodeWithSignature("tickSpacing()")
        );
        require(success_03, "tickSpacing call failed for 0.3%");
        int24 tickSpacing_03 = abi.decode(data_03, (int24));

        (bool success_1, bytes memory data_1) = WETH_USDC_V3_1.staticcall(
            abi.encodeWithSignature("tickSpacing()")
        );
        require(success_1, "tickSpacing call failed for 1%");
        int24 tickSpacing_1 = abi.decode(data_1, (int24));

        // Verify tick spacings match expected values
        assertEq(tickSpacing_005, 10, "0.05% pool should have tick spacing 10");
        assertEq(tickSpacing_03, 60, "0.3% pool should have tick spacing 60");
        assertEq(tickSpacing_1, 200, "1% pool should have tick spacing 200");

        emit log_named_int("0.05% Tick Spacing", tickSpacing_005);
        emit log_named_int("0.3% Tick Spacing", tickSpacing_03);
        emit log_named_int("1% Tick Spacing", tickSpacing_1);

        // Verify our helper function matches
        assertEq(UniswapHelpers.getTickSpacing(500), tickSpacing_005, "Helper should match 0.05%");
        assertEq(UniswapHelpers.getTickSpacing(3000), tickSpacing_03, "Helper should match 0.3%");
        assertEq(UniswapHelpers.getTickSpacing(10000), tickSpacing_1, "Helper should match 1%");
    }

    /**
     * @notice Test querying pool fee tier
     * @dev Verify we can determine which fee tier a pool uses
     */
    function test_queryPoolFee() public {
        // Query fee from each pool
        (bool success_005, bytes memory data_005) = WETH_USDC_V3_005.staticcall(
            abi.encodeWithSignature("fee()")
        );
        require(success_005, "fee call failed for 0.05%");
        uint24 fee_005 = abi.decode(data_005, (uint24));

        (bool success_03, bytes memory data_03) = WETH_USDC_V3_03.staticcall(
            abi.encodeWithSignature("fee()")
        );
        require(success_03, "fee call failed for 0.3%");
        uint24 fee_03 = abi.decode(data_03, (uint24));

        (bool success_1, bytes memory data_1) = WETH_USDC_V3_1.staticcall(
            abi.encodeWithSignature("fee()")
        );
        require(success_1, "fee call failed for 1%");
        uint24 fee_1 = abi.decode(data_1, (uint24));

        // Verify fees match expected values
        assertEq(fee_005, 500, "0.05% pool fee should be 500");
        assertEq(fee_03, 3000, "0.3% pool fee should be 3000");
        assertEq(fee_1, 10000, "1% pool fee should be 10000");

        emit log_named_uint("0.05% Fee", fee_005);
        emit log_named_uint("0.3% Fee", fee_03);
        emit log_named_uint("1% Fee", fee_1);
    }
}
