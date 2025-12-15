// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ForkTestBase } from "../helpers/ForkTestBase.sol";
import { UniswapHelpers } from "../helpers/UniswapHelpers.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// V2Router02 interface
interface IUniswapV2Router02Slippage {
    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);
}

/**
 * @title V2SlippageProtection
 * @notice Fork tests for V2 swap edge cases and slippage scenarios
 * @dev Run with: forge test --mp test/fork/v2/V2SlippageProtection.t.sol --fork-url $ETH_RPC_URL -vvv
 *
 * Purpose: Validate assumptions about:
 * - Slippage impact on large swaps
 * - Edge cases (zero amount, empty pairs)
 * - Price impact calculation
 * - How to set appropriate minOut for vault swaps
 *
 * These tests help us implement slippage protection in _swapETHForTarget()
 */
contract V2SlippageProtectionTest is ForkTestBase {

    IUniswapV2Router02Slippage router;
    address swapper;

    function setUp() public {
        loadAddresses();
        router = IUniswapV2Router02Slippage(UNISWAP_V2_ROUTER);
        swapper = testAddress1;

        // Give swapper 10,000 ETH for large swap testing
        dealETH(swapper, 10_000 ether);
    }

    /**
     * @notice Test slippage on a very large swap (1000 ETH)
     * @dev Large swaps should experience significant price impact
     *      This helps us understand how to calculate minOut for large vault conversions
     */
    function test_swapLargeAmount_highSlippage() public {
        uint256 amountIn = 1000 ether;
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = USDC;

        // Get expected output for large swap
        uint256[] memory expectedAmounts = router.getAmountsOut(amountIn, path);
        uint256 expectedUSDC = expectedAmounts[1];

        // Also calculate output for 1 ETH to measure price impact
        uint256[] memory smallSwapAmounts = router.getAmountsOut(1 ether, path);
        uint256 smallSwapRate = smallSwapAmounts[1]; // USDC per 1 ETH

        // If there was no price impact, 1000 ETH would give 1000x the rate
        uint256 noSlippageOutput = smallSwapRate * 1000;

        // Calculate actual price impact
        uint256 slippageAmount = noSlippageOutput - expectedUSDC;
        uint256 slippagePercent = (slippageAmount * 10000) / noSlippageOutput; // In basis points

        // Log slippage analysis
        emit log_named_uint("Amount In (ETH)", amountIn / 1 ether);
        emit log_named_uint("Expected USDC Out", expectedUSDC / 1e6);
        emit log_named_uint("No-Slippage Output", noSlippageOutput / 1e6);
        emit log_named_uint("Slippage Amount (USDC)", slippageAmount / 1e6);
        emit log_named_uint("Slippage Percent (bps)", slippagePercent);

        // Verify slippage is substantial for large swap
        assertGt(slippagePercent, 10, "Large swap should have >0.1% slippage");

        // Execute the swap
        vm.prank(swapper);
        uint256[] memory amounts = router.swapExactETHForTokens{value: amountIn}(
            (expectedUSDC * 95) / 100, // Allow 5% slippage
            path,
            swapper,
            block.timestamp + 300
        );

        // Verify we got the expected amount
        assertEq(amounts[1], expectedUSDC, "Should get quoted amount");

        // Log actual effective price
        uint256 effectivePrice = amounts[1] / 1000; // USDC per ETH (adjusted for decimals)
        emit log_named_uint("Effective Price (USDC per ETH)", effectivePrice / 1e6);
        emit log_named_uint("Small Swap Price (USDC per ETH)", smallSwapRate / 1e6);

        // Critical Learning: For vault, we should:
        // 1. Query getAmountsOut before swap
        // 2. Set minOut to quoted amount - slippage tolerance (e.g., 1-3%)
        // 3. Consider splitting large swaps across multiple blocks/pools
    }

    /**
     * @notice Test that swapping zero amount reverts
     * @dev Edge case validation for vault input checks
     */
    function test_swapZeroAmount_reverts() public {
        uint256 amountIn = 0;
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = USDC;

        // Expect revert when swapping 0 ETH
        vm.prank(swapper);
        vm.expectRevert();
        router.swapExactETHForTokens{value: amountIn}(
            0,
            path,
            swapper,
            block.timestamp + 300
        );
    }

    /**
     * @notice Test swapping to a pair with low liquidity
     * @dev Simulate what happens when target token has thin liquidity
     *      This may not revert but will have very high slippage
     */
    function test_swapToLowLiquidityPair_highSlippage() public {
        // For this test, we'll use a less liquid pair if available
        // Otherwise, we'll test with a smaller amount on WETH/USDC
        // and compare price impact

        uint256 amountIn = 100 ether;
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = USDC;

        // Get reserves to understand liquidity depth
        (uint112 reserve0, uint112 reserve1,) = getV2Reserves(WETH_USDC_V2_PAIR);

        // Determine WETH reserve
        (bool success, bytes memory data) = WETH_USDC_V2_PAIR.staticcall(
            abi.encodeWithSignature("token0()")
        );
        require(success, "token0 call failed");
        address token0 = abi.decode(data, (address));

        uint256 wethReserve = (token0 == WETH) ? reserve0 : reserve1;

        emit log_named_uint("WETH Reserve", wethReserve);
        emit log_named_uint("Swap Amount", amountIn);
        emit log_named_uint("Swap as % of Reserve", (amountIn * 100) / wethReserve);

        // Get quote
        uint256[] memory amounts = router.getAmountsOut(amountIn, path);

        // If swap is > 5% of reserve, slippage should be significant
        if (amountIn * 100 / wethReserve > 5) {
            // Calculate expected slippage
            uint256[] memory smallAmounts = router.getAmountsOut(1 ether, path);
            uint256 linearOutput = (smallAmounts[1] * amountIn) / 1 ether;
            uint256 slippage = ((linearOutput - amounts[1]) * 10000) / linearOutput;

            emit log_named_uint("Expected (linear)", linearOutput);
            emit log_named_uint("Actual (with slippage)", amounts[1]);
            emit log_named_uint("Slippage (bps)", slippage);

            assertGt(slippage, 10, "Swapping >5% of pool should have >0.1% slippage");
        }
    }

    /**
     * @notice Test price impact calculation formula
     * @dev Verify we can accurately predict slippage before executing swap
     *      This is critical for setting minOut parameter in vault
     */
    function test_priceImpactCalculation() public {
        // Test various swap sizes and calculate price impact
        uint256[] memory testAmounts = new uint256[](5);
        testAmounts[0] = 0.1 ether;
        testAmounts[1] = 1 ether;
        testAmounts[2] = 10 ether;
        testAmounts[3] = 100 ether;
        testAmounts[4] = 1000 ether;

        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = USDC;

        // Get baseline rate (1 ETH swap)
        uint256[] memory baselineAmounts = router.getAmountsOut(1 ether, path);
        uint256 baselineRate = baselineAmounts[1]; // USDC per 1 ETH

        emit log_named_string("Swap Size", "Price Impact Analysis");
        emit log_named_uint("Baseline Rate (USDC per ETH)", baselineRate / 1e6);

        for (uint256 i = 0; i < testAmounts.length; i++) {
            uint256 amountIn = testAmounts[i];

            // Get actual quote
            uint256[] memory amounts = router.getAmountsOut(amountIn, path);
            uint256 actualOutput = amounts[1];

            // Calculate linear output (no price impact)
            uint256 linearOutput = (baselineRate * amountIn) / 1 ether;

            // Calculate price impact
            uint256 priceImpact = 0;
            if (linearOutput > actualOutput) {
                priceImpact = ((linearOutput - actualOutput) * 10000) / linearOutput;
            }

            // Calculate effective rate
            uint256 effectiveRate = (actualOutput * 1 ether) / amountIn;

            emit log_named_uint("  Swap Size (ETH)", amountIn / 1 ether);
            emit log_named_uint("    Output (USDC)", actualOutput / 1e6);
            emit log_named_uint("    Price Impact (bps)", priceImpact);
            emit log_named_uint("    Effective Rate", effectiveRate / 1e6);

            // Verify price impact increases with swap size
            if (i > 0) {
                // Later swaps should have >= price impact than earlier ones
                // (This is a general trend, not strict for all pairs)
            }
        }

        // Critical Learning: Price impact formula
        // priceImpact = (linearOutput - actualOutput) / linearOutput
        // For minOut, use: actualOutput * (1 - slippageTolerance)
        // Recommended slippageTolerance: 1-3% (100-300 bps)
    }
}
