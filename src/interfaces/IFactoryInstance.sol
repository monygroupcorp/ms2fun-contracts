// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IFactoryInstance
/// @notice Minimal interface every factory-deployed instance must implement.
///         The MasterRegistry verifies vault() and protocolTreasury() at registration time.
interface IFactoryInstance {
    /// @notice Returns the vault address this instance is aligned to
    /// @return The vault contract address (must be non-zero and deployed)
    function vault() external view returns (address);

    /// @notice Returns the protocol treasury address for fee routing
    /// @return The treasury contract address (must be non-zero)
    function protocolTreasury() external view returns (address);

    /// @notice Returns the global message registry address
    /// @return The registry contract address
    function getGlobalMessageRegistry() external view returns (address);
}
