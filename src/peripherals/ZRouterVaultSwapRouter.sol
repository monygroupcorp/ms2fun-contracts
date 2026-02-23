// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IVaultSwapRouter} from "../interfaces/IVaultSwapRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IzRouterV4 {
    function swapV4(
        address to,
        bool exactOut,
        uint24 swapFee,
        int24 tickSpace,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) external payable returns (uint256 amountIn, uint256 amountOut);
}

/// @title ZRouterVaultSwapRouter
/// @notice IVaultSwapRouter implementation backed by zRouter's swapV4.
///         Drop-in replacement for UniswapVaultSwapRouter — always routes
///         through the configured V4 pool, no fallback needed.
contract ZRouterVaultSwapRouter is IVaultSwapRouter {
    using SafeERC20 for IERC20;

    address public immutable zRouter;
    uint24  public immutable fee;
    int24   public immutable tickSpacing;

    constructor(address _zRouter, uint24 _fee, int24 _tickSpacing) {
        zRouter = _zRouter;
        fee = _fee;
        tickSpacing = _tickSpacing;
    }

    /// @inheritdoc IVaultSwapRouter
    function swapETHForToken(
        address token,
        uint256 minOut,
        address recipient
    ) external payable override returns (uint256 tokenReceived) {
        (, tokenReceived) = IzRouterV4(zRouter).swapV4{value: msg.value}(
            recipient,
            false,       // exactIn
            fee,
            tickSpacing,
            address(0), // ETH in
            token,
            msg.value,
            minOut,
            type(uint256).max
        );
    }

    /// @inheritdoc IVaultSwapRouter
    function swapTokenForETH(
        address token,
        uint256 amount,
        uint256 minOut,
        address recipient
    ) external override returns (uint256 ethReceived) {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(token).forceApprove(zRouter, amount);
        (, ethReceived) = IzRouterV4(zRouter).swapV4(
            recipient,
            false,       // exactIn
            fee,
            tickSpacing,
            token,
            address(0), // ETH out
            amount,
            minOut,
            type(uint256).max
        );
    }

    receive() external payable {}
}
