// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title GlobalMessageTypes
 * @notice Constants for factory types and action types in the global messaging system
 */
library GlobalMessageTypes {
    // ┌─────────────────────────┐
    // │     Factory Types       │
    // └─────────────────────────┘

    /// @notice ERC404 bonding curve factory
    uint8 internal constant FACTORY_ERC404 = 0;

    /// @notice ERC1155 open edition factory
    uint8 internal constant FACTORY_ERC1155 = 1;

    // Reserve 2-255 for future factory types

    // ┌─────────────────────────┐
    // │      Action Types       │
    // └─────────────────────────┘

    /// @notice Buy tokens from bonding curve (ERC404)
    uint8 internal constant ACTION_BUY = 0;

    /// @notice Sell tokens to bonding curve (ERC404)
    uint8 internal constant ACTION_SELL = 1;

    /// @notice Mint edition tokens (ERC1155)
    uint8 internal constant ACTION_MINT = 2;

    /// @notice Creator withdraws proceeds
    uint8 internal constant ACTION_WITHDRAW = 3;

    /// @notice Holder stakes tokens
    uint8 internal constant ACTION_STAKE = 4;

    /// @notice Holder unstakes tokens
    uint8 internal constant ACTION_UNSTAKE = 5;

    /// @notice Claim vault fee rewards
    uint8 internal constant ACTION_CLAIM_REWARDS = 6;

    /// @notice Deploy liquidity to Uniswap V4
    uint8 internal constant ACTION_DEPLOY_LIQUIDITY = 7;

    // Reserve 8-255 for future action types
}
