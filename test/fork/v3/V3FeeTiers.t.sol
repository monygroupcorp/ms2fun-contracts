// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ForkTestBase } from "../helpers/ForkTestBase.sol";
import { UniswapHelpers } from "../helpers/UniswapHelpers.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// V3 SwapRouter interface (simplified)
interface IV3SwapRouterFeeTiers {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface IWETH9FeeTiers {
    function deposit() external payable;
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/**
 * @title V3FeeTiers
 * @notice Fork tests comparing V3 swap behavior across different fee tiers
 * @dev Run with: forge test --mp test/fork/v3/V3FeeTiers.t.sol --fork-url $ETH_RPC_URL -vvv
 *
 * Purpose: Validate assumptions about:
 * - Output differences across 0.05%, 0.3%, 1% fee tiers
 * - When low fee tiers are better (large trades with concentrated liquidity)
 * - Liquidity depth comparison across tiers
 * - Optimal fee tier selection algorithm
 *
 * These tests help us implement smart routing in _quoteV3Swap() to select best fee tier
 */
contract V3FeeTiersTest is ForkTestBase {
    IV3SwapRouterFeeTiers router;
    IWETH9FeeTiers weth;
    address swapper;

    function setUp() public {
        loadAddresses();
        router = IV3SwapRouterFeeTiers(UNISWAP_V3_ROUTER);
        weth = IWETH9FeeTiers(WETH);
        swapper = testAddress1;

        // Give swapper plenty of ETH for testing
        dealETH(swapper, 1000 ether);
    }

    /**
     * @notice Compare swap output across all three fee tiers for same input
     * @dev This shows which tier gives best price for a given trade size
     */
    function test_compareOutputAcrossFeeTiers() public {
        uint256 amountIn = 1 ether;

        // Wrap WETH once for all swaps
        vm.prank(swapper);
        weth.deposit{value: amountIn * 3}(); // Enough for 3 swaps

        // Approve router
        vm.prank(swapper);
        weth.approve(address(router), amountIn * 3);

        // Test swap through 0.05% pool
        IV3SwapRouterFeeTiers.ExactInputSingleParams memory params_005 = IV3SwapRouterFeeTiers.ExactInputSingleParams({
            tokenIn: WETH,
            tokenOut: USDC,
            fee: 500,  // 0.05%
            recipient: swapper,
            deadline: block.timestamp + 300,
            amountIn: amountIn,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        vm.prank(swapper);
        uint256 output_005 = router.exactInputSingle(params_005);

        // Test swap through 0.3% pool
        IV3SwapRouterFeeTiers.ExactInputSingleParams memory params_03 = IV3SwapRouterFeeTiers.ExactInputSingleParams({
            tokenIn: WETH,
            tokenOut: USDC,
            fee: 3000,  // 0.3%
            recipient: swapper,
            deadline: block.timestamp + 300,
            amountIn: amountIn,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        vm.prank(swapper);
        uint256 output_03 = router.exactInputSingle(params_03);

        // Test swap through 1% pool
        IV3SwapRouterFeeTiers.ExactInputSingleParams memory params_1 = IV3SwapRouterFeeTiers.ExactInputSingleParams({
            tokenIn: WETH,
            tokenOut: USDC,
            fee: 10000,  // 1%
            recipient: swapper,
            deadline: block.timestamp + 300,
            amountIn: amountIn,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        vm.prank(swapper);
        uint256 output_1 = router.exactInputSingle(params_1);

        // Log outputs for comparison
        emit log_named_string("Fee Tier Comparison", "1 ETH Swap");
        emit log_named_uint("0.05% Output (USDC)", output_005 / 1e6);
        emit log_named_uint("0.3% Output (USDC)", output_03 / 1e6);
        emit log_named_uint("1% Output (USDC)", output_1 / 1e6);

        // Calculate which is best
        uint256 maxOutput = UniswapHelpers.max(output_005, UniswapHelpers.max(output_03, output_1));
        string memory bestTier;
        if (maxOutput == output_005) bestTier = "0.05%";
        else if (maxOutput == output_03) bestTier = "0.3%";
        else bestTier = "1%";

        emit log_named_string("Best Fee Tier", bestTier);

        // Calculate fee cost for each tier
        emit log_named_uint("0.05% Fee Cost (USDC)", (amountIn * 5 / 10000) / 1e12);
        emit log_named_uint("0.3% Fee Cost (USDC)", (amountIn * 30 / 10000) / 1e12);
        emit log_named_uint("1% Fee Cost (USDC)", (amountIn * 100 / 10000) / 1e12);

        // For a 1 ETH swap on WETH/USDC, typically 0.05% is best (most liquid)
        // But this depends on current liquidity distribution
    }

    /**
     * @notice Test that low fee tier (0.05%) is better for large trades
     * @dev Large trades benefit more from lower fees if liquidity is sufficient
     */
    function test_lowFeeTierBetterForLargeTrades() public {
        uint256 largeAmount = 100 ether;

        // Wrap WETH
        vm.prank(swapper);
        weth.deposit{value: largeAmount * 2}();

        // Approve router
        vm.prank(swapper);
        weth.approve(address(router), largeAmount * 2);

        // Swap through 0.05% pool
        IV3SwapRouterFeeTiers.ExactInputSingleParams memory params_005 = IV3SwapRouterFeeTiers.ExactInputSingleParams({
            tokenIn: WETH,
            tokenOut: USDC,
            fee: 500,
            recipient: swapper,
            deadline: block.timestamp + 300,
            amountIn: largeAmount,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        vm.prank(swapper);
        uint256 output_005 = router.exactInputSingle(params_005);

        // Swap through 1% pool
        IV3SwapRouterFeeTiers.ExactInputSingleParams memory params_1 = IV3SwapRouterFeeTiers.ExactInputSingleParams({
            tokenIn: WETH,
            tokenOut: USDC,
            fee: 10000,
            recipient: swapper,
            deadline: block.timestamp + 300,
            amountIn: largeAmount,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        vm.prank(swapper);
        uint256 output_1 = router.exactInputSingle(params_1);

        emit log_named_string("Large Trade (100 ETH)", "Fee Tier Comparison");
        emit log_named_uint("0.05% Output (USDC)", output_005 / 1e6);
        emit log_named_uint("1% Output (USDC)", output_1 / 1e6);

        // Calculate fee savings
        uint256 feeDiff = largeAmount * (100 - 5) / 10000; // 0.95% difference
        emit log_named_uint("Fee Difference (ETH)", feeDiff);
        emit log_named_uint("Actual Output Diff (USDC)", (output_005 - output_1) / 1e6);

        // 0.05% should give significantly more output due to lower fees
        // (Assuming both pools have sufficient liquidity)
        if (output_005 > output_1) {
            uint256 advantage = ((output_005 - output_1) * 10000) / output_1;
            emit log_named_uint("0.05% Advantage (bps)", advantage);
        }
    }

    /**
     * @notice Compare liquidity depth across fee tiers
     * @dev Higher liquidity = lower price impact
     */
    function test_highFeeTierBetterLiquidity() public {
        // Query liquidity from each fee tier
        uint128 liquidity_005 = getV3Liquidity(WETH_USDC_V3_005);
        uint128 liquidity_03 = getV3Liquidity(WETH_USDC_V3_03);
        uint128 liquidity_1 = getV3Liquidity(WETH_USDC_V3_1);

        emit log_named_string("Liquidity Comparison", "WETH/USDC Pools");
        emit log_named_uint("0.05% Liquidity", liquidity_005);
        emit log_named_uint("0.3% Liquidity", liquidity_03);
        emit log_named_uint("1% Liquidity", liquidity_1);

        // Calculate liquidity ratios
        uint256 total = uint256(liquidity_005) + uint256(liquidity_03) + uint256(liquidity_1);
        if (total > 0) {
            emit log_named_uint("0.05% Share %", (uint256(liquidity_005) * 100) / total);
            emit log_named_uint("0.3% Share %", (uint256(liquidity_03) * 100) / total);
            emit log_named_uint("1% Share %", (uint256(liquidity_1) * 100) / total);
        }

        // For WETH/USDC, typically:
        // - 0.05% has most liquidity (tightest spreads)
        // - 0.3% has decent liquidity (balanced)
        // - 1% has least liquidity (wider spreads, higher risk assets)

        // All pools should have some liquidity
        assertGt(liquidity_005, 0, "0.05% should have liquidity");
        assertGt(liquidity_03, 0, "0.3% should have liquidity");
    }

    /**
     * @notice Test algorithm for selecting optimal fee tier
     * @dev Based on trade size and liquidity, determine best tier
     */
    function test_optimalFeeTierSelection() public {
        // Test various trade sizes
        uint256[] memory tradeSizes = new uint256[](4);
        tradeSizes[0] = 0.1 ether;
        tradeSizes[1] = 1 ether;
        tradeSizes[2] = 10 ether;
        tradeSizes[3] = 100 ether;

        // Get liquidity for each tier
        uint128 liquidity_005 = getV3Liquidity(WETH_USDC_V3_005);
        uint128 liquidity_03 = getV3Liquidity(WETH_USDC_V3_03);
        uint128 liquidity_1 = getV3Liquidity(WETH_USDC_V3_1);

        emit log_named_string("Optimal Fee Tier Selection", "Algorithm");

        for (uint256 i = 0; i < tradeSizes.length; i++) {
            uint256 tradeSize = tradeSizes[i];

            // Calculate trade as % of liquidity for each tier
            uint256 impact_005 = (tradeSize * 100) / uint256(liquidity_005);
            uint256 impact_03 = (tradeSize * 100) / uint256(liquidity_03);
            uint256 impact_1 = (tradeSize * 100) / uint256(liquidity_1);

            emit log_named_uint("Trade Size (ETH)", tradeSize / 1e18);
            emit log_named_uint("  0.05% Impact %", impact_005);
            emit log_named_uint("  0.3% Impact %", impact_03);
            emit log_named_uint("  1% Impact %", impact_1);

            // Selection algorithm:
            // 1. If 0.05% pool has enough liquidity (trade < 5% of pool), use it (lowest fees)
            // 2. Else if 0.3% pool has enough liquidity, use it
            // 3. Else use 1% pool
            // 4. Also consider: if price impact difference > fee difference, choose lower impact

            string memory recommended;
            if (impact_005 < 5) {
                recommended = "0.05% (low fees, sufficient liquidity)";
            } else if (impact_03 < 10) {
                recommended = "0.3% (balanced)";
            } else if (impact_1 < 20) {
                recommended = "1% (high impact, avoid if possible)";
            } else {
                recommended = "Split trade or wait (excessive impact)";
            }

            emit log_named_string("  Recommended", recommended);
        }

        // Key Learning: For vault implementation
        // - Small swaps (< 5% of 0.05% pool liquidity): Use 0.05%
        // - Medium swaps: Use 0.3%
        // - Large swaps: Split across pools or multiple blocks
        // - Always compare quoted outputs, don't just use heuristics
    }
}
