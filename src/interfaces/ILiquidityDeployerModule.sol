// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Uniform interface for all ERC404 liquidity deployer modules.
///         Each deployer is pre-configured with its AMM-specific params at construction —
///         the instance only sends the base assets and graduation metadata.
interface ILiquidityDeployerModule {
    struct DeployParams {
        uint256 ethReserve;     // ETH to deploy (also sent as msg.value)
        uint256 tokenReserve;   // ERC404 tokens to deploy (pre-transferred to deployer)
        address protocolTreasury;
        address vault;          // alignment vault (receives 19% of raise)
        address token;          // ERC404 token address
        address instance;       // same as token; benefactor to register with vault
    }

    /// @notice Deploy AMM liquidity. Caller must pre-transfer tokenReserve to this address.
    ///         ETH must equal p.ethReserve exactly via msg.value.
    function deployLiquidity(DeployParams calldata p) external payable;
}
