// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/**
 * @title VaultRegistry
 * @notice Simple registry for tracking vaults and hooks
 * @dev Separated from MasterRegistry for single responsibility (Phase 1)
 *
 * This contract manages:
 * - Vault registration and tracking
 * - Hook registration and association with vaults
 * - Basic metadata storage
 *
 * Phase 2 extensions (without code changes):
 * - Vault analytics module
 * - Hook performance tracking
 * - Advanced statistics
 */
contract VaultRegistry is Ownable {
    // Custom Errors
    error InvalidAddress();
    error InvalidName();
    error InsufficientFee();
    error AlreadyRegistered();
    error InvalidMetadataURI();
    error MustBeContract();
    error NotRegistered();
    error FeeMustBePositive();

    // Structs
    struct VaultInfo {
        address vault;
        address creator;
        string name;
        string metadataURI;
        bool active;
        uint256 registeredAt;
    }

    struct HookInfo {
        address hook;
        address creator;
        address vault;
        string name;
        string metadataURI;
        bool active;
        uint256 registeredAt;
    }

    // Constants
    uint256 public constant VAULT_REGISTRATION_FEE = 0.05 ether;
    uint256 public constant HOOK_REGISTRATION_FEE = 0.02 ether;

    // State variables
    uint256 public vaultRegistrationFee;
    uint256 public hookRegistrationFee;

    // Mappings
    mapping(address => VaultInfo) public vaults;
    mapping(address => HookInfo) public hooks;
    mapping(address => bool) public registeredVaults;
    mapping(address => bool) public registeredHooks;

    // Events
    event VaultRegistered(address indexed vault, address indexed creator, string name, uint256 fee);
    event HookRegistered(address indexed hook, address indexed creator, address indexed vault, string name, uint256 fee);
    event VaultDeactivated(address indexed vault);
    event HookDeactivated(address indexed hook);
    event VaultFeeUpdated(uint256 newFee);
    event HookFeeUpdated(uint256 newFee);

    // Constructor
    constructor() {
        _initializeOwner(msg.sender);
        vaultRegistrationFee = VAULT_REGISTRATION_FEE;
        hookRegistrationFee = HOOK_REGISTRATION_FEE;
    }

    /**
     * @notice Register a vault
     * @param vault Address of the vault contract
     * @param name Name of the vault
     * @param metadataURI Metadata URI for the vault
     */
    function registerVault(
        address vault,
        string memory name,
        string memory metadataURI
    ) external payable {
        if (vault == address(0)) revert InvalidAddress();
        if (bytes(name).length == 0 || bytes(name).length > 256) revert InvalidName();
        if (msg.value < vaultRegistrationFee) revert InsufficientFee();
        if (registeredVaults[vault]) revert AlreadyRegistered();
        if (bytes(metadataURI).length == 0 || bytes(metadataURI).length > 2048) revert InvalidMetadataURI();
        // Basic validation that vault is a contract
        if (vault.code.length == 0) revert MustBeContract();

        registeredVaults[vault] = true;

        vaults[vault] = VaultInfo({
            vault: vault,
            creator: msg.sender,
            name: name,
            metadataURI: metadataURI,
            active: true,
            registeredAt: block.timestamp
        });

        // Refund excess
        if (msg.value > vaultRegistrationFee) {
            SafeTransferLib.safeTransferETH(msg.sender, msg.value - vaultRegistrationFee);
        }

        emit VaultRegistered(vault, msg.sender, name, vaultRegistrationFee);
    }

    /**
     * @notice Register a hook
     * @param hook Address of the hook contract
     * @param vault Address of the associated vault
     * @param name Name of the hook
     * @param metadataURI Metadata URI for the hook
     */
    function registerHook(
        address hook,
        address vault,
        string memory name,
        string memory metadataURI
    ) external payable {
        if (hook == address(0)) revert InvalidAddress();
        if (vault == address(0)) revert InvalidAddress();
        if (!registeredVaults[vault]) revert NotRegistered();
        if (bytes(name).length == 0 || bytes(name).length > 256) revert InvalidName();
        if (msg.value < hookRegistrationFee) revert InsufficientFee();
        if (registeredHooks[hook]) revert AlreadyRegistered();
        if (bytes(metadataURI).length == 0 || bytes(metadataURI).length > 2048) revert InvalidMetadataURI();
        // Basic validation that hook is a contract
        if (hook.code.length == 0) revert MustBeContract();

        registeredHooks[hook] = true;

        hooks[hook] = HookInfo({
            hook: hook,
            creator: msg.sender,
            vault: vault,
            name: name,
            metadataURI: metadataURI,
            active: true,
            registeredAt: block.timestamp
        });

        // Refund excess
        if (msg.value > hookRegistrationFee) {
            SafeTransferLib.safeTransferETH(msg.sender, msg.value - hookRegistrationFee);
        }

        emit HookRegistered(hook, msg.sender, vault, name, hookRegistrationFee);
    }

    /**
     * @notice Get vault information
     */
    function getVaultInfo(address vault) external view returns (VaultInfo memory) {
        if (!registeredVaults[vault]) revert NotRegistered();
        return vaults[vault];
    }

    /**
     * @notice Get hook information
     */
    function getHookInfo(address hook) external view returns (HookInfo memory) {
        if (!registeredHooks[hook]) revert NotRegistered();
        return hooks[hook];
    }

    /**
     * @notice Check if vault is registered and active
     */
    function isVaultRegistered(address vault) external view returns (bool) {
        return registeredVaults[vault] && vaults[vault].active;
    }

    /**
     * @notice Check if hook is registered and active
     */
    function isHookRegistered(address hook) external view returns (bool) {
        return registeredHooks[hook] && hooks[hook].active;
    }

    /**
     * @notice Deactivate a vault (owner only)
     */
    function deactivateVault(address vault) external onlyOwner {
        if (!registeredVaults[vault]) revert NotRegistered();
        vaults[vault].active = false;
        emit VaultDeactivated(vault);
    }

    /**
     * @notice Deactivate a hook (owner only)
     */
    function deactivateHook(address hook) external onlyOwner {
        if (!registeredHooks[hook]) revert NotRegistered();
        hooks[hook].active = false;
        emit HookDeactivated(hook);
    }

    /**
     * @notice Set vault registration fee (owner only)
     */
    function setVaultRegistrationFee(uint256 newFee) external onlyOwner {
        if (newFee == 0) revert FeeMustBePositive();
        vaultRegistrationFee = newFee;
        emit VaultFeeUpdated(newFee);
    }

    /**
     * @notice Set hook registration fee (owner only)
     */
    function setHookRegistrationFee(uint256 newFee) external onlyOwner {
        if (newFee == 0) revert FeeMustBePositive();
        hookRegistrationFee = newFee;
        emit HookFeeUpdated(newFee);
    }

}
