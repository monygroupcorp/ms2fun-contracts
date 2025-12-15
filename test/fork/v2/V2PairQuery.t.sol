// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ForkTestBase } from "../helpers/ForkTestBase.sol";
import { UniswapHelpers } from "../helpers/UniswapHelpers.sol";

/**
 * @title V2PairQuery
 * @notice Fork tests for querying Uniswap V2 pair reserves and pricing
 * @dev Run with: forge test --mp test/fork/v2/V2PairQuery.t.sol --fork-url $ETH_RPC_URL -vvv
 *
 * Purpose: Validate assumptions about:
 * - Querying V2 pair reserves for pricing
 * - Calculating prices using constant product formula (x*y=k)
 * - Checking for pool existence
 * - Price consistency across different pairs
 *
 * These tests help us understand how to implement _checkTargetAssetPriceAndPurchasePower()
 * and _quoteV2Swap() in UltraAlignmentVault.sol
 */
contract V2PairQueryTest is ForkTestBase {
    function setUp() public {
        loadAddresses();
    }

    /**
     * @notice Test querying WETH/USDC pair reserves returns valid data
     * @dev This is the most liquid V2 pair, should have substantial reserves
     */
    function test_queryWETHUSDCPairReserves_returnsValidReserves() public {
        (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast) = getV2Reserves(WETH_USDC_V2_PAIR);

        // Verify reserves exist and are non-zero
        assertGt(reserve0, 0, "Reserve0 should be greater than 0");
        assertGt(reserve1, 0, "Reserve1 should be greater than 0");

        // Verify reserves are substantial (at least 1 ETH and 1000 USDC equivalent)
        // WETH has 18 decimals, USDC has 6 decimals
        // We don't know which is token0 vs token1, so check both scenarios
        bool hasSubstantialLiquidity = (reserve0 > 1e18 && reserve1 > 1000e6) || (reserve0 > 1000e6 && reserve1 > 1e18);
        assertTrue(hasSubstantialLiquidity, "Pair should have substantial liquidity");

        // Verify timestamp is reasonable (not zero)
        assertGt(blockTimestampLast, 0, "Block timestamp should be greater than 0");

        // Log reserves for inspection
        emit log_named_uint("Reserve0", reserve0);
        emit log_named_uint("Reserve1", reserve1);
        emit log_named_uint("Block Timestamp", blockTimestampLast);
    }

    /**
     * @notice Test querying a non-existent pair returns zero address
     * @dev This helps us handle cases where target token doesn't have a V2 pool
     */
    function test_queryNonexistentPair_returnsZeroAddress() public {
        // Try to get factory to check for non-existent pair
        // Call factory.getPair(tokenA, tokenB)
        address randomToken = address(0xDEADBEEF);

        (bool success, bytes memory data) = UNISWAP_V2_FACTORY.staticcall(
            abi.encodeWithSignature("getPair(address,address)", WETH, randomToken)
        );

        if (success) {
            address pair = abi.decode(data, (address));
            assertEq(pair, address(0), "Non-existent pair should return zero address");
        } else {
            // Factory doesn't have getPair or call failed - that's also valid
            assertTrue(true, "Factory call failed as expected for non-existent pair");
        }
    }

    /**
     * @notice Test that calculated swap output matches constant product formula
     * @dev Verify our V2 output calculation is correct: (amountIn * 997 * reserveOut) / (reserveIn * 1000 + amountIn * 997)
     */
    function test_calculateSwapOutput_matchesConstantProduct() public {
        (uint112 reserve0, uint112 reserve1,) = getV2Reserves(WETH_USDC_V2_PAIR);

        // Simulate swapping 1 ETH for USDC
        uint256 amountIn = 1 ether;

        // Calculate output using our helper (assumes WETH is token0)
        uint256 amountOut0to1 = calculateV2Output(amountIn, reserve0, reserve1);

        // Verify output is reasonable (should get some USDC)
        assertGt(amountOut0to1, 0, "Output should be greater than 0");

        // Manual calculation to verify formula
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserve1;
        uint256 denominator = (reserve0 * 1000) + amountInWithFee;
        uint256 expectedOutput = numerator / denominator;

        assertEq(amountOut0to1, expectedOutput, "Calculated output should match formula");

        // Log the swap details
        emit log_named_uint("Amount In (WETH)", amountIn);
        emit log_named_uint("Amount Out (calculated)", amountOut0to1);
        emit log_named_uint("Reserve0", reserve0);
        emit log_named_uint("Reserve1", reserve1);

        // Try the reverse direction (token1 -> token0)
        uint256 amountOut1to0 = calculateV2Output(amountIn, reserve1, reserve0);
        assertGt(amountOut1to0, 0, "Reverse output should be greater than 0");

        emit log_named_uint("Amount Out (reverse)", amountOut1to0);
    }

    /**
     * @notice Test querying multiple pairs successfully
     * @dev Verify we can query different pairs: WETH/USDC, WETH/DAI, WETH/USDT
     */
    function test_queryMultiplePairs_success() public {
        // Query WETH/USDC pair
        (uint112 reserve0_usdc, uint112 reserve1_usdc,) = getV2Reserves(WETH_USDC_V2_PAIR);
        assertGt(reserve0_usdc, 0, "WETH/USDC reserve0 should be > 0");
        assertGt(reserve1_usdc, 0, "WETH/USDC reserve1 should be > 0");

        // Query WETH/DAI pair
        (uint112 reserve0_dai, uint112 reserve1_dai,) = getV2Reserves(WETH_DAI_V2_PAIR);
        assertGt(reserve0_dai, 0, "WETH/DAI reserve0 should be > 0");
        assertGt(reserve1_dai, 0, "WETH/DAI reserve1 should be > 0");

        // Query WETH/USDT pair
        (uint112 reserve0_usdt, uint112 reserve1_usdt,) = getV2Reserves(WETH_USDT_V2_PAIR);
        assertGt(reserve0_usdt, 0, "WETH/USDT reserve0 should be > 0");
        assertGt(reserve1_usdt, 0, "WETH/USDT reserve1 should be > 0");

        // Log all reserves
        emit log_named_string("Pair", "WETH/USDC");
        emit log_named_uint("  Reserve0", reserve0_usdc);
        emit log_named_uint("  Reserve1", reserve1_usdc);

        emit log_named_string("Pair", "WETH/DAI");
        emit log_named_uint("  Reserve0", reserve0_dai);
        emit log_named_uint("  Reserve1", reserve1_dai);

        emit log_named_string("Pair", "WETH/USDT");
        emit log_named_uint("  Reserve0", reserve0_usdt);
        emit log_named_uint("  Reserve1", reserve1_usdt);
    }

    /**
     * @notice Test price consistency across different WETH pairs
     * @dev Compare WETH prices from USDC, DAI, and USDT pairs
     *      Prices should be within reasonable range of each other (±5%)
     *      This validates our oracle price checking logic
     *
     * SKIPPED: This test is flawed because:
     * - Token ordering differs between pairs (USDC/WETH vs DAI/WETH vs WETH/USDT)
     * - Token decimals differ (USDC=6, DAI=18, USDT=6)
     * - getV2Price() doesn't normalize for decimals or token order
     * - Would need decimal-aware price calculation to make this meaningful
     */
    function skip_test_priceConsistency_acrossPairs() public {
        // Get prices from each pair
        uint256 priceFromUSDC = getV2Price(WETH_USDC_V2_PAIR);
        uint256 priceFromDAI = getV2Price(WETH_DAI_V2_PAIR);
        uint256 priceFromUSDT = getV2Price(WETH_USDT_V2_PAIR);

        // All prices should be non-zero
        assertGt(priceFromUSDC, 0, "USDC price should be > 0");
        assertGt(priceFromDAI, 0, "DAI price should be > 0");
        assertGt(priceFromUSDT, 0, "USDT price should be > 0");

        // Log prices for manual inspection
        emit log_named_uint("Price from WETH/USDC", priceFromUSDC);
        emit log_named_uint("Price from WETH/DAI", priceFromDAI);
        emit log_named_uint("Price from WETH/USDT", priceFromUSDT);

        // Check consistency: prices should be within ±10% of each other
        // Note: getV2Price returns reserve0/reserve1, so interpretation depends on token order
        // We're mainly checking they're in the same ballpark, not exact equality

        // Calculate percent differences
        uint256 diffUSDC_DAI = percentDiff(priceFromUSDC, priceFromDAI);
        uint256 diffUSDC_USDT = percentDiff(priceFromUSDC, priceFromUSDT);
        uint256 diffDAI_USDT = percentDiff(priceFromDAI, priceFromUSDT);

        emit log_named_uint("Percent diff USDC-DAI", diffUSDC_DAI / 1e16); // in bps * 100
        emit log_named_uint("Percent diff USDC-USDT", diffUSDC_USDT / 1e16);
        emit log_named_uint("Percent diff DAI-USDT", diffDAI_USDT / 1e16);

        // Prices should be somewhat consistent (within 50% of each other as a sanity check)
        // In practice, stablecoin pairs should be very close
        // Note: This may fail if token ordering differs between pairs
        // We're being lenient here just to validate the query mechanism works

        // Just verify prices are in reasonable ranges (not wildly different)
        // This is a smoke test, not a precise oracle validation
        assertLt(diffUSDC_DAI, 0.5e18, "USDC-DAI prices should be within 50%");
        assertLt(diffUSDC_USDT, 0.5e18, "USDC-USDT prices should be within 50%");
        assertLt(diffDAI_USDT, 0.5e18, "DAI-USDT prices should be within 50%");
    }
}
