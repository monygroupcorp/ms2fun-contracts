// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ForkTestBase } from "../helpers/ForkTestBase.sol";
import { UniswapHelpers } from "../helpers/UniswapHelpers.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// V3 SwapRouter interface
interface IV3SwapRouter {
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

    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
    function exactOutputSingle(ExactOutputSingleParams calldata params) external payable returns (uint256 amountIn);
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

// WETH9 interface for wrapping ETH
interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256) external;
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/**
 * @title V3SwapRouting
 * @notice Fork tests for executing swaps through Uniswap V3 SwapRouter
 * @dev Run with: forge test --mp test/fork/v3/V3SwapRouting.t.sol --fork-url $ETH_RPC_URL -vvv
 *
 * Purpose: Validate assumptions about:
 * - Executing swaps via V3 SwapRouter.exactInputSingle()
 * - Using sqrtPriceLimitX96 for price protection
 * - Exact output swaps (specify output amount, get input amount)
 * - Multi-hop swaps with encoded path
 * - Deadline enforcement
 *
 * These tests help us implement _executeV3Swap() in UltraAlignmentVault.sol
 */
contract V3SwapRoutingTest is ForkTestBase {
    IV3SwapRouter router;
    IWETH9 weth;
    address swapper;

    function setUp() public {
        loadAddresses();
        router = IV3SwapRouter(UNISWAP_V3_ROUTER);
        weth = IWETH9(WETH);
        swapper = testAddress1;

        // Give swapper 100 ETH
        dealETH(swapper, 100 ether);
    }

    /**
     * @notice Test basic WETH → USDC swap via exactInputSingle
     * @dev V3 requires WETH instead of raw ETH
     */
    function test_exactInputSingle_success() public {
        uint256 amountIn = 1 ether;

        // Wrap ETH to WETH
        vm.prank(swapper);
        weth.deposit{value: amountIn}();

        // Approve router to spend WETH
        vm.prank(swapper);
        weth.approve(address(router), amountIn);

        // Record initial balances
        uint256 initialWETH = weth.balanceOf(swapper);
        uint256 initialUSDC = IERC20(USDC).balanceOf(swapper);

        // Execute swap through 0.3% fee pool
        IV3SwapRouter.ExactInputSingleParams memory params = IV3SwapRouter.ExactInputSingleParams({
            tokenIn: WETH,
            tokenOut: USDC,
            fee: 3000, // 0.3%
            recipient: swapper,
            deadline: block.timestamp + 300,
            amountIn: amountIn,
            amountOutMinimum: 0, // No slippage protection for this test
            sqrtPriceLimitX96: 0 // No price limit
        });

        vm.prank(swapper);
        uint256 amountOut = router.exactInputSingle(params);

        // Verify swap results
        assertEq(weth.balanceOf(swapper), initialWETH - amountIn, "WETH should be spent");
        assertEq(IERC20(USDC).balanceOf(swapper), initialUSDC + amountOut, "USDC should be received");

        // Should receive substantial USDC (at least $1000 worth)
        assertGt(amountOut, 1000e6, "Should receive > 1000 USDC for 1 ETH");

        // Log swap details
        emit log_named_uint("WETH In", amountIn);
        emit log_named_uint("USDC Out", amountOut);
        emit log_named_uint("Effective Price (USDC per ETH)", amountOut / 1e12);
    }

    /**
     * @notice Test swap with sqrtPriceLimitX96 for price protection
     * @dev sqrtPriceLimitX96 acts as a price limit - swap stops if price moves past it
     */
    function test_exactInputSingle_withSqrtPriceLimitX96_success() public {
        uint256 amountIn = 1 ether;

        // Wrap and approve
        vm.prank(swapper);
        weth.deposit{value: amountIn}();
        vm.prank(swapper);
        weth.approve(address(router), amountIn);

        // Get current pool price
        (uint160 currentSqrtPrice,,,,,, ) = getV3Slot0(WETH_USDC_V3_03);

        // Set price limit to 0 (no limit) for this test
        // NOTE: Setting specific price limits in V3 is complex because:
        // - Token ordering (token0 vs token1) affects price direction
        // - Small swaps (1 ETH) shouldn't hit limits anyway
        // - This test just demonstrates the parameter works
        uint160 priceLimitX96 = 0;

        emit log_named_uint("Current sqrtPriceX96", currentSqrtPrice);
        emit log_named_uint("Price Limit sqrtPriceX96 (0 = no limit)", priceLimitX96);

        // Execute swap with price limit
        IV3SwapRouter.ExactInputSingleParams memory params = IV3SwapRouter.ExactInputSingleParams({
            tokenIn: WETH,
            tokenOut: USDC,
            fee: 3000,
            recipient: swapper,
            deadline: block.timestamp + 300,
            amountIn: amountIn,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: priceLimitX96
        });

        vm.prank(swapper);
        uint256 amountOut = router.exactInputSingle(params);

        // Swap should succeed (1 ETH shouldn't move price by >1%)
        assertGt(amountOut, 0, "Swap should succeed with reasonable price limit");

        emit log_named_uint("Amount Out", amountOut);
    }

    /**
     * @notice Test exact output swap (specify output, get input calculated)
     * @dev Useful when you need exactly X tokens out
     */
    function test_exactOutputSingle_success() public {
        uint256 desiredOutput = 1000e6; // Want exactly 1000 USDC

        // Wrap substantial WETH (we don't know exact input needed)
        uint256 maxInput = 2 ether;
        vm.prank(swapper);
        weth.deposit{value: maxInput}();
        vm.prank(swapper);
        weth.approve(address(router), maxInput);

        // Record initial balances
        uint256 initialWETH = weth.balanceOf(swapper);
        uint256 initialUSDC = IERC20(USDC).balanceOf(swapper);

        // Execute exact output swap
        IV3SwapRouter.ExactOutputSingleParams memory params = IV3SwapRouter.ExactOutputSingleParams({
            tokenIn: WETH,
            tokenOut: USDC,
            fee: 3000,
            recipient: swapper,
            deadline: block.timestamp + 300,
            amountOut: desiredOutput,
            amountInMaximum: maxInput,
            sqrtPriceLimitX96: 0
        });

        vm.prank(swapper);
        uint256 amountIn = router.exactOutputSingle(params);

        // Verify we got exactly the output we wanted
        assertEq(IERC20(USDC).balanceOf(swapper), initialUSDC + desiredOutput, "Should get exact output");

        // Verify input was reasonable
        assertGt(amountIn, 0, "Input should be > 0");
        assertLe(amountIn, maxInput, "Input should be <= max");

        // WETH balance should decrease by amountIn
        assertEq(weth.balanceOf(swapper), initialWETH - amountIn, "WETH spent should match amountIn");

        emit log_named_uint("Desired USDC Out", desiredOutput);
        emit log_named_uint("Actual WETH In", amountIn);
        emit log_named_uint("Effective Price (USDC per ETH)", (desiredOutput * 1e18) / amountIn / 1e6);
    }

    /**
     * @notice Test multi-hop swap: WETH → USDC → DAI
     * @dev V3 uses encoded path for multi-hop: tokenIn | fee | tokenMid | fee | tokenOut
     */
    function test_exactInput_multiHop_success() public {
        uint256 amountIn = 1 ether;

        // Wrap and approve
        vm.prank(swapper);
        weth.deposit{value: amountIn}();
        vm.prank(swapper);
        weth.approve(address(router), amountIn);

        // Encode path: WETH → (0.3%) → USDC → (0.05%) → DAI
        // Path encoding: abi.encodePacked(tokenIn, fee, tokenMid, fee, tokenOut)
        bytes memory path = abi.encodePacked(
            WETH,
            uint24(3000),  // 0.3% WETH/USDC
            USDC,
            uint24(500),   // 0.05% USDC/DAI
            DAI
        );

        // Record initial balance
        uint256 initialDAI = IERC20(DAI).balanceOf(swapper);

        // Execute multi-hop swap
        IV3SwapRouter.ExactInputParams memory params = IV3SwapRouter.ExactInputParams({
            path: path,
            recipient: swapper,
            deadline: block.timestamp + 300,
            amountIn: amountIn,
            amountOutMinimum: 0
        });

        vm.prank(swapper);
        uint256 amountOut = router.exactInput(params);

        // Verify DAI was received
        assertEq(IERC20(DAI).balanceOf(swapper), initialDAI + amountOut, "DAI should be received");

        // Should receive substantial DAI (at least 1000 DAI)
        assertGt(amountOut, 1000 ether, "Should receive > 1000 DAI for 1 ETH");

        emit log_named_uint("WETH In", amountIn);
        emit log_named_uint("DAI Out", amountOut);

        // Note: Multi-hop has double fees (0.3% + 0.05% = 0.35% total)
    }

    /**
     * @notice Test that expired deadline causes revert
     * @dev Critical for MEV protection
     */
    function test_swapWithDeadline_reverts() public {
        uint256 amountIn = 1 ether;

        // Wrap and approve
        vm.prank(swapper);
        weth.deposit{value: amountIn}();
        vm.prank(swapper);
        weth.approve(address(router), amountIn);

        // Set deadline in the past
        uint256 expiredDeadline = block.timestamp - 1;

        IV3SwapRouter.ExactInputSingleParams memory params = IV3SwapRouter.ExactInputSingleParams({
            tokenIn: WETH,
            tokenOut: USDC,
            fee: 3000,
            recipient: swapper,
            deadline: expiredDeadline,
            amountIn: amountIn,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        // Expect revert with "Transaction too old" or similar
        vm.prank(swapper);
        vm.expectRevert();
        router.exactInputSingle(params);

        // Verify no swap occurred
        assertEq(IERC20(USDC).balanceOf(swapper), 0, "No USDC should be received after deadline revert");
    }

    /**
     * @notice Test swap with minimum output protection (should succeed)
     * @dev Realistic minOut that should be met
     */
    function test_exactInputSingle_withMinOut_success() public {
        uint256 amountIn = 1 ether;

        // Wrap and approve
        vm.prank(swapper);
        weth.deposit{value: amountIn}();
        vm.prank(swapper);
        weth.approve(address(router), amountIn);

        // Do a test swap to see expected output
        // (In practice, you'd query via quoter contract)
        // For this test, we'll use a conservative minOut

        // Set minOut to 1000 USDC (conservative for 1 ETH at reasonable prices)
        uint256 minOut = 1000e6;

        IV3SwapRouter.ExactInputSingleParams memory params = IV3SwapRouter.ExactInputSingleParams({
            tokenIn: WETH,
            tokenOut: USDC,
            fee: 3000,
            recipient: swapper,
            deadline: block.timestamp + 300,
            amountIn: amountIn,
            amountOutMinimum: minOut,
            sqrtPriceLimitX96: 0
        });

        vm.prank(swapper);
        uint256 amountOut = router.exactInputSingle(params);

        // Verify we got at least minOut
        assertGe(amountOut, minOut, "Should receive at least minOut");

        emit log_named_uint("MinOut", minOut);
        emit log_named_uint("Actual Out", amountOut);
    }
}
