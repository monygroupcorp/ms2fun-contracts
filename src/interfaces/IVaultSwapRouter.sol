// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IVaultSwapRouter {
    /// @notice Swap ETH for a target token.
    /// @dev ETH sent via msg.value. Router handles all DEX routing internally.
    ///      Tokens are delivered directly to `recipient` — router never holds them.
    /// @param token Address of the token to receive
    /// @param minOut Minimum tokens to receive (slippage protection)
    /// @param recipient Address to receive the output tokens
    /// @return tokenReceived Amount of tokens received
    function swapETHForToken(
        address token,
        uint256 minOut,
        address recipient
    ) external payable returns (uint256 tokenReceived);

    /// @notice Swap a token for ETH.
    /// @dev Caller must approve exact `amount` to this router before calling.
    ///      ETH is delivered directly to `recipient`.
    /// @param token Address of the token to swap
    /// @param amount Amount of tokens to swap
    /// @param minOut Minimum ETH to receive (slippage protection)
    /// @param recipient Address to receive the ETH
    /// @return ethReceived Amount of ETH received
    function swapTokenForETH(
        address token,
        uint256 amount,
        uint256 minOut,
        address recipient
    ) external returns (uint256 ethReceived);
}
