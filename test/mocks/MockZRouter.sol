// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Mock zRouter for unit testing UltraAlignmentVaultV2
/// Simulates swapVZ (token -> ETH) by pulling token from caller and sending ETH.
contract MockZRouter {
    // Configure: ETH returned per token swap (ratio * swapAmount / 1e18)
    uint256 public ethOutRatio = 1e18; // 1:1 by default

    receive() external payable {}

    function setEthOutRatio(uint256 ratio) external { ethOutRatio = ratio; }

    /// @notice Simulates swapVZ: pulls tokenIn from caller, sends ETH to `to`
    function swapVZ(
        address to,
        bool /*exactOut*/,
        uint256 /*feeOrHook*/,
        address tokenIn,
        address /*tokenOut*/,
        uint256 /*idIn*/,
        uint256 /*idOut*/,
        uint256 swapAmount,
        uint256 /*amountLimit*/,
        uint256 /*deadline*/
    ) external payable returns (uint256 amountIn, uint256 amountOut) {
        amountIn = swapAmount;
        amountOut = swapAmount * ethOutRatio / 1e18;
        // Pull token
        if (tokenIn != address(0)) {
            IERC20(tokenIn).transferFrom(msg.sender, address(this), swapAmount);
        }
        // Send ETH
        require(address(this).balance >= amountOut, "MockZRouter: insufficient ETH");
        payable(to).transfer(amountOut);
    }
}
