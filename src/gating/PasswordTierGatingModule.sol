// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IGatingModule} from "./IGatingModule.sol";

/// @title PasswordTierGatingModule
/// @notice Singleton gating module for password-protected tier minting.
/// State is keyed by the calling instance address (msg.sender).
/// Any ERC404 bonding instance can use this module.
contract PasswordTierGatingModule is IGatingModule {
    // ── Types ──────────────────────────────────────────────────────────────────

    enum TierType { VOLUME_CAP, TIME_BASED }

    struct TierConfig {
        TierType   tierType;
        bytes32[]  passwordHashes;
        uint256[]  volumeCaps;       // For VOLUME_CAP mode
        uint256[]  tierUnlockTimes;  // For TIME_BASED mode (relative to bondingOpenTime)
    }

    // ── Errors ─────────────────────────────────────────────────────────────────

    error AlreadyConfigured();
    error InvalidPassword();
    error VolumeCapExceeded();
    error TierTimeLocked();
    error InvalidPasswordHash();
    error TierConfigMismatch();

    // ── State (keyed by instance = msg.sender) ─────────────────────────────────

    mapping(address instance => bool)                                    public  configured;
    mapping(address instance => TierConfig)                              private _configs;
    mapping(address instance => mapping(bytes32 => uint256))             private _tierByPasswordHash;
    // slither-disable-next-line uninitialized-state
    mapping(address instance => mapping(address user => uint256))        private _userTierUnlocked;
    mapping(address instance => mapping(address user => uint256))        public  userPurchaseVolume;

    // ── Configuration ──────────────────────────────────────────────────────────

    /// @notice Called by factory right after deploying an instance. One-time per instance.
    /// @dev canMint data encoding: abi.encode(bytes32 passwordHash, uint256 openTime)
    function configureFor(address instance, TierConfig calldata config) external {
        if (configured[instance]) revert AlreadyConfigured();
        if (config.tierType == TierType.VOLUME_CAP
            ? config.volumeCaps.length != config.passwordHashes.length
            : config.tierUnlockTimes.length != config.passwordHashes.length
        ) revert TierConfigMismatch();

        configured[instance] = true;
        _configs[instance] = config;

        for (uint256 i = 0; i < config.passwordHashes.length; i++) {
            if (config.passwordHashes[i] == bytes32(0)) revert InvalidPasswordHash();
            _tierByPasswordHash[instance][config.passwordHashes[i]] = i + 1; // 1-indexed
        }
    }

    // ── IGatingModule ──────────────────────────────────────────────────────────

    /// @dev msg.sender is the calling instance.
    /// @param data abi.encode(bytes32 passwordHash, uint256 openTime)
    ///             passwordHash: bytes32(0) = open tier (no password).
    ///             openTime: instance/edition open timestamp; used by TIME_BASED enforcement.
    // slither-disable-next-line timestamp
    function canMint(address user, uint256 amount, bytes calldata data)
        external override returns (bool allowed, bool permanent)
    {
        TierConfig storage config = _configs[msg.sender];
        (bytes32 passwordHash, uint256 openTime) = abi.decode(data, (bytes32, uint256));

        uint256 tier = passwordHash == bytes32(0) ? 0 : _tierByPasswordHash[msg.sender][passwordHash];
        if (tier == 0 && passwordHash != bytes32(0)) revert InvalidPassword();

        if (config.tierType == TierType.VOLUME_CAP) {
            uint256 cap = tier == 0 ? type(uint256).max : config.volumeCaps[tier - 1];
            if (userPurchaseVolume[msg.sender][user] + amount > cap) revert VolumeCapExceeded();
        } else if (config.tierType == TierType.TIME_BASED && tier > 0) {
            uint256 unlockAt = openTime + config.tierUnlockTimes[tier - 1];
            if (block.timestamp < unlockAt) revert TierTimeLocked();
        }
        allowed = true;
        permanent = false; // PasswordTierGating never self-deactivates
    }

    /// @dev msg.sender is the calling instance.
    function onMint(address user, uint256 amount) external override {
        userPurchaseVolume[msg.sender][user] += amount;
    }

    // ── Views ──────────────────────────────────────────────────────────────────

    function getConfig(address instance) external view returns (TierConfig memory) {
        return _configs[instance];
    }

    function tierByPasswordHash(address instance, bytes32 hash) external view returns (uint256) {
        return _tierByPasswordHash[instance][hash];
    }

    function userTierUnlocked(address instance, address user) external view returns (uint256) {
        return _userTierUnlocked[instance][user];
    }
}
