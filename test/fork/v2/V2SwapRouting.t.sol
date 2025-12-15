// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ForkTestBase } from "../helpers/ForkTestBase.sol";
import { UniswapHelpers } from "../helpers/UniswapHelpers.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// V2Router02 interface
interface IUniswapV2Router02 {
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
 * @title V2SwapRouting
 * @notice Fork tests for executing swaps through Uniswap V2 Router
 * @dev Run with: forge test --mp test/fork/v2/V2SwapRouting.t.sol --fork-url $ETH_RPC_URL -vvv
 *
 * Purpose: Validate assumptions about:
 * - Executing ETH → Token swaps via V2Router02.swapExactETHForTokens()
 * - Slippage protection with minOut parameter
 * - Multi-hop swaps (ETH → USDC → DAI)
 * - Deadline enforcement
 *
 * These tests help us implement _executeV2Swap() in UltraAlignmentVault.sol
 */
contract V2SwapRoutingTest is ForkTestBase {

    IUniswapV2Router02 router;
    address swapper;

    function setUp() public {
        loadAddresses();
        router = IUniswapV2Router02(UNISWAP_V2_ROUTER);
        swapper = testAddress1;

        // Give swapper 100 ETH for testing
        dealETH(swapper, 100 ether);
    }

    /**
     * @notice Test basic ETH → USDC swap via V2 router
     * @dev Verify that swapExactETHForTokens works and returns expected output
     */
    function test_swapExactETHForTokens_success() public {
        uint256 amountIn = 1 ether;
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = USDC;

        // Query expected output before swap
        uint256[] memory expectedAmounts = router.getAmountsOut(amountIn, path);
        uint256 expectedUSDC = expectedAmounts[1];

        // Record initial balances
        uint256 initialETH = swapper.balance;
        uint256 initialUSDC = IERC20(USDC).balanceOf(swapper);

        // Execute swap
        vm.prank(swapper);
        uint256[] memory amounts = router.swapExactETHForTokens{value: amountIn}(
            0, // No slippage protection for this test
            path,
            swapper,
            block.timestamp + 300
        );

        // Verify swap results
        assertEq(amounts[0], amountIn, "Input amount should match");
        assertEq(amounts[1], expectedUSDC, "Output should match getAmountsOut");

        // Verify balances changed correctly
        assertEq(swapper.balance, initialETH - amountIn, "ETH should be spent");
        assertEq(IERC20(USDC).balanceOf(swapper), initialUSDC + amounts[1], "USDC should be received");

        // Verify we got substantial output (at least $1000 worth at reasonable ETH prices)
        assertGt(amounts[1], 1000e6, "Should receive > 1000 USDC for 1 ETH");

        // Log swap details
        emit log_named_uint("ETH In", amountIn);
        emit log_named_uint("USDC Out", amounts[1]);
        emit log_named_uint("Effective Price (USDC per ETH)", amounts[1] / 1e12); // Normalize decimals
    }

    /**
     * @notice Test swap with minOut protection (should succeed)
     * @dev Set reasonable minOut that should be met
     */
    function test_swapExactETHForTokens_withMinOut_success() public {
        uint256 amountIn = 1 ether;
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = USDC;

        // Get expected output
        uint256[] memory expectedAmounts = router.getAmountsOut(amountIn, path);
        uint256 expectedUSDC = expectedAmounts[1];

        // Set minOut to 99% of expected (allowing 1% slippage)
        uint256 minOut = (expectedUSDC * 99) / 100;

        // Execute swap with slippage protection
        vm.prank(swapper);
        uint256[] memory amounts = router.swapExactETHForTokens{value: amountIn}(
            minOut,
            path,
            swapper,
            block.timestamp + 300
        );

        // Verify we got at least minOut
        assertGe(amounts[1], minOut, "Should receive at least minOut");

        // Log results
        emit log_named_uint("Expected USDC", expectedUSDC);
        emit log_named_uint("MinOut USDC", minOut);
        emit log_named_uint("Actual USDC", amounts[1]);
    }

    /**
     * @notice Test swap with unrealistic minOut (should revert)
     * @dev Set minOut higher than possible output to trigger revert
     */
    function test_swapExactETHForTokens_withMinOut_reverts() public {
        uint256 amountIn = 1 ether;
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = USDC;

        // Set unrealistic minOut (10 million USDC for 1 ETH)
        uint256 unrealisticMinOut = 10_000_000e6;

        // Expect revert with "UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT" or similar
        vm.prank(swapper);
        vm.expectRevert();
        router.swapExactETHForTokens{value: amountIn}(
            unrealisticMinOut,
            path,
            swapper,
            block.timestamp + 300
        );

        // Verify no tokens were transferred
        assertEq(IERC20(USDC).balanceOf(swapper), 0, "No USDC should be received after revert");
    }

    /**
     * @notice Test multi-hop swap: ETH → USDC → DAI
     * @dev Verify that routing through intermediate tokens works
     */
    function test_swapWithMultiHopPath_success() public {
        uint256 amountIn = 1 ether;
        address[] memory path = new address[](3);
        path[0] = WETH;
        path[1] = USDC;
        path[2] = DAI;

        // Query expected output
        uint256[] memory expectedAmounts = router.getAmountsOut(amountIn, path);
        uint256 expectedDAI = expectedAmounts[2];

        // Record initial balances
        uint256 initialDAI = IERC20(DAI).balanceOf(swapper);

        // Execute multi-hop swap
        vm.prank(swapper);
        uint256[] memory amounts = router.swapExactETHForTokens{value: amountIn}(
            0,
            path,
            swapper,
            block.timestamp + 300
        );

        // Verify we got 3 amounts (ETH, USDC, DAI)
        assertEq(amounts.length, 3, "Should have 3 amounts in path");
        assertEq(amounts[0], amountIn, "Input should match");
        assertEq(amounts[2], expectedDAI, "DAI output should match expected");

        // Verify DAI was received
        assertEq(IERC20(DAI).balanceOf(swapper), initialDAI + amounts[2], "DAI should be received");

        // Verify we got substantial DAI (at least 1000 DAI for 1 ETH)
        assertGt(amounts[2], 1000 ether, "Should receive > 1000 DAI for 1 ETH");

        // Log multi-hop details
        emit log_named_uint("ETH In", amounts[0]);
        emit log_named_uint("USDC Intermediate", amounts[1]);
        emit log_named_uint("DAI Out", amounts[2]);

        // Compare to direct swap efficiency
        address[] memory directPath = new address[](2);
        directPath[0] = WETH;
        directPath[1] = DAI;
        uint256[] memory directAmounts = router.getAmountsOut(amountIn, directPath);

        emit log_named_uint("Direct swap would give DAI", directAmounts[1]);
        emit log_named_uint("Multi-hop gave DAI", amounts[2]);

        // Multi-hop might be slightly less efficient due to double fees (0.3% twice)
        // But should be within reasonable range
    }

    /**
     * @notice Test that expired deadline causes revert
     * @dev Deadline enforcement is critical for MEV protection
     */
    function test_swapWithDeadline_reverts() public {
        uint256 amountIn = 1 ether;
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = USDC;

        // Set deadline in the past
        uint256 expiredDeadline = block.timestamp - 1;

        // Expect revert with "UniswapV2Router: EXPIRED" or similar
        vm.prank(swapper);
        vm.expectRevert();
        router.swapExactETHForTokens{value: amountIn}(
            0,
            path,
            swapper,
            expiredDeadline
        );

        // Verify no swap occurred
        assertEq(IERC20(USDC).balanceOf(swapper), 0, "No USDC should be received after deadline revert");
    }

    /**
     * @notice Test getAmountsOut for quote validation
     * @dev Verify that getAmountsOut provides accurate quotes
     */
    function test_getAmountsOut_accuracy() public {
        uint256 amountIn = 1 ether;
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = USDC;

        // Get quote from router
        uint256[] memory amounts = router.getAmountsOut(amountIn, path);

        // Manually calculate expected output from pair reserves
        (uint112 reserve0, uint112 reserve1,) = getV2Reserves(WETH_USDC_V2_PAIR);

        // Determine which reserve is WETH vs USDC
        // We need to check token0 of the pair to know ordering
        (bool success, bytes memory data) = WETH_USDC_V2_PAIR.staticcall(
            abi.encodeWithSignature("token0()")
        );
        require(success, "token0 call failed");
        address token0 = abi.decode(data, (address));

        uint256 manualOutput;
        if (token0 == WETH) {
            // WETH is token0, USDC is token1
            manualOutput = calculateV2Output(amountIn, reserve0, reserve1);
        } else {
            // USDC is token0, WETH is token1
            manualOutput = calculateV2Output(amountIn, reserve1, reserve0);
        }

        // Router quote should match our manual calculation
        assertEq(amounts[1], manualOutput, "Router quote should match manual calculation");

        emit log_named_uint("Router quote", amounts[1]);
        emit log_named_uint("Manual calculation", manualOutput);
    }
}
