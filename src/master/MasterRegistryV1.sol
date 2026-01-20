// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UUPSUpgradeable} from "solady/utils/UUPSUpgradeable.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {IMasterRegistry} from "./interfaces/IMasterRegistry.sol";
import {IAlignmentVault} from "../interfaces/IAlignmentVault.sol";
import {MetadataUtils} from "../shared/libraries/MetadataUtils.sol";
import {VaultRegistry} from "../registry/VaultRegistry.sol";
import {FactoryApprovalGovernance} from "../governance/FactoryApprovalGovernance.sol";
import {VaultApprovalGovernance} from "../governance/VaultApprovalGovernance.sol";
import {GlobalMessageRegistry} from "../registry/GlobalMessageRegistry.sol";

/**
 * @title MasterRegistryV1
 * @notice Simplified implementation of the Master Registry contract
 * @dev UUPS upgradeable contract for managing factory registration and instance tracking
 *
 * Core Features:
 * - Factory registration (pre-approved factories only)
 * - Instance tracking and registration
 * - Creator instance lookups
 * - Name collision prevention
 * - Queue-based featured promotion system
 * - Time-based expiration with auto-renewal
 *
 * Additional Modules:
 * - Vault/hook registry → VaultRegistry
 * - Factory voting → FactoryApprovalGovernance
 */
contract MasterRegistryV1 is UUPSUpgradeable, Ownable, ReentrancyGuard, IMasterRegistry {
    // Constants
    uint256 public constant APPLICATION_FEE = 0.1 ether;

    // State variables
    uint256 public nextFactoryId;
    bool private _initialized;

    // Dictator Governance
    address public dictator;
    uint256 public abdicationInitiatedAt;
    uint256 public constant ABDICATION_TIMELOCK = 48 hours;

    // Mappings
    mapping(uint256 => address) public factoryIdToAddress;
    mapping(address => FactoryInfo) public factoryInfo;
    mapping(address => bool) public registeredFactories;
    mapping(bytes32 => bool) public nameHashes; // For name collision prevention
    mapping(address => IMasterRegistry.InstanceInfo) public instanceInfo;
    mapping(address => address[]) public creatorInstances; // creator => instances[]

    // Instance Enumeration (for listing all instances)
    address[] public allInstances; // Array of all registered instances
    mapping(address => uint256) public instanceIndex; // instance address => index in allInstances

    // Phase 2 Registry Contracts
    address public vaultRegistry;
    address public governanceModule;        // Factory approval governance
    address public vaultGovernanceModule;   // Vault approval governance
    address public execToken; // EXEC token for governance voting
    address public globalMessageRegistry; // Global message registry for protocol-wide activity tracking
    address public featuredQueueManager; // Featured queue manager for rental system

    // Vault Registry - Hook is now managed by vault, not MasterRegistry
    mapping(address => IMasterRegistry.VaultInfo) public vaultInfo;
    mapping(address => bool) public registeredVaults;
    address[] public vaultList;
    uint256 public vaultRegistrationFee = 0.05 ether;

    // Vault-to-Instance tracking (for queries and analytics)
    mapping(address => address[]) public vaultInstances; // vault => instances using it

    // Note: Competitive Rental Queue System has been extracted to FeaturedQueueManager

    // Events (FactoryRegistered and InstanceRegistered defined in IMasterRegistry)
    event CreatorInstanceAdded(address indexed creator, address indexed instance);
    event GovernanceModuleSet(address indexed newModule);
    event VaultGovernanceModuleSet(address indexed newModule);
    event VaultRegistrySet(address indexed newRegistry);

    // M-04 Security Fix: Cleanup reward events
    event CleanupRewardRejected(address indexed caller, uint256 rewardAmount);
    event InsufficientCleanupRewardBalance(address indexed caller, uint256 rewardAmount, uint256 contractBalance);

    // Dictator Governance Events
    event AbdicationInitiated(address indexed dictator, uint256 finalizeTime);
    event AbdicationCancelled(address indexed dictator, uint256 timestamp);
    event AbdicationFinalized(uint256 timestamp, address factoryGovernance, address vaultGovernance);

    // Featured Queue Manager Events
    event FeaturedQueueManagerSet(address indexed newManager);

    // Note: All competitive queue events are defined in IMasterRegistry interface

    // Constructor
    constructor() {
        _initializeOwner(msg.sender);
    }

    /**
     * @notice Initialize the contract (supports flexible parameters via low-level call)
     * @dev When called with 1 param: param is owner, execToken = address(0)
     *      When called with 2 params: param1 = execToken, param2 = owner
     *      This function signature must match what tests expect for .selector
     */
    function initialize(address param1, address param2) public {
        // Determine which signature was used based on parameter validity
        // If param2 is address(0), assume single-parameter call where param1 = owner
        if (param2 == address(0)) {
            _initializeWithOwner(address(0), param1);
        } else {
            // Two-parameter call: param1 = execToken, param2 = owner
            _initializeWithOwner(param1, param2);
        }
    }

    /**
     * @notice Internal initialize logic
     */
    function _initializeWithOwner(address _execToken, address _owner) internal {
        require(!_initialized, "Already initialized");
        require(_owner != address(0), "Invalid owner");
        require(_execToken != address(0), "EXEC token required");

        _initialized = true;
        _setOwner(_owner);
        dictator = _owner; // Set dictator to owner initially
        nextFactoryId = 1;

        // Store EXEC token address (now required)
        execToken = _execToken;

        // Initialize vault registration fees
        if (vaultRegistrationFee == 0) {
            vaultRegistrationFee = 0.05 ether;
        }

        // Always create factory governance module (EXEC token is required)
        FactoryApprovalGovernance gov = new FactoryApprovalGovernance();
        gov.initialize(_execToken, address(this), _owner);
        governanceModule = address(gov);

        // Always create vault governance module (EXEC token is required)
        VaultApprovalGovernance vaultGov = new VaultApprovalGovernance();
        vaultGov.initialize(_execToken, address(this), _owner);
        vaultGovernanceModule = address(vaultGov);

        // Note: Competitive queue system is now in FeaturedQueueManager
    }

    // ============ Dictator Governance Functions ============

    /**
     * @notice Initiate the abdication process (48-hour timelock)
     * @dev Only callable by dictator. Starts the countdown to permanent power transfer.
     */
    function initiateAbdication() external {
        require(msg.sender == dictator, "Only dictator");
        require(dictator != address(0), "Dictator already abdicated");
        require(abdicationInitiatedAt == 0, "Abdication already initiated");

        abdicationInitiatedAt = block.timestamp;
        emit AbdicationInitiated(dictator, block.timestamp + ABDICATION_TIMELOCK);
    }

    /**
     * @notice Cancel the abdication process during timelock
     * @dev Only callable by dictator during the 48-hour window
     */
    function cancelAbdication() external {
        require(msg.sender == dictator, "Only dictator");
        require(abdicationInitiatedAt > 0, "Abdication not initiated");
        require(block.timestamp < abdicationInitiatedAt + ABDICATION_TIMELOCK, "Timelock elapsed");

        abdicationInitiatedAt = 0;
        emit AbdicationCancelled(dictator, block.timestamp);
    }

    /**
     * @notice Finalize abdication and permanently transfer power to governance
     * @dev Only callable by dictator after 48-hour timelock. Irreversible.
     */
    function finalizeAbdication() external {
        require(msg.sender == dictator, "Only dictator");
        require(abdicationInitiatedAt > 0, "Abdication not initiated");
        require(block.timestamp >= abdicationInitiatedAt + ABDICATION_TIMELOCK, "Timelock not elapsed");

        // Verify governance succession is ready
        require(governanceModule != address(0), "Factory governance not set");
        require(vaultGovernanceModule != address(0), "Vault governance not set");
        require(execToken != address(0), "EXEC token not set");

        address formerDictator = dictator;
        dictator = address(0);

        emit AbdicationFinalized(block.timestamp, governanceModule, vaultGovernanceModule);
    }

    /**
     * @notice Register a factory (direct registration, admin only)
     * @dev In Phase 1, factories are pre-approved and registered by admin.
     *      In Phase 2, factory approval will be via FactoryApprovalGovernance.
     *
     * @param factoryAddress Address of the factory contract
     * @param contractType Type of contract (e.g., "ERC404", "ERC1155")
     * @param title Human-readable title
     * @param displayTitle Display title for UI
     * @param metadataURI URI for metadata
     */
    function registerFactory(
        address factoryAddress,
        string memory contractType,
        string memory title,
        string memory displayTitle,
        string memory metadataURI
    ) external {
        _registerFactoryInternal(factoryAddress, contractType, title, displayTitle, metadataURI, new bytes32[](0), msg.sender);
    }

    function registerFactoryWithFeatures(
        address factoryAddress,
        string memory contractType,
        string memory title,
        string memory displayTitle,
        string memory metadataURI,
        bytes32[] memory features
    ) external {
        _registerFactoryInternal(factoryAddress, contractType, title, displayTitle, metadataURI, features, msg.sender);
    }

    function registerFactoryWithFeaturesAndCreator(
        address factoryAddress,
        string memory contractType,
        string memory title,
        string memory displayTitle,
        string memory metadataURI,
        bytes32[] memory features,
        address creator
    ) external {
        _registerFactoryInternal(factoryAddress, contractType, title, displayTitle, metadataURI, features, creator);
    }

    function _registerFactoryInternal(
        address factoryAddress,
        string memory contractType,
        string memory title,
        string memory displayTitle,
        string memory metadataURI,
        bytes32[] memory features,
        address creator
    ) internal {
        require(msg.sender == dictator || msg.sender == governanceModule, "Only dictator or governance");
        require(factoryAddress != address(0), "Invalid factory address");
        require(bytes(contractType).length > 0, "Invalid contract type");
        require(!registeredFactories[factoryAddress], "Factory already registered");
        require(MetadataUtils.isValidName(title), "Invalid title");
        require(MetadataUtils.isValidURI(metadataURI), "Invalid metadata URI");

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
            creator: creator,
            active: true,
            registeredAt: block.timestamp
        });

        registeredFactories[factoryAddress] = true;

        emit FactoryRegistered(factoryAddress, factoryId, contractType);
    }

    /**
     * @notice Register an instance (called by factory)
     * @param instance Instance address
     * @param factory Factory address
     * @param creator Creator address
     * @param name Instance name
     * @param metadataURI Metadata URI
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
        require(msg.sender == factory, "Only factory can register instance");
        require(instance != address(0), "Invalid instance");
        require(creator != address(0), "Invalid creator");
        require(MetadataUtils.isValidName(name), "Invalid name");
        require(MetadataUtils.isValidURI(metadataURI), "Invalid metadata URI");

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

        creatorInstances[creator].push(instance);

        // Track instance in enumeration array
        instanceIndex[instance] = allInstances.length;
        allInstances.push(instance);

        // Track vault usage if vault is provided and registered
        if (vault != address(0) && registeredVaults[vault]) {
            vaultInstances[vault].push(instance);
            vaultInfo[vault].instanceCount++;
        }

        emit InstanceRegistered(instance, factory, creator, name);
        emit CreatorInstanceAdded(creator, instance);
    }

    /**
     * @notice Get factory info by ID
     */
    function getFactoryInfo(uint256 factoryId) external view returns (FactoryInfo memory) {
        address factoryAddress = factoryIdToAddress[factoryId];
        require(factoryAddress != address(0), "Factory not found");
        return factoryInfo[factoryAddress];
    }

    /**
     * @notice Get factory info by address
     */
    function getFactoryInfoByAddress(address factoryAddress) external view returns (FactoryInfo memory) {
        require(registeredFactories[factoryAddress], "Factory not registered");
        return factoryInfo[factoryAddress];
    }

    /**
     * @notice Get instance info
     */
    function getInstanceInfo(address instance) external view returns (IMasterRegistry.InstanceInfo memory) {
        require(instanceInfo[instance].instance != address(0), "Instance not found");
        return instanceInfo[instance];
    }

    /**
     * @notice Get creator instances
     */
    function getCreatorInstances(address creator) external view returns (address[] memory) {
        return creatorInstances[creator];
    }

    /**
     * @notice Get total number of factories
     */
    function getTotalFactories() external view returns (uint256) {
        return nextFactoryId - 1;
    }

    /**
     * @notice Check if factory is registered
     */
    function isFactoryRegistered(address factory) external view returns (bool) {
        return registeredFactories[factory];
    }

    /**
     * @notice Check if an instance was created by an approved factory
     * @dev Used by GlobalMessageRegistry to auto-authorize instances
     * @param instance Instance address to check
     * @return True if instance was created by a registered factory
     */
    function isInstanceFromApprovedFactory(address instance) external view override returns (bool) {
        IMasterRegistry.InstanceInfo storage info = instanceInfo[instance];
        // Instance must exist and its factory must be registered
        return info.instance != address(0) && registeredFactories[info.factory];
    }

    /**
     * @notice Check if a project name is already taken
     * @dev Used by factories to check name availability before creating instances
     * @param name The project name to check
     * @return True if the name is already taken
     */
    function isNameTaken(string memory name) external view override returns (bool) {
        bytes32 nameHash = MetadataUtils.toNameHash(name);
        return nameHashes[nameHash];
    }

    /**
     * @notice Get total number of instances
     */
    function getTotalInstances() external view returns (uint256) {
        return allInstances.length;
    }

    /**
     * @notice Get instance address by index
     * @param index Index in allInstances array (0-based)
     * @return Instance address at that index
     */
    function getInstanceByIndex(uint256 index) external view returns (address) {
        require(index < allInstances.length, "Index out of bounds");
        return allInstances[index];
    }

    /**
     * @notice Get paginated list of instance addresses
     * @param offset Starting index (0-based)
     * @param limit Maximum number of addresses to return
     * @return instances Array of instance addresses
     */
    function getInstanceAddresses(uint256 offset, uint256 limit)
        external view returns (address[] memory instances)
    {
        uint256 total = allInstances.length;
        if (offset >= total) return new address[](0);

        uint256 end = offset + limit;
        if (end > total) end = total;

        instances = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            instances[i - offset] = allInstances[i];
        }
    }

    // ============ Competitive Rental Queue System ============
    // Note: Queue system extracted to FeaturedQueueManager contract
    // Use featuredQueueManager address to interact with queue functions

    // Phase 2 Features - Vault Registry

    function registerVault(
        address vault,
        string memory name,
        string memory metadataURI
    ) external payable override {
        // Allow dictator for direct registration OR vault governance module after approval
        require(msg.sender == dictator || msg.sender == vaultGovernanceModule, "Only dictator or vault governance");
        require(vault != address(0), "Invalid vault address");
        require(bytes(name).length > 0 && bytes(name).length <= 256, "Invalid name");
        require(!registeredVaults[vault], "Vault already registered");
        require(MetadataUtils.isValidURI(metadataURI), "Invalid metadata URI");
        require(vault.code.length > 0, "Vault must be a contract");

        // Fee only required for direct registration (governance handles fees separately)
        if (msg.sender != vaultGovernanceModule) {
            require(msg.value >= vaultRegistrationFee, "Insufficient registration fee");
        }

        registeredVaults[vault] = true;
        vaultList.push(vault);

        vaultInfo[vault] = IMasterRegistry.VaultInfo({
            vault: vault,
            creator: msg.sender,
            name: name,
            metadataURI: metadataURI,
            active: true,
            registeredAt: block.timestamp,
            instanceCount: 0
        });

        // Refund excess (only for direct registration)
        if (msg.sender != vaultGovernanceModule && msg.value > vaultRegistrationFee) {
            (bool success, ) = payable(msg.sender).call{value: msg.value - vaultRegistrationFee}("");
            require(success, "Refund failed");
        }

        emit VaultRegistered(vault, msg.sender, name, vaultRegistrationFee);
    }

    function getVaultInfo(address vault) external view override returns (VaultInfo memory) {
        require(registeredVaults[vault], "Vault not registered");
        return vaultInfo[vault];
    }

    function getVaultList() external view override returns (address[] memory) {
        return vaultList;
    }

    function isVaultRegistered(address vault) external view override returns (bool) {
        return registeredVaults[vault] && vaultInfo[vault].active;
    }

    function deactivateVault(address vault) external override onlyOwner {
        require(registeredVaults[vault], "Vault not registered");
        vaultInfo[vault].active = false;
        emit VaultDeactivated(vault);
    }

    // ============ Vault Query Functions ============

    /**
     * @notice Get total number of registered vaults
     * @return Total vault count
     */
    function getTotalVaults() external view returns (uint256) {
        return vaultList.length;
    }

    /**
     * @notice Get all instances using a specific vault
     * @param vault Vault address to query
     * @return Array of instance addresses using this vault
     */
    function getInstancesByVault(address vault) external view returns (address[] memory) {
        require(registeredVaults[vault], "Vault not registered");
        return vaultInstances[vault];
    }

    /**
     * @notice Get paginated vault list with full info
     * @param startIndex Starting index (0-based)
     * @param endIndex Ending index (exclusive)
     * @return vaults Array of vault addresses
     * @return infos Array of vault info structs
     * @return total Total number of vaults
     */
    function getVaults(
        uint256 startIndex,
        uint256 endIndex
    ) external view returns (
        address[] memory vaults,
        VaultInfo[] memory infos,
        uint256 total
    ) {
        require(endIndex > startIndex, "Invalid range");
        require(endIndex <= vaultList.length, "End index out of bounds");

        uint256 resultSize = endIndex - startIndex;
        vaults = new address[](resultSize);
        infos = new VaultInfo[](resultSize);

        for (uint256 i = startIndex; i < endIndex; i++) {
            address vault = vaultList[i];
            vaults[i - startIndex] = vault;
            infos[i - startIndex] = vaultInfo[vault];
        }

        return (vaults, infos, vaultList.length);
    }

    /**
     * @notice Get vaults sorted by popularity (most instances)
     * @param limit Maximum number of vaults to return
     * @return vaults Array of vault addresses (sorted by popularity)
     * @return instanceCounts Array of instance counts for each vault
     * @return names Array of vault names
     */
    function getVaultsByPopularity(
        uint256 limit
    ) external view returns (
        address[] memory vaults,
        uint256[] memory instanceCounts,
        string[] memory names
    ) {
        uint256 totalVaults = vaultList.length;
        uint256 resultSize = limit > totalVaults ? totalVaults : limit;

        // Create arrays to sort
        address[] memory allVaults = new address[](totalVaults);
        uint256[] memory allCounts = new uint256[](totalVaults);

        // Populate arrays
        for (uint256 i = 0; i < totalVaults; i++) {
            address vault = vaultList[i];
            allVaults[i] = vault;
            allCounts[i] = vaultInfo[vault].instanceCount;
        }

        // Simple bubble sort (descending by instance count)
        for (uint256 i = 0; i < totalVaults; i++) {
            for (uint256 j = i + 1; j < totalVaults; j++) {
                if (allCounts[j] > allCounts[i]) {
                    // Swap counts
                    uint256 tempCount = allCounts[i];
                    allCounts[i] = allCounts[j];
                    allCounts[j] = tempCount;

                    // Swap addresses
                    address tempAddr = allVaults[i];
                    allVaults[i] = allVaults[j];
                    allVaults[j] = tempAddr;
                }
            }
        }

        // Extract top N
        vaults = new address[](resultSize);
        instanceCounts = new uint256[](resultSize);
        names = new string[](resultSize);

        for (uint256 i = 0; i < resultSize; i++) {
            vaults[i] = allVaults[i];
            instanceCounts[i] = allCounts[i];
            names[i] = vaultInfo[allVaults[i]].name;
        }

        return (vaults, instanceCounts, names);
    }

    /**
     * @notice Get vaults sorted by Total Value Locked (TVL)
     * @dev Queries IAlignmentVault.accumulatedFees() for each vault
     * @param limit Maximum number of vaults to return
     * @return vaults Array of vault addresses (sorted by TVL)
     * @return tvls Array of TVL values for each vault
     * @return names Array of vault names
     */
    function getVaultsByTVL(
        uint256 limit
    ) external view returns (
        address[] memory vaults,
        uint256[] memory tvls,
        string[] memory names
    ) {
        uint256 totalVaults = vaultList.length;
        uint256 resultSize = limit > totalVaults ? totalVaults : limit;

        // Create arrays to sort
        address[] memory allVaults = new address[](totalVaults);
        uint256[] memory allTVLs = new uint256[](totalVaults);

        // Populate arrays by querying each vault's accumulated fees
        for (uint256 i = 0; i < totalVaults; i++) {
            address vault = vaultList[i];
            allVaults[i] = vault;

            // Query vault's TVL (accumulatedFees)
            try IAlignmentVault(payable(vault)).accumulatedFees() returns (uint256 fees) {
                allTVLs[i] = fees;
            } catch {
                // If query fails, TVL is 0
                allTVLs[i] = 0;
            }
        }

        // Simple bubble sort (descending by TVL)
        for (uint256 i = 0; i < totalVaults; i++) {
            for (uint256 j = i + 1; j < totalVaults; j++) {
                if (allTVLs[j] > allTVLs[i]) {
                    // Swap TVLs
                    uint256 tempTVL = allTVLs[i];
                    allTVLs[i] = allTVLs[j];
                    allTVLs[j] = tempTVL;

                    // Swap addresses
                    address tempAddr = allVaults[i];
                    allVaults[i] = allVaults[j];
                    allVaults[j] = tempAddr;
                }
            }
        }

        // Extract top N
        vaults = new address[](resultSize);
        tvls = new uint256[](resultSize);
        names = new string[](resultSize);

        for (uint256 i = 0; i < resultSize; i++) {
            vaults[i] = allVaults[i];
            tvls[i] = allTVLs[i];
            names[i] = vaultInfo[allVaults[i]].name;
        }

        return (vaults, tvls, names);
    }

    // ============ Vault Governance ============

    /**
     * @notice Set factory governance module address
     * @dev Only owner can set the factory governance module
     * @param _governanceModule Address of the FactoryApprovalGovernance contract
     */
    function setGovernanceModule(address _governanceModule) external onlyOwner {
        require(_governanceModule != address(0), "Invalid governance module");
        governanceModule = _governanceModule;
        emit GovernanceModuleSet(_governanceModule);
    }

    /**
     * @notice Set vault governance module address
     * @dev Only owner can set the vault governance module
     * @param _vaultGovernanceModule Address of the VaultApprovalGovernance contract
     */
    function setVaultGovernanceModule(address _vaultGovernanceModule) external onlyOwner {
        require(_vaultGovernanceModule != address(0), "Invalid governance module");
        vaultGovernanceModule = _vaultGovernanceModule;
        emit VaultGovernanceModuleSet(_vaultGovernanceModule);
    }

    /**
     * @notice Apply for vault approval via governance
     * @dev Forwards application to VaultApprovalGovernance module
     * @param vaultAddress Address of the vault contract
     * @param vaultType Type of vault (e.g., "UniswapV4LP", "AaveYield")
     * @param title Human-readable title
     * @param displayTitle Display title for UI
     * @param metadataURI URI for metadata
     * @param features Array of feature identifiers
     */
    function applyForVault(
        address vaultAddress,
        string memory vaultType,
        string memory title,
        string memory displayTitle,
        string memory metadataURI,
        bytes32[] memory features
    ) external payable {
        require(vaultGovernanceModule != address(0), "Vault governance module not set");
        IVaultApprovalGovernance(vaultGovernanceModule).submitApplicationWithApplicant{value: msg.value}(
            vaultAddress,
            vaultType,
            title,
            displayTitle,
            metadataURI,
            features,
            msg.sender
        );
    }

    /**
     * @notice Register an approved vault (called by VaultApprovalGovernance after approval)
     * @dev Only callable by vault governance module
     * @param vaultAddress Address of the approved vault
     * @param vaultType Type of vault
     * @param title Vault title
     * @param displayTitle Display title
     * @param metadataURI Metadata URI
     * @param features Feature identifiers
     * @param creator Original applicant address
     */
    function registerApprovedVault(
        address vaultAddress,
        string memory vaultType,
        string memory title,
        string memory displayTitle,
        string memory metadataURI,
        bytes32[] memory features,
        address creator
    ) external {
        require(msg.sender == vaultGovernanceModule, "Only vault governance module");
        require(vaultAddress != address(0), "Invalid vault address");
        require(!registeredVaults[vaultAddress], "Vault already registered");
        require(MetadataUtils.isValidURI(metadataURI), "Invalid metadata URI");
        require(vaultAddress.code.length > 0, "Vault must be a contract");

        // Register the vault
        registeredVaults[vaultAddress] = true;
        vaultList.push(vaultAddress);

        vaultInfo[vaultAddress] = IMasterRegistry.VaultInfo({
            vault: vaultAddress,
            creator: creator,
            name: title,
            metadataURI: metadataURI,
            active: true,
            registeredAt: block.timestamp,
            instanceCount: 0
        });

        emit VaultRegistered(vaultAddress, creator, title, 0);
    }

    // ============ Global Message Registry ============

    /**
     * @notice Set global message registry address
     * @dev Only owner can set the registry
     * @param _globalMessageRegistry Address of the GlobalMessageRegistry contract
     */
    function setGlobalMessageRegistry(address _globalMessageRegistry) external onlyOwner {
        require(_globalMessageRegistry != address(0), "Invalid registry address");
        globalMessageRegistry = _globalMessageRegistry;
    }

    /**
     * @notice Set featured queue manager address
     * @dev Only owner can set the queue manager
     * @param _featuredQueueManager Address of the FeaturedQueueManager contract
     */
    function setFeaturedQueueManager(address _featuredQueueManager) external onlyOwner {
        require(_featuredQueueManager != address(0), "Invalid manager address");
        featuredQueueManager = _featuredQueueManager;
        emit FeaturedQueueManagerSet(_featuredQueueManager);
    }

    /**
     * @notice Get global message registry address
     * @return Address of the GlobalMessageRegistry contract
     */
    function getGlobalMessageRegistry() external view override returns (address) {
        return globalMessageRegistry;
    }

    // Phase 2 Features - Hook Registry

    // Hook registry removed - vaults now manage their own canonical hooks

    // UUPS Upgrade Authorization
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // Phase 2 Features - Factory Application (Governance)

    function applyForFactory(
        address factoryAddress,
        string memory contractType,
        string memory title,
        string memory displayTitle,
        string memory metadataURI,
        bytes32[] memory features
    ) external payable override {
        require(governanceModule != address(0), "Governance module not set");
        IFactoryApprovalGovernance(governanceModule).submitApplicationWithApplicant{value: msg.value}(
            factoryAddress,
            contractType,
            title,
            displayTitle,
            metadataURI,
            features,
            msg.sender
        );
    }


    function getFactoryApplication(address factoryAddress) external view override returns (FactoryApplication memory) {
        require(governanceModule != address(0), "Governance module not set");

        // Get application data from governance module
        (
            address applicant,
            string memory contractType,
            string memory title,
            ,  // phase
            uint256 phaseDeadline,
            uint256 cumulativeYayRequired,
            uint256 roundCount
        ) = IFactoryApprovalGovernance(governanceModule).getApplication(factoryAddress);

        // For backwards compatibility, we approximate vote counts from latest round
        uint256 approvalVotes = 0;
        uint256 rejectionVotes = 0;
        ApplicationStatus status = ApplicationStatus.Pending;

        if (roundCount > 0) {
            // This is a simplified view - actual voting data is in rounds
            // For detailed info, query FactoryApprovalGovernance directly
            approvalVotes = cumulativeYayRequired;
        }

        // Convert to IMasterRegistry.FactoryApplication
        return FactoryApplication({
            factoryAddress: factoryAddress,
            applicant: applicant,
            contractType: contractType,
            title: title,
            displayTitle: title,
            metadataURI: "",
            features: new bytes32[](0),
            status: status,
            applicationFee: 0.1 ether,
            createdAt: phaseDeadline,
            totalVotes: approvalVotes + rejectionVotes,
            approvalVotes: approvalVotes,
            rejectionVotes: rejectionVotes,
            rejectionReason: "",
            verified: false,
            verificationURI: ""
        });
    }
}

// Interfaces for extension modules
interface IFactoryApprovalGovernance {
    function submitApplicationWithApplicant(
        address factoryAddress,
        string memory contractType,
        string memory title,
        string memory displayTitle,
        string memory metadataURI,
        bytes32[] memory features,
        address applicant
    ) external payable;

    function getApplication(address factoryAddress) external view returns (
        address applicant,
        string memory contractType,
        string memory title,
        uint8 phase,
        uint256 phaseDeadline,
        uint256 cumulativeYayRequired,
        uint256 roundCount
    );
}

interface IVaultApprovalGovernance {
    function submitApplicationWithApplicant(
        address vaultAddress,
        string memory vaultType,
        string memory title,
        string memory displayTitle,
        string memory metadataURI,
        bytes32[] memory features,
        address applicant
    ) external payable;

    function getApplication(address vaultAddress) external view returns (
        address applicant,
        string memory vaultType,
        string memory title,
        uint8 phase,
        uint256 phaseDeadline,
        uint256 cumulativeYayRequired,
        uint256 roundCount
    );
}

interface IVaultRegistry {
    function registerVault(address vault, string memory name, string memory metadataURI) external payable;

    function registerHook(address hook, address vault, string memory name, string memory metadataURI) external payable;

    function getVaultInfo(address vault) external view returns (
        address,
        address,
        string memory,
        string memory,
        bool,
        uint256,
        uint256
    );

    function getHookInfo(address hook) external view returns (
        address,
        address,
        address,
        string memory,
        string memory,
        bool,
        uint256,
        uint256
    );

    function getVaultList() external view returns (address[] memory);

    function getHookList() external view returns (address[] memory);

    function getHooksByVault(address vault) external view returns (address[] memory);

    function isVaultRegistered(address vault) external view returns (bool);

    function isHookRegistered(address hook) external view returns (bool);

    function deactivateVault(address vault) external;

    function deactivateHook(address hook) external;

    function vaultRegistrationFee() external view returns (uint256);

    function hookRegistrationFee() external view returns (uint256);
}

// Data structures (needed by interface)
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
