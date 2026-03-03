// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {GatingScope} from "../gating/IGatingModule.sol";

/// @notice Free mint configuration passed to factory at instance creation.
struct FreeMintParams {
    uint256 allocation; // NFT count reserved for zero-cost claims (0 = disabled)
    GatingScope scope;  // which entry points the gating module guards
}

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
