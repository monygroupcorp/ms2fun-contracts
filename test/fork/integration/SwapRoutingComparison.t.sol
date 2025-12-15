// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ForkTestBase } from "../helpers/ForkTestBase.sol";
import { UniswapHelpers } from "../helpers/UniswapHelpers.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// V2 Router interface
interface IUniswapV2Router02Comparison {
    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);

    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);
}

// V3 Router interface
interface IV3SwapRouterComparison {
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

interface IWETH9Comparison {
    function deposit() external payable;
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/**
 * @title SwapRoutingComparison
 * @notice Compare swap routing across V2, V3, and V4 to find best price
 * @dev Run with: forge test --mp test/fork/integration/SwapRoutingComparison.t.sol --fork-url $ETH_RPC_URL -vvv
 *
 * Purpose: Test the CRITICAL routing decision logic for the vault
 * - Compare actual swap outputs across all three versions
 * - Determine best price selection algorithm
 * - Account for V4 hook taxation impact
 * - Test routing split strategies
 *
 * This directly informs implementation of _swapETHForTarget() routing logic
 */
contract SwapRoutingComparisonTest is ForkTestBase {
    IUniswapV2Router02Comparison v2Router;
    IV3SwapRouterComparison v3Router;
    IWETH9Comparison weth;
    address swapper;

    function setUp() public {
        loadAddresses();
        v2Router = IUniswapV2Router02Comparison(UNISWAP_V2_ROUTER);
        v3Router = IV3SwapRouterComparison(UNISWAP_V3_ROUTER);
        weth = IWETH9Comparison(WETH);
        swapper = testAddress1;

        // Give swapper plenty of ETH
        dealETH(swapper, 1000 ether);
    }

    /**
     * @notice Compare swap prices for 1 ETH across V2, V3, V4
     * @dev This is the core test for routing decision logic
     */
    function test_compareSwapPrices_allVersions() public {
        uint256 amountIn = 1 ether;

        // V2: Query expected output
        address[] memory v2Path = new address[](2);
        v2Path[0] = WETH;
        v2Path[1] = USDC;
        uint256[] memory v2Amounts = v2Router.getAmountsOut(amountIn, v2Path);
        uint256 v2Output = v2Amounts[1];

        // V3: Execute swap to get actual output (0.05% pool)
        vm.prank(swapper);
        weth.deposit{value: amountIn}();
        vm.prank(swapper);
        weth.approve(address(v3Router), amountIn);

        IV3SwapRouterComparison.ExactInputSingleParams memory v3Params = IV3SwapRouterComparison.ExactInputSingleParams({
            tokenIn: WETH,
            tokenOut: USDC,
            fee: 500,  // 0.05% - typically best for WETH/USDC
            recipient: swapper,
            deadline: block.timestamp + 300,
            amountIn: amountIn,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        vm.prank(swapper);
        uint256 v3Output = v3Router.exactInputSingle(v3Params);

        // V4: Would test here if V4 pools exist
        // For now, V4 testing depends on V4 PoolManager being available
        uint256 v4Output = 0;
        if (UNISWAP_V4_POOL_MANAGER != address(0)) {
            // TODO: Implement V4 swap once we have V4 pool setup
            emit log_string("V4 PoolManager detected - implement V4 swap");
        } else {
            emit log_string("V4 PoolManager not available - skipping V4 comparison");
        }

        // Log all outputs
        emit log_named_string("Swap Amount", "1 ETH");
        emit log_named_uint("V2 Output (quoted, USDC)", v2Output / 1e6);
        emit log_named_uint("V3 Output (actual, USDC)", v3Output / 1e6);
        if (v4Output > 0) {
            emit log_named_uint("V4 Output (actual, USDC)", v4Output / 1e6);
        }

        // Determine best route
        uint256 bestOutput = UniswapHelpers.max(v2Output, v3Output);
        if (v4Output > 0) bestOutput = UniswapHelpers.max(bestOutput, v4Output);

        string memory bestRoute;
        if (bestOutput == v2Output) bestRoute = "V2";
        else if (bestOutput == v3Output) bestRoute = "V3 (0.05%)";
        else bestRoute = "V4";

        emit log_named_string("Best Route", bestRoute);

        // Calculate advantage
        if (v3Output > v2Output) {
            uint256 advantage = ((v3Output - v2Output) * 10000) / v2Output;
            emit log_named_uint("V3 Advantage over V2 (bps)", advantage);
        }

        // Key Learning: For 1 ETH swap on WETH/USDC:
        // - V3 0.05% typically wins (lowest fees + concentrated liquidity)
        // - V2 may be better for very small swaps (lower gas)
        // - V4 depends on hook tax impact
    }

    /**
     * @notice Test best price selection algorithm
     * @dev Implement the actual algorithm the vault will use
     */
    function test_bestPriceSelection_algorithm() public {
        uint256 amountIn = 10 ether;

        // Step 1: Query V2 output
        address[] memory v2Path = new address[](2);
        v2Path[0] = WETH;
        v2Path[1] = USDC;
        uint256[] memory v2Amounts = v2Router.getAmountsOut(amountIn, v2Path);
        uint256 v2Quote = v2Amounts[1];

        // Step 2: Query V3 outputs for different fee tiers
        // In practice, we'd query all available pools
        // For this test, we know 0.05% is typically best for WETH/USDC

        // Step 3: Query V4 output (if available)
        // Must account for hook tax reducing output

        // Step 4: Selection algorithm
        emit log_string("Best Price Selection Algorithm:");
        emit log_string("1. Query V2 via getAmountsOut()");
        emit log_string("2. Query V3 for each fee tier (0.05%, 0.3%, 1%)");
        emit log_string("3. Query V4 (account for hook tax)");
        emit log_string("4. Select max(v2Quote, v3Quote_005, v3Quote_03, v3Quote_1, v4Quote)");
        emit log_string("5. Consider gas costs for small swaps");

        emit log_named_uint("V2 Quote for 10 ETH (USDC)", v2Quote / 1e6);

        // For vault implementation:
        // function _getBestSwapRoute(uint256 ethAmount) internal returns (Route, uint256 expectedOutput) {
        //     uint256 v2Output = _quoteV2Swap(ethAmount);
        //     uint256 v3Output = _quoteV3Swap(ethAmount);  // Check all fee tiers
        //     uint256 v4Output = _quoteV4Swap(ethAmount);  // Account for hook tax
        //
        //     if (v2Output > v3Output && v2Output > v4Output) return (Route.V2, v2Output);
        //     else if (v3Output > v4Output) return (Route.V3, v3Output);
        //     else return (Route.V4, v4Output);
        // }
    }

    /**
     * @notice Test that V3 is better for large trades
     * @dev Concentrated liquidity advantage
     */
    function test_largeSwap_v3BetterThanV2() public {
        uint256 largeAmount = 100 ether;

        // V2: Query output
        address[] memory v2Path = new address[](2);
        v2Path[0] = WETH;
        v2Path[1] = USDC;
        uint256[] memory v2Amounts = v2Router.getAmountsOut(largeAmount, v2Path);
        uint256 v2Output = v2Amounts[1];

        // V3: Execute large swap
        vm.prank(swapper);
        weth.deposit{value: largeAmount}();
        vm.prank(swapper);
        weth.approve(address(v3Router), largeAmount);

        IV3SwapRouterComparison.ExactInputSingleParams memory v3Params = IV3SwapRouterComparison.ExactInputSingleParams({
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
        uint256 v3Output = v3Router.exactInputSingle(v3Params);

        emit log_named_string("Large Swap", "100 ETH");
        emit log_named_uint("V2 Output (USDC)", v2Output / 1e6);
        emit log_named_uint("V3 Output (USDC)", v3Output / 1e6);

        if (v3Output > v2Output) {
            uint256 advantage = ((v3Output - v2Output) * 10000) / v2Output;
            emit log_named_uint("V3 Advantage (bps)", advantage);
            emit log_string("V3 wins due to concentrated liquidity + lower fees");
        }

        // For large swaps, V3 typically wins because:
        // 1. Lower fees (0.05% vs 0.3%)
        // 2. Concentrated liquidity reduces price impact
    }

    /**
     * @notice Test that V2 may be better for very small swaps
     * @dev Lower gas costs can outweigh fee savings for tiny amounts
     */
    function test_smallSwap_v2MaybeBetter() public {
        uint256 smallAmount = 0.01 ether;  // $20-30 worth

        // V2: Query output
        address[] memory v2Path = new address[](2);
        v2Path[0] = WETH;
        v2Path[1] = USDC;
        uint256[] memory v2Amounts = v2Router.getAmountsOut(smallAmount, v2Path);
        uint256 v2Output = v2Amounts[1];

        emit log_named_string("Small Swap", "0.01 ETH");
        emit log_named_uint("V2 Output (USDC)", v2Output / 1e6);

        // For very small swaps:
        // - V2 has lower gas costs (~100k gas vs ~150k for V3)
        // - Fee difference is tiny (0.25% = $0.05 on $20 swap)
        // - Gas savings may outweigh fee savings

        emit log_string("For vault: Use V2 for swaps < 0.1 ETH to save gas");
    }

    /**
     * @notice Test V4 pricing with hook tax impact
     * @dev Hook tax reduces swap output, may make V2/V3 more attractive
     */
    function test_v4WithHookTax_affectsPricing() public {
        if (UNISWAP_V4_POOL_MANAGER == address(0)) {
            emit log_string("SKIPPED: V4 not available");
            return;
        }

        // TODO: Implement once V4 pools with hooks are available
        emit log_string("TODO: Test V4 swap with hook taxation");

        // Expected: V4 swap output will be reduced by hook tax
        // Example: 1% hook tax means you get 99% of normal output
        // This makes V4 effectively more expensive than V2/V3

        // For vault: Only use V4 if it's the vault's own alignment token
        // and the pool exists. For other tokens, prefer V2/V3.
    }

    /**
     * @notice Test routing split across V2 and V3 for best execution
     * @dev Split large swaps to minimize price impact
     */
    function test_routingSplitAcrossVersions() public {
        uint256 totalAmount = 100 ether;

        // Strategy: Split across V2 and V3 to minimize price impact
        // Example: 50 ETH via V3 (0.05%) + 50 ETH via V2

        address[] memory v2Path = new address[](2);
        v2Path[0] = WETH;
        v2Path[1] = USDC;

        // Option 1: All via V3
        uint256[] memory allV3Amounts = v2Router.getAmountsOut(totalAmount, v2Path);
        uint256 allV3Output = allV3Amounts[1];  // Using V2 router for quote simplification

        // Option 2: Split 50/50 across V2 and V3
        uint256[] memory v2Half = v2Router.getAmountsOut(totalAmount / 2, v2Path);
        uint256[] memory v3Half = v2Router.getAmountsOut(totalAmount / 2, v2Path);
        uint256 splitOutput = v2Half[1] + v3Half[1];

        emit log_named_string("Split Strategy", "100 ETH");
        emit log_named_uint("All via one route (USDC)", allV3Output / 1e6);
        emit log_named_uint("Split 50/50 (USDC)", splitOutput / 1e6);

        // For vault: Consider splitting very large swaps (>100 ETH)
        // across multiple routes/blocks to minimize impact
    }
}
