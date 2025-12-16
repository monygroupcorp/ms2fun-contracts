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
    // Structs
    struct VaultInfo {
        address vault;
        address creator;
        string name;
        string metadataURI;
        bool active;
        uint256 registeredAt;
        uint256 instanceCount; // For tracking usage
    }

    struct HookInfo {
        address hook;
        address creator;
        address vault;
        string name;
        string metadataURI;
        bool active;
        uint256 registeredAt;
        uint256 instanceCount; // For tracking usage
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
    mapping(address => address[]) public hooksByVault; // vault => hooks[]
    address[] public vaultList;
    address[] public hookList;

    // Extension points for Phase 2
    address public analyticsModule; // Will track vault performance

    // Events
    event VaultRegistered(address indexed vault, address indexed creator, string name, uint256 fee);
    event HookRegistered(address indexed hook, address indexed creator, address indexed vault, string name, uint256 fee);
    event VaultDeactivated(address indexed vault);
    event HookDeactivated(address indexed hook);
    event AnalyticsModuleSet(address indexed newModule);
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
        require(vault != address(0), "Invalid vault address");
        require(bytes(name).length > 0 && bytes(name).length <= 256, "Invalid name");
        require(msg.value >= vaultRegistrationFee, "Insufficient registration fee");
        require(!registeredVaults[vault], "Vault already registered");
        require(bytes(metadataURI).length > 0 && bytes(metadataURI).length <= 2048, "Invalid metadata URI");
        // Basic validation that vault is a contract
        require(vault.code.length > 0, "Vault must be a contract");

        registeredVaults[vault] = true;
        vaultList.push(vault);

        vaults[vault] = VaultInfo({
            vault: vault,
            creator: msg.sender,
            name: name,
            metadataURI: metadataURI,
            active: true,
            registeredAt: block.timestamp,
            instanceCount: 0
        });

        // Refund excess
        require(msg.value >= vaultRegistrationFee, "Insufficient payment");
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
        require(hook != address(0), "Invalid hook address");
        require(vault != address(0), "Invalid vault address");
        require(registeredVaults[vault], "Vault must be registered");
        require(bytes(name).length > 0 && bytes(name).length <= 256, "Invalid name");
        require(msg.value >= hookRegistrationFee, "Insufficient registration fee");
        require(!registeredHooks[hook], "Hook already registered");
        require(bytes(metadataURI).length > 0 && bytes(metadataURI).length <= 2048, "Invalid metadata URI");
        // Basic validation that hook is a contract
        require(hook.code.length > 0, "Hook must be a contract");

        registeredHooks[hook] = true;
        hookList.push(hook);
        hooksByVault[vault].push(hook);

        hooks[hook] = HookInfo({
            hook: hook,
            creator: msg.sender,
            vault: vault,
            name: name,
            metadataURI: metadataURI,
            active: true,
            registeredAt: block.timestamp,
            instanceCount: 0
        });

        // Refund excess
        require(msg.value >= hookRegistrationFee, "Insufficient payment");
        if (msg.value > hookRegistrationFee) {
            SafeTransferLib.safeTransferETH(msg.sender, msg.value - hookRegistrationFee);
        }

        emit HookRegistered(hook, msg.sender, vault, name, hookRegistrationFee);
    }

    /**
     * @notice Get vault information
     */
    function getVaultInfo(address vault) external view returns (VaultInfo memory) {
        require(registeredVaults[vault], "Vault not registered");
        return vaults[vault];
    }

    /**
     * @notice Get hook information
     */
    function getHookInfo(address hook) external view returns (HookInfo memory) {
        require(registeredHooks[hook], "Hook not registered");
        return hooks[hook];
    }

    /**
     * @notice Get all registered vaults
     */
    function getVaultList() external view returns (address[] memory) {
        return vaultList;
    }

    /**
     * @notice Get all registered hooks
     */
    function getHookList() external view returns (address[] memory) {
        return hookList;
    }

    /**
     * @notice Get hooks associated with a vault
     */
    function getHooksByVault(address vault) external view returns (address[] memory) {
        require(registeredVaults[vault], "Vault not registered");
        return hooksByVault[vault];
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
        require(registeredVaults[vault], "Vault not registered");
        vaults[vault].active = false;
        emit VaultDeactivated(vault);
    }

    /**
     * @notice Deactivate a hook (owner only)
     */
    function deactivateHook(address hook) external onlyOwner {
        require(registeredHooks[hook], "Hook not registered");
        hooks[hook].active = false;
        emit HookDeactivated(hook);
    }

    /**
     * @notice Increment vault instance count (called by factory)
     */
    function incrementVaultInstanceCount(address vault) external {
        require(registeredVaults[vault], "Vault not registered");
        vaults[vault].instanceCount++;
    }

    /**
     * @notice Increment hook instance count (called by factory)
     */
    function incrementHookInstanceCount(address hook) external {
        require(registeredHooks[hook], "Hook not registered");
        hooks[hook].instanceCount++;
    }

    /**
     * @notice Set vault registration fee (owner only)
     */
    function setVaultRegistrationFee(uint256 newFee) external onlyOwner {
        require(newFee > 0, "Fee must be positive");
        vaultRegistrationFee = newFee;
        emit VaultFeeUpdated(newFee);
    }

    /**
     * @notice Set hook registration fee (owner only)
     */
    function setHookRegistrationFee(uint256 newFee) external onlyOwner {
        require(newFee > 0, "Fee must be positive");
        hookRegistrationFee = newFee;
        emit HookFeeUpdated(newFee);
    }

    /**
     * @notice Set analytics module (Phase 2)
     */
    function setAnalyticsModule(address newModule) external onlyOwner {
        require(newModule == address(0) || newModule.code.length > 0, "Invalid module");
        analyticsModule = newModule;
        emit AnalyticsModuleSet(newModule);
    }

    /**
     * @notice Get vault count
     */
    function getVaultCount() external view returns (uint256) {
        return vaultList.length;
    }

    /**
     * @notice Get hook count
     */
    function getHookCount() external view returns (uint256) {
        return hookList.length;
    }
}
