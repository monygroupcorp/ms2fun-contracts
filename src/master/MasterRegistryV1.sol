// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SafeOwnableUUPS} from "../shared/SafeOwnableUUPS.sol";
import {IMasterRegistry} from "./interfaces/IMasterRegistry.sol";
import {IAlignmentRegistry} from "./interfaces/IAlignmentRegistry.sol";
import {IComponentRegistry} from "../registry/interfaces/IComponentRegistry.sol";
import {MetadataUtils} from "../shared/libraries/MetadataUtils.sol";
import {IFactoryInstance} from "../interfaces/IFactoryInstance.sol";
import {IFactory} from "../interfaces/IFactory.sol";
import {IInstanceLifecycle} from "../interfaces/IInstanceLifecycle.sol";

/**
 * @title MasterRegistryV1
 * @notice Central registry for factories, instances, and vaults
 * @dev UUPS upgradeable. Owner is the Safe multisig via Timelock.
 *      Alignment target curation is handled by AlignmentRegistryV1.
 */
contract MasterRegistryV1 is SafeOwnableUUPS, IMasterRegistry {
    // ── Custom Errors ──
    error InvalidAddress();
    error InvalidContractType();
    error InvalidTitle();
    error InvalidName();
    error InvalidMetadataURI();
    error AlreadyRegistered();
    error NotRegistered();
    error FactoryNotActive();
    error FactoryHasNoProtocol();
    error InstanceHasNoVault();
    error VaultMismatch();
    error VaultNotDeployed();
    error InstanceHasNoTreasury();
    error MissingInstanceType();
    error NameAlreadyTaken();
    error TargetNotActive();
    error TokenNotInTarget();
    error VaultMustBeContract();
    error VaultAlreadyInArray();
    error NoVaults();
    error NoAlignmentToken();
    error NotEmergencyRevoker();

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
    IComponentRegistry public componentRegistry;

    // ── Agent Management ──
    mapping(address => bool) public isAgent;
    address public emergencyRevoker;

    /// @notice Tracks revoked instances. Revoked instances are invisible to getInstanceInfo.
    /// @dev Temporary — intended for removal in the next upgrade cycle.
    mapping(address => bool) public revokedInstances;

    // Events
    event AlignmentRegistrySet(address indexed oldRegistry, address indexed newRegistry);
    event CreatorInstanceAdded(address indexed creator, address indexed instance);
    event AgentUpdated(address indexed agent, bool authorized);
    event EmergencyRevokerSet(address indexed oldRevoker, address indexed newRevoker);

    constructor() {
        _initializeOwner(msg.sender);
    }

    /**
     * @notice Initialize the contract with a single owner (DAO address)
     * @param _owner Address of the DAO or owner
     */
    function initialize(address _owner) public {
        if (_initialized) revert AlreadyInitialized();
        if (_owner == address(0)) revert InvalidAddress();

        _initialized = true;
        _setOwner(_owner);
        nextFactoryId = 1;
    }

    // ============ Alignment Registry Wiring ============

    function setAlignmentRegistry(address _alignmentRegistry) external onlyOwner {
        if (_alignmentRegistry == address(0)) revert InvalidAddress();
        address old = address(alignmentRegistry);
        alignmentRegistry = IAlignmentRegistry(_alignmentRegistry);
        emit AlignmentRegistrySet(old, _alignmentRegistry);
    }

    // ============ ComponentRegistry Wiring ============

    function setComponentRegistry(address _componentRegistry) external onlyOwner {
        if (_componentRegistry == address(0)) revert InvalidAddress();
        componentRegistry = IComponentRegistry(_componentRegistry);
        emit ComponentRegistrySet(_componentRegistry);
    }

    // ============ Emergency Revoker Wiring ============

    function setEmergencyRevoker(address _revoker) external onlyOwner {
        address old = emergencyRevoker;
        emergencyRevoker = _revoker;
        emit EmergencyRevokerSet(old, _revoker);
    }

    // ============ Agent Management ============

    /// @notice Authorize or deauthorize a protocol agent (DAO only, via Timelock)
    function setAgent(address agent, bool authorized) external onlyOwner {
        isAgent[agent] = authorized;
        emit AgentUpdated(agent, authorized);
    }

    /// @notice Emergency agent revocation (bypasses Timelock)
    function revokeAgent(address agent) external {
        if (msg.sender != emergencyRevoker) revert NotEmergencyRevoker();
        isAgent[agent] = false;
        emit AgentUpdated(agent, false);
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
        if (factoryAddress == address(0)) revert InvalidAddress();
        if (bytes(contractType).length == 0) revert InvalidContractType();
        if (registeredFactories[factoryAddress]) revert AlreadyRegistered();
        if (!MetadataUtils.isValidName(title)) revert InvalidTitle();
        if (!MetadataUtils.isValidURI(metadataURI)) revert InvalidMetadataURI();

        address factoryProtocol = IFactory(factoryAddress).protocol();
        if (factoryProtocol == address(0)) revert FactoryHasNoProtocol();

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
            creator: address(0),
            active: true,
            registeredAt: block.timestamp
        });

        registeredFactories[factoryAddress] = true;

        emit FactoryRegistered(factoryAddress, factoryId, contractType);
    }

    // ============ Factory Deactivation ============

    function deactivateFactory(address factoryAddress) external override onlyOwner {
        if (!registeredFactories[factoryAddress]) revert NotRegistered();
        if (!factoryInfo[factoryAddress].active) revert FactoryNotActive();
        factoryInfo[factoryAddress].active = false;
        emit FactoryDeactivated(factoryAddress, factoryInfo[factoryAddress].factoryId);
    }

    /// @notice Update the metadata URI for a registered instance.
    ///         Callable by the instance's creator or the registry owner.
    function updateInstanceMetadata(address instance, string calldata uri) external override {
        IMasterRegistry.InstanceInfo storage info = instanceInfo[instance];
        if (info.instance == address(0)) revert NotRegistered();
        if (msg.sender != info.creator && msg.sender != owner()) revert Unauthorized();
        if (!MetadataUtils.isValidURI(uri)) revert InvalidMetadataURI();
        info.metadataURI = uri;
        emit InstanceMetadataUpdated(instance, uri);
    }

    /// @notice Revoke a registered instance, hiding it from getInstanceInfo.
    ///         Owner only. TEMPORARY — intended for removal in the next upgrade cycle.
    ///         Do not rely on this as a permanent censorship mechanism.
    function revokeInstance(address instance) external override onlyOwner {
        if (instanceInfo[instance].instance == address(0)) revert NotRegistered();
        revokedInstances[instance] = true;
        emit InstanceRevoked(instance);
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
        if (!registeredFactories[factory]) revert NotRegistered();
        if (!factoryInfo[factory].active) revert FactoryNotActive();
        if (msg.sender != factory) revert Unauthorized();
        if (instance == address(0)) revert InvalidAddress();
        if (creator == address(0)) revert InvalidAddress();
        if (!MetadataUtils.isValidName(name)) revert InvalidName();
        if (!MetadataUtils.isValidURI(metadataURI)) revert InvalidMetadataURI();

        address instanceVault = IFactoryInstance(instance).vault();
        if (instanceVault == address(0)) revert InstanceHasNoVault();
        if (instanceVault != vault) revert VaultMismatch();
        if (instanceVault.code.length == 0) revert VaultNotDeployed();

        address instanceTreasury = IFactoryInstance(instance).protocolTreasury();
        if (instanceTreasury == address(0)) revert InstanceHasNoTreasury();

        if (IInstanceLifecycle(instance).instanceType() == bytes32(0)) revert MissingInstanceType();

        bytes32 nameHash = MetadataUtils.toNameHash(name);
        if (nameHashes[nameHash]) revert NameAlreadyTaken();

        nameHashes[nameHash] = true;

        address[] memory initialVaults = new address[](1);
        initialVaults[0] = vault;

        instanceInfo[instance] = IMasterRegistry.InstanceInfo({
            instance: instance,
            factory: factory,
            creator: creator,
            vaults: initialVaults,
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
        if (factoryAddress == address(0)) revert NotRegistered();
        return factoryInfo[factoryAddress];
    }

    function getFactoryInfoByAddress(address factoryAddress) external view returns (FactoryInfo memory) {
        if (!registeredFactories[factoryAddress]) revert NotRegistered();
        return factoryInfo[factoryAddress];
    }

    // slither-disable-next-line timestamp
    function getInstanceInfo(address instance) external view returns (IMasterRegistry.InstanceInfo memory) {
        if (instanceInfo[instance].instance == address(0) || revokedInstances[instance]) revert NotRegistered();
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

    // slither-disable-next-line timestamp
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
    // slither-disable-next-line timestamp
    function registerVault(
        address vault,
        address creator,
        string memory name,
        string memory metadataURI,
        uint256 targetId
    ) external override {
        bool isActiveFactory = registeredFactories[msg.sender] && factoryInfo[msg.sender].active;
        if (!isActiveFactory && msg.sender != owner()) revert Unauthorized();

        if (vault == address(0)) revert InvalidAddress();
        if (creator == address(0)) revert InvalidAddress();
        if (bytes(name).length == 0 || bytes(name).length > 256) revert InvalidName();
        if (registeredVaults[vault]) revert AlreadyRegistered();
        if (!MetadataUtils.isValidURI(metadataURI)) revert InvalidMetadataURI();
        if (vault.code.length == 0) revert VaultMustBeContract();

        // Alignment validation via AlignmentRegistry
        if (!alignmentRegistry.isAlignmentTargetActive(targetId)) revert TargetNotActive();
        address vaultToken = _getVaultAlignmentToken(vault);
        if (!alignmentRegistry.isTokenInTarget(targetId, vaultToken)) revert TokenNotInTarget();

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
        if (!registeredVaults[vault]) revert NotRegistered();
        return vaultInfo[vault];
    }

    // slither-disable-next-line timestamp
    function isVaultRegistered(address vault) external view override returns (bool) {
        return registeredVaults[vault] && vaultInfo[vault].active;
    }

    function deactivateVault(address vault) external override onlyOwner {
        if (!registeredVaults[vault]) revert NotRegistered();
        vaultInfo[vault].active = false;
        emit VaultDeactivated(vault);
    }

    // ============ Instance Vault Migration ============

    // slither-disable-next-line timestamp
    function migrateVault(address instance, address newVault) external override {
        if (msg.sender != instance) revert Unauthorized();
        if (instanceInfo[instance].instance == address(0)) revert NotRegistered();
        if (!registeredVaults[newVault] || !vaultInfo[newVault].active) revert FactoryNotActive();

        address[] storage vaults = instanceInfo[instance].vaults;
        uint256 genesisTargetId = vaultInfo[vaults[0]].targetId;
        if (vaultInfo[newVault].targetId != genesisTargetId) revert VaultMismatch();

        for (uint256 i = 0; i < vaults.length; i++) {
            if (vaults[i] == newVault) revert VaultAlreadyInArray();
        }

        vaults.push(newVault);
        emit InstanceVaultMigrated(instance, newVault, vaults.length - 1);
    }

    function getInstanceVaults(address instance) external view override returns (address[] memory) {
        return instanceInfo[instance].vaults;
    }

    function getActiveVault(address instance) external view override returns (address) {
        address[] storage vaults = instanceInfo[instance].vaults;
        if (vaults.length == 0) revert NoVaults();
        return vaults[vaults.length - 1];
    }

    // ============ Internal Helpers ============

    function _getVaultAlignmentToken(address vault) internal view returns (address) {
        (bool success, bytes memory data) = vault.staticcall(
            abi.encodeWithSignature("alignmentToken()")
        );
        if (!success || data.length < 32) revert NoAlignmentToken();
        return abi.decode(data, (address));
    }

}
