// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice User-provided identity for any ERC404 factory instance.
/// Identical across ERC404, ERC404Cypher, and ERC404ZAMM variants.
struct IdentityParams {
    string  name;
    string  symbol;
    string  styleUri;
    address owner;
    address vault;
    uint256 nftCount;
    uint8   profileId;  // 0=small, 1=medium, 2=large
}
