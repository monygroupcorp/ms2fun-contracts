// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Common interface for all DAO-approved component modules registered in ComponentRegistry.
///         Provides self-describing metadata so frontends can render component information
///         without hardcoding it — the module creator owns and maintains their own metadata.
interface IComponentModule {
    event MetadataURIUpdated(string newURI);

    /// @notice Returns a URI pointing to a JSON metadata document.
    ///         Accepted formats: data:application/json,... or ipfs://...
    ///         Returns empty string if not set — frontends fall back to componentName.
    ///         Expected JSON schema:
    ///         { "name": string, "subtitle": string, "description": string, "badge": string|null }
    ///         All fields optional — frontends fall back gracefully on missing keys.
    function metadataURI() external view returns (string memory);

    /// @notice Update the metadata URI. Callable only by the module owner.
    function setMetadataURI(string calldata uri) external;
}
