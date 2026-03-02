// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice User-provided identity for any ERC404 factory instance.
struct IdentityParams {
    string  name;
    string  symbol;
    string  styleUri;
    address owner;
    address vault;
    uint256 nftCount;
    uint8   presetId;      // points into LaunchManager.getPreset()
    uint8   creationTier;  // 0=STANDARD, 1=PREMIUM, 2=LAUNCH — maps to LaunchManager.CreationTier
}
