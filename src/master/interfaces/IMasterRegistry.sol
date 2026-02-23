// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IMasterRegistry
 * @notice Interface for the Master Registry contract
 */
interface IMasterRegistry {
    struct FactoryInfo {
        address factoryAddress;
        uint256 factoryId;
        string contractType;
        string title;
        string displayTitle;
        string metadataURI;
        bytes32[] features;
        address creator;
        bool active;
        uint256 registeredAt;
    }

    struct VaultInfo {
        address vault;
        address creator;
        string name;
        string metadataURI;
        bool active;
        uint256 registeredAt;
        uint256 targetId;
    }

    struct InstanceInfo {
        address instance;
        address factory;
        address creator;
        address[] vaults;      // Append-only. Index 0 = genesis vault. Last = active vault.
        string name;
        string metadataURI;
        bytes32 nameHash;
        uint256 registeredAt;
    }

    // Events
    event FactoryRegistered(
        address indexed factoryAddress,
        uint256 indexed factoryId,
        string contractType
    );

    event FactoryDeactivated(address indexed factoryAddress, uint256 indexed factoryId);

    event InstanceRegistered(
        address indexed instance,
        address indexed factory,
        address indexed creator,
        string name
    );

    event VaultRegistered(
        address indexed vault,
        address indexed creator,
        string name,
        uint256 indexed targetId
    );

    event VaultDeactivated(address indexed vault);

    event InstanceVaultMigrated(address indexed instance, address indexed newVault, uint256 vaultIndex);

    // Functions
    function registerInstance(
        address instance,
        address factory,
        address creator,
        string memory name,
        string memory metadataURI,
        address vault
    ) external;

    function getFactoryInfo(
        uint256 factoryId
    ) external view returns (FactoryInfo memory);

    function getFactoryInfoByAddress(
        address factoryAddress
    ) external view returns (FactoryInfo memory);

    function getTotalFactories() external view returns (uint256);

    function getInstanceInfo(address instance) external view returns (InstanceInfo memory);

    // Vault Registry Functions
    function registerVault(
        address vault,
        address creator,
        string memory name,
        string memory metadataURI,
        uint256 targetId
    ) external;

    function getVaultInfo(address vault) external view returns (VaultInfo memory);

    function isVaultRegistered(address vault) external view returns (bool);

    function deactivateVault(address vault) external;

    // Factory Management
    function deactivateFactory(address factoryAddress) external;

    // Factory Authorization
    function isInstanceFromApprovedFactory(address instance) external view returns (bool);

    // Instance Registration Check
    function isRegisteredInstance(address instance) external view returns (bool);

    // Namespace Protection
    function isNameTaken(string memory name) external view returns (bool);

    // Instance Vault Migration
    function migrateVault(address instance, address newVault) external;
    function getInstanceVaults(address instance) external view returns (address[] memory);
    function getActiveVault(address instance) external view returns (address);
}
