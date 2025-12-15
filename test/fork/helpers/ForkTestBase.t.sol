// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ForkTestBase } from "./ForkTestBase.sol";
import { UniswapHelpers } from "./UniswapHelpers.sol";

/**
 * @title ForkTestBaseTest
 * @notice Smoke tests to verify fork testing infrastructure is working
 * @dev Run with: forge test --mp test/fork/helpers/ForkTestBase.t.sol --fork-url $ETH_RPC_URL -vvv
 */
contract ForkTestBaseTest is ForkTestBase {
    function setUp() public {
        loadAddresses();
    }

    // ========== Address Loading Tests ==========

    function test_loadAddresses_WETH() public view {
        assertEq(WETH, 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2, "WETH address incorrect");
    }

    function test_loadAddresses_USDC() public view {
        assertEq(USDC, 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, "USDC address incorrect");
    }

    function test_loadAddresses_V2Router() public view {
        assertEq(UNISWAP_V2_ROUTER, 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D, "V2 Router address incorrect");
    }

    function test_loadAddresses_V3Router() public view {
        assertEq(UNISWAP_V3_ROUTER, 0xE592427A0AEce92De3Edee1F18E0157C05861564, "V3 Router address incorrect");
    }

    // ========== V2 Helper Tests ==========

    function test_getV2Reserves_WETH_USDC() public view {
        (uint112 reserve0, uint112 reserve1, uint32 blockTimestamp) = getV2Reserves(WETH_USDC_V2_PAIR);

        // Verify reserves exist (not zero)
        assertGt(reserve0, 0, "Reserve0 should be greater than 0");
        assertGt(reserve1, 0, "Reserve1 should be greater than 0");
        assertGt(blockTimestamp, 0, "Block timestamp should be greater than 0");
    }

    function test_calculateV2Output_basic() public pure {
        uint256 amountIn = 1 ether;
        uint112 reserveIn = 100 ether;
        uint112 reserveOut = 200000e6; // 200k USDC (6 decimals)

        uint256 amountOut = calculateV2Output(amountIn, reserveIn, reserveOut);

        // With 1 ETH in and 100 ETH / 200k USDC reserves:
        // Expected output ~1990 USDC (accounting for 0.3% fee)
        assertGt(amountOut, 1900e6, "Output should be > 1900 USDC");
        assertLt(amountOut, 2000e6, "Output should be < 2000 USDC");
    }

    function test_getV2Price_WETH_USDC() public view {
        uint256 price = getV2Price(WETH_USDC_V2_PAIR);

        // WETH/USDC price should be reasonable (e.g., between $1000 and $10000)
        // Note: V2 pair has token0 and token1 - verify which is which
        assertGt(price, 0, "Price should be greater than 0");
    }

    // ========== V3 Helper Tests ==========

    function test_getV3Slot0_WETH_USDC_03() public view {
        (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        ) = getV3Slot0(WETH_USDC_V3_03);

        // Verify slot0 data is valid
        assertGt(sqrtPriceX96, 0, "sqrtPriceX96 should be greater than 0");
        assertGt(tick, MIN_TICK, "Tick should be within valid range (lower)");
        assertLt(tick, MAX_TICK, "Tick should be within valid range (upper)");
        assertTrue(unlocked, "Pool should be unlocked");
    }

    function test_getV3Liquidity_WETH_USDC_03() public view {
        uint128 liquidity = getV3Liquidity(WETH_USDC_V3_03);

        // WETH/USDC 0.3% pool should have liquidity
        assertGt(liquidity, 0, "Liquidity should be greater than 0");
    }

    function test_getV3Price_WETH_USDC_03() public view {
        uint256 price = getV3Price(WETH_USDC_V3_03);

        // Price should be reasonable
        assertGt(price, 0, "Price should be greater than 0");
    }

    // ========== UniswapHelpers Tests ==========

    function test_sqrtPriceX96ToPrice() public {
        // Test with a known sqrtPriceX96 value
        // For 1:1 price, sqrtPriceX96 = 2^96
        uint160 sqrtPriceX96 = uint160(79228162514264337593543950336); // 2^96

        uint256 price = UniswapHelpers.sqrtPriceX96ToPrice(sqrtPriceX96);

        // Should be close to 1e18 (1:1 ratio)
        assertApproxEq(price, 1e18, 100, "Price should be approximately 1e18");
    }

    function test_priceToSqrtPriceX96() public {
        uint256 price = 1e18; // 1:1 ratio

        uint160 sqrtPriceX96 = UniswapHelpers.priceToSqrtPriceX96(price);

        // Should be close to 2^96
        uint160 expected = uint160(79228162514264337593543950336);
        assertApproxEq(uint256(sqrtPriceX96), uint256(expected), 1000, "sqrtPriceX96 should be approximately 2^96");
    }

    function test_calculateV2Output_helperLibrary() public {
        uint256 amountIn = 1 ether;
        uint256 reserveIn = 100 ether;
        uint256 reserveOut = 200000e6;

        uint256 amountOut = UniswapHelpers.calculateV2Output(amountIn, reserveIn, reserveOut);

        assertGt(amountOut, 1900e6, "Output should be > 1900 USDC");
        assertLt(amountOut, 2000e6, "Output should be < 2000 USDC");
    }

    function test_sqrt() public {
        assertEq(UniswapHelpers.sqrt(0), 0);
        assertEq(UniswapHelpers.sqrt(1), 1);
        assertEq(UniswapHelpers.sqrt(4), 2);
        assertEq(UniswapHelpers.sqrt(9), 3);
        assertEq(UniswapHelpers.sqrt(16), 4);
        assertEq(UniswapHelpers.sqrt(100), 10);
    }

    function test_minMax() public {
        assertEq(UniswapHelpers.min(5, 10), 5);
        assertEq(UniswapHelpers.min(10, 5), 5);
        assertEq(UniswapHelpers.max(5, 10), 10);
        assertEq(UniswapHelpers.max(10, 5), 10);
    }

    function test_getTickSpacing() public {
        assertEq(UniswapHelpers.getTickSpacing(500), 10);
        assertEq(UniswapHelpers.getTickSpacing(3000), 60);
        assertEq(UniswapHelpers.getTickSpacing(10000), 200);
    }

    // ========== Helper Function Tests ==========

    function test_dealETH() public {
        address recipient = address(0xBEEF);
        uint256 amount = 10 ether;

        dealETH(recipient, amount);

        assertEq(recipient.balance, amount, "ETH balance should match dealt amount");
    }

    function test_dealERC20() public {
        address recipient = address(0xBEEF);
        uint256 amount = 1000e6; // 1000 USDC

        dealERC20(USDC, recipient, amount);

        assertEq(getBalance(USDC, recipient), amount, "USDC balance should match dealt amount");
    }

    function test_percentDiff() public {
        // 10 and 12 have 18.18% difference
        uint256 diff = percentDiff(10, 12);
        assertGt(diff, 0.15e18, "Percent diff should be > 15%");
        assertLt(diff, 0.20e18, "Percent diff should be < 20%");

        // Same values have 0% difference
        assertEq(percentDiff(100, 100), 0, "Same values should have 0% diff");
    }

    function test_assertApproxEq_helper() public {
        // 100 and 101 are within 200 bps (2%)
        assertApproxEq(100, 101, 200, "Should be within tolerance");

        // 100 and 100 are exact
        assertApproxEq(100, 100, 1, "Exact values should pass");
    }

    // Tick constants for testing
    int24 constant MIN_TICK = -887272;
    int24 constant MAX_TICK = 887272;
}
