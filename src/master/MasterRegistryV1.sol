// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UUPSUpgradeable} from "solady/utils/UUPSUpgradeable.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {IMasterRegistry} from "./interfaces/IMasterRegistry.sol";
import {IAlignmentRegistry} from "./interfaces/IAlignmentRegistry.sol";
import {MetadataUtils} from "../shared/libraries/MetadataUtils.sol";
import {IFactoryInstance} from "../interfaces/IFactoryInstance.sol";
import {IFactory} from "../interfaces/IFactory.sol";
import {IInstanceLifecycle} from "../interfaces/IInstanceLifecycle.sol";

/**
 * @title MasterRegistryV1
 * @notice Central registry for factories, instances, and vaults
 * @dev UUPS upgradeable. Owner is the DAO (GrandCentral + Safe).
 *      Alignment target curation is handled by AlignmentRegistryV1.
 */
contract MasterRegistryV1 is UUPSUpgradeable, Ownable, IMasterRegistry {
    // ── Core State ──
    uint256 public nextFactoryId;
    bool private _initialized;

    // ── Factory Registry ──
    mapping(uint256 => address) public factoryIdToAddress;
    mapping(address => FactoryInfo) public factoryInfo;
    mapping(address => bool) public registeredFactories;

    // ── Instance Registry ──
    mapping(address => IMasterRegistry.InstanceInfo) public instanceInfo;
    mapping(bytes32 => bool) public nameHashes;

    // ── Vault Registry ──
    mapping(address => IMasterRegistry.VaultInfo) public vaultInfo;
    mapping(address => bool) public registeredVaults;

    // ── External Modules ──
    IAlignmentRegistry public alignmentRegistry;

    // Events
    event CreatorInstanceAdded(address indexed creator, address indexed instance);

    constructor() {
        _initializeOwner(msg.sender);
    }

    /**
     * @notice Initialize the contract with a single owner (DAO address)
     * @param _owner Address of the DAO or owner
     */
    function initialize(address _owner) public {
        require(!_initialized, "Already initialized");
        require(_owner != address(0), "Invalid owner");

        _initialized = true;
        _setOwner(_owner);
        nextFactoryId = 1;
    }

    // ============ Alignment Registry Wiring ============

    function setAlignmentRegistry(address _alignmentRegistry) external onlyOwner {
        require(_alignmentRegistry != address(0), "Invalid registry");
        alignmentRegistry = IAlignmentRegistry(_alignmentRegistry);
    }

    // ============ Factory Registration ============

    /**
     * @notice Register a factory (admin only)
     */
    function registerFactory(
        address factoryAddress,
        string memory contractType,
        string memory title,
        string memory displayTitle,
        string memory metadataURI,
        bytes32[] memory features
    ) external onlyOwner {
        require(factoryAddress != address(0), "Invalid factory address");
        require(bytes(contractType).length > 0, "Invalid contract type");
        require(!registeredFactories[factoryAddress], "Factory already registered");
        require(MetadataUtils.isValidName(title), "Invalid title");
        require(MetadataUtils.isValidURI(metadataURI), "Invalid metadata URI");

        address factoryCreator = IFactory(factoryAddress).creator();
        require(factoryCreator != address(0), "Factory has no creator");
        address factoryProtocol = IFactory(factoryAddress).protocol();
        require(factoryProtocol != address(0), "Factory has no protocol");

        uint256 factoryId = nextFactoryId++;
        factoryIdToAddress[factoryId] = factoryAddress;

        factoryInfo[factoryAddress] = FactoryInfo({
            factoryAddress: factoryAddress,
            factoryId: factoryId,
            contractType: contractType,
            title: title,
            displayTitle: displayTitle,
            metadataURI: metadataURI,
            features: features,
            creator: factoryCreator,
            active: true,
            registeredAt: block.timestamp
        });

        registeredFactories[factoryAddress] = true;

        emit FactoryRegistered(factoryAddress, factoryId, contractType);
    }

    // ============ Factory Deactivation ============

    function deactivateFactory(address factoryAddress) external override onlyOwner {
        require(registeredFactories[factoryAddress], "Factory not registered");
        require(factoryInfo[factoryAddress].active, "Factory already inactive");
        factoryInfo[factoryAddress].active = false;
        emit FactoryDeactivated(factoryAddress, factoryInfo[factoryAddress].factoryId);
    }

    // ============ Instance Registration ============

    /**
     * @notice Register an instance (called by factory)
     */
    function registerInstance(
        address instance,
        address factory,
        address creator,
        string memory name,
        string memory metadataURI,
        address vault
    ) external override {
        require(registeredFactories[factory], "Factory not registered");
        require(factoryInfo[factory].active, "Factory not active");
        require(msg.sender == factory, "Only factory can register instance");
        require(instance != address(0), "Invalid instance");
        require(creator != address(0), "Invalid creator");
        require(MetadataUtils.isValidName(name), "Invalid name");
        require(MetadataUtils.isValidURI(metadataURI), "Invalid metadata URI");

        address instanceVault = IFactoryInstance(instance).vault();
        require(instanceVault != address(0), "Instance has no vault");
        require(instanceVault == vault, "Vault mismatch");
        require(instanceVault.code.length > 0, "Vault not deployed");

        address instanceTreasury = IFactoryInstance(instance).protocolTreasury();
        require(instanceTreasury != address(0), "Instance has no treasury");

        require(
            IInstanceLifecycle(instance).instanceType() != bytes32(0),
            "Instance must implement IInstanceLifecycle"
        );

        bytes32 nameHash = MetadataUtils.toNameHash(name);
        require(!nameHashes[nameHash], "Name already taken");

        nameHashes[nameHash] = true;

        instanceInfo[instance] = IMasterRegistry.InstanceInfo({
            instance: instance,
            factory: factory,
            creator: creator,
            vault: vault,
            name: name,
            metadataURI: metadataURI,
            nameHash: nameHash,
            registeredAt: block.timestamp
        });

        emit InstanceRegistered(instance, factory, creator, name);
        emit CreatorInstanceAdded(creator, instance);
    }

    // ============ Factory Queries ============

    function getFactoryInfo(uint256 factoryId) external view returns (FactoryInfo memory) {
        address factoryAddress = factoryIdToAddress[factoryId];
        require(factoryAddress != address(0), "Factory not found");
        return factoryInfo[factoryAddress];
    }

    function getFactoryInfoByAddress(address factoryAddress) external view returns (FactoryInfo memory) {
        require(registeredFactories[factoryAddress], "Factory not registered");
        return factoryInfo[factoryAddress];
    }

    function getInstanceInfo(address instance) external view returns (IMasterRegistry.InstanceInfo memory) {
        require(instanceInfo[instance].instance != address(0), "Instance not found");
        return instanceInfo[instance];
    }

    function getTotalFactories() external view returns (uint256) {
        return nextFactoryId - 1;
    }

    function isFactoryRegistered(address factory) external view returns (bool) {
        return registeredFactories[factory];
    }

    function isInstanceFromApprovedFactory(address instance) external view override returns (bool) {
        IMasterRegistry.InstanceInfo storage info = instanceInfo[instance];
        return info.instance != address(0) && registeredFactories[info.factory];
    }

    function isRegisteredInstance(address instance) external view override returns (bool) {
        return instanceInfo[instance].instance != address(0);
    }

    function isNameTaken(string memory name) external view override returns (bool) {
        bytes32 nameHash = MetadataUtils.toNameHash(name);
        return nameHashes[nameHash];
    }

    // ============ Vault Registry ============

    /**
     * @notice Register a vault (callable by active factory or owner)
     * @param vault Vault address
     * @param creator Address credited as vault creator
     * @param name Vault name
     * @param metadataURI Metadata URI
     * @param targetId Alignment target ID
     */
    function registerVault(
        address vault,
        address creator,
        string memory name,
        string memory metadataURI,
        uint256 targetId
    ) external override {
        bool isActiveFactory = registeredFactories[msg.sender] && factoryInfo[msg.sender].active;
        require(isActiveFactory || msg.sender == owner(), "Not authorized");

        require(vault != address(0), "Invalid vault address");
        require(creator != address(0), "Invalid creator");
        require(bytes(name).length > 0 && bytes(name).length <= 256, "Invalid name");
        require(!registeredVaults[vault], "Vault already registered");
        require(MetadataUtils.isValidURI(metadataURI), "Invalid metadata URI");
        require(vault.code.length > 0, "Vault must be a contract");

        // Alignment validation via AlignmentRegistry
        require(alignmentRegistry.isAlignmentTargetActive(targetId), "Target not active");
        address vaultToken = _getVaultAlignmentToken(vault);
        require(alignmentRegistry.isTokenInTarget(targetId, vaultToken), "Token not in target assets");

        registeredVaults[vault] = true;

        vaultInfo[vault] = IMasterRegistry.VaultInfo({
            vault: vault,
            creator: creator,
            name: name,
            metadataURI: metadataURI,
            active: true,
            registeredAt: block.timestamp,
            targetId: targetId
        });

        emit VaultRegistered(vault, creator, name, targetId);
    }

    function getVaultInfo(address vault) external view override returns (VaultInfo memory) {
        require(registeredVaults[vault], "Vault not registered");
        return vaultInfo[vault];
    }

    function isVaultRegistered(address vault) external view override returns (bool) {
        return registeredVaults[vault] && vaultInfo[vault].active;
    }

    function deactivateVault(address vault) external override onlyOwner {
        require(registeredVaults[vault], "Vault not registered");
        vaultInfo[vault].active = false;
        emit VaultDeactivated(vault);
    }

    // ============ Internal Helpers ============

    function _getVaultAlignmentToken(address vault) internal view returns (address) {
        (bool success, bytes memory data) = vault.staticcall(
            abi.encodeWithSignature("alignmentToken()")
        );
        require(success && data.length >= 32, "Vault has no alignment token");
        return abi.decode(data, (address));
    }

    // ============ UUPS ============

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
