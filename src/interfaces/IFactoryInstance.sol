// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IFactoryInstance
/// @notice Minimal interface every factory-deployed instance must implement.
///         The MasterRegistry verifies vault() at registration time.
interface IFactoryInstance {
    /// @notice Returns the vault address this instance is aligned to
    /// @return The vault contract address (must be non-zero and deployed)
    function vault() external view returns (address);
}
