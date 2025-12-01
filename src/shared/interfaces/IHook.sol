// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IHook
 * @notice Interface for hook instances that can be registered with ERC404 tokens
 */
interface IHook {
    /**
     * @notice Execute pre-transfer hook logic
     * @param from Address sending tokens
     * @param to Address receiving tokens
     * @param amount Amount of tokens being transferred
     * @return success Whether the hook execution succeeded
     */
    function preTransfer(
        address from,
        address to,
        uint256 amount
    ) external returns (bool success);

    /**
     * @notice Execute post-transfer hook logic
     * @param from Address that sent tokens
     * @param to Address that received tokens
     * @param amount Amount of tokens transferred
     */
    function postTransfer(
        address from,
        address to,
        uint256 amount
    ) external;

    /**
     * @notice Get the vault address this hook pays out to
     * @return vault Address of the vault
     */
    function getVault() external view returns (address vault);

    /**
     * @notice Get accumulated token balance for a specific token
     * @param token Address of the token
     * @return balance Accumulated balance
     */
    function getAccumulatedBalance(address token) external view returns (uint256 balance);
}

