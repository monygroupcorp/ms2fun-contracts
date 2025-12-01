// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UUPSUpgradeable} from "solady/utils/UUPSUpgradeable.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {IMasterRegistry} from "./interfaces/IMasterRegistry.sol";
import {MetadataUtils} from "../shared/libraries/MetadataUtils.sol";
import {VaultRegistry} from "../registry/VaultRegistry.sol";
import {FactoryApprovalGovernance} from "../governance/FactoryApprovalGovernance.sol";

/**
 * @title MasterRegistryV1
 * @notice Simplified implementation of the Master Registry contract
 * @dev UUPS upgradeable contract for managing factory registration and instance tracking
 *
 * Phase 1 Scope (MVP):
 * - Factory registration (pre-approved factories only)
 * - Instance tracking and registration
 * - Creator instance lookups
 * - Name collision prevention
 *
 * Deferred to Phase 2 (via separate modules):
 * - Featured tier system → FeaturedTierModule
 * - Vault/hook registry → VaultRegistry
 * - Factory voting → FactoryApprovalGovernance
 *
 * Extension Architecture:
 * This contract maintains integration points (featuredTierModule, governanceModule)
 * to allow seamless Phase 2 upgrades without modifying core registry logic.
 */
contract MasterRegistryV1 is UUPSUpgradeable, Ownable, ReentrancyGuard, IMasterRegistry {
    // Constants
    uint256 public constant APPLICATION_FEE = 0.1 ether;

    // State variables
    uint256 public nextFactoryId;

    // Mappings
    mapping(uint256 => address) public factoryIdToAddress;
    mapping(address => FactoryInfo) public factoryInfo;
    mapping(address => bool) public registeredFactories;
    mapping(bytes32 => bool) public nameHashes; // For name collision prevention
    mapping(address => InstanceInfo) public instanceInfo;
    mapping(address => address[]) public creatorInstances; // creator => instances[]

    // Instance Enumeration (for listing all instances)
    address[] public allInstances; // Array of all registered instances
    mapping(address => uint256) public instanceIndex; // instance address => index in allInstances

    // Featured Tier Tracking (per instance)
    mapping(address => uint256) public instanceFeaturedTier; // instance => tier (0 = not featured, 1-3 = tier level)

    // Phase 2 Registry Contracts
    address public vaultRegistry;
    address public governanceModule;
    address public execToken; // EXEC token for governance voting

    // Vault Registry - Hook is now managed by vault, not MasterRegistry
    mapping(address => IMasterRegistry.VaultInfo) public vaultInfo;
    mapping(address => bool) public registeredVaults;
    address[] public vaultList;
    uint256 public vaultRegistrationFee = 0.05 ether;

    // Featured Tier System
    mapping(uint256 => FeaturedTierInfo) public tierPricing;
    uint256 public basePrice;
    uint256 public tierCount;

    struct FeaturedTierInfo {
        uint256 currentPrice;
        uint256 utilizationRate;
        uint256 demandFactor;
        uint256 lastPurchaseTime;
        uint256 totalPurchases;
    }

    // Extension points for Phase 2 modules
    address public featuredTierModule; // Will call onInstanceRegistered(instance) when enabled

    // Structs
    struct InstanceInfo {
        address instance;
        address factory;
        address creator;
        string name;
        string metadataURI;
        bytes32 nameHash;
        uint256 registeredAt;
    }

    // Events (FactoryRegistered and InstanceRegistered defined in IMasterRegistry)
    event CreatorInstanceAdded(address indexed creator, address indexed instance);
    event FeaturedTierModuleSet(address indexed newModule);
    event GovernanceModuleSet(address indexed newModule);
    event VaultRegistrySet(address indexed newRegistry);
    event TierPricingUpdated(uint256 indexed tierIndex, uint256 newPrice);

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
        require(_owner != address(0), "Invalid owner");
        _setOwner(_owner);
        nextFactoryId = 1;

        // Store EXEC token address
        if (_execToken != address(0)) {
            execToken = _execToken;
        }

        // Initialize vault registration fees
        if (vaultRegistrationFee == 0) {
            vaultRegistrationFee = 0.05 ether;
        }

        // Create governance module if EXEC token is provided and not already set
        if (governanceModule == address(0) && _execToken != address(0)) {
            FactoryApprovalGovernance gov = new FactoryApprovalGovernance();
            // Initialize governance module with EXEC token and this registry
            gov.initialize(_execToken, address(this), _owner);
            governanceModule = address(gov);
        }

        // Initialize featured tier pricing
        basePrice = 0.1 ether;
        tierCount = 3;
        for (uint256 i = 0; i < tierCount; i++) {
            tierPricing[i] = FeaturedTierInfo({
                currentPrice: basePrice * (i + 1),
                utilizationRate: 0,
                demandFactor: 100,
                lastPurchaseTime: 0,
                totalPurchases: 0
            });
        }
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
        require(msg.sender == owner() || msg.sender == governanceModule, "Only owner or governance");
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

        instanceInfo[instance] = InstanceInfo({
            instance: instance,
            factory: factory,
            creator: creator,
            name: name,
            metadataURI: metadataURI,
            nameHash: nameHash,
            registeredAt: block.timestamp
        });

        creatorInstances[creator].push(instance);

        // Track instance in enumeration array
        instanceIndex[instance] = allInstances.length;
        allInstances.push(instance);

        // Initialize featured tier (0 = not featured by default)
        instanceFeaturedTier[instance] = 0;

        // Notify featured tier module if enabled (Phase 2)
        if (featuredTierModule != address(0)) {
            try IFeaturedTierModule(featuredTierModule).onInstanceRegistered(instance) {} catch {}
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
    function getInstanceInfo(address instance) external view returns (InstanceInfo memory) {
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
     * @notice Get total number of instances
     */
    function getTotalInstances() external view returns (uint256) {
        return allInstances.length;
    }

    /**
     * @notice Set featured tier for an instance (owner only)
     * @param instance Instance address
     * @param tier Tier level (0 = not featured, 1-3 = tier level)
     */
    function setInstanceFeaturedTier(address instance, uint256 tier) external onlyOwner {
        require(instanceInfo[instance].instance != address(0), "Instance not found");
        require(tier <= 3, "Invalid tier (0-3 allowed)");
        instanceFeaturedTier[instance] = tier;
    }

    /**
     * @notice Get featured tier for an instance
     * @param instance Instance address
     * @return tier Tier level (0 = not featured, 1-3 = tier level)
     */
    function getInstanceFeaturedTier(address instance) external view returns (uint256) {
        return instanceFeaturedTier[instance];
    }

    /**
     * @notice CRITICAL: Get instances by tier and date with pagination
     * @dev Returns instances STARTING WITH PAID TIER (newest first), then chronologically reverse
     * @param startIndex Index to start from in the sorted results (0-based)
     * @param endIndex Index to end at (exclusive). Returns instances from startIndex to endIndex-1
     * @return instances Array of instance addresses sorted by: tier DESC, then registeredAt DESC
     * @return total Total number of instances that match the criteria
     *
     * Algorithm:
     * 1. Separate instances into two groups: featured (tier >= 1) and non-featured (tier == 0)
     * 2. Sort featured instances by tier DESC, then by registeredAt DESC (newest first)
     * 3. Sort non-featured instances by registeredAt DESC (newest first)
     * 4. Return paginated results with featured instances grafted up front
     *
     * Example: If you have 100 total instances:
     * - Call getInstancesByTierAndDate(0, 10) to get first 10 (highest tier, newest)
     * - Call getInstancesByTierAndDate(10, 20) to get next 10
     * - etc.
     */
    function getInstancesByTierAndDate(uint256 startIndex, uint256 endIndex)
        external
        view
        returns (address[] memory instances, uint256 total)
    {
        require(endIndex > startIndex, "Invalid range");

        uint256 instanceCount = allInstances.length;

        if (instanceCount == 0) {
            return (new address[](0), 0);
        }

        // Create array to track tier and registration time for sorting
        // Structure: we'll sort in two passes - featured first, then non-featured

        address[] memory featured = new address[](instanceCount);
        address[] memory nonFeatured = new address[](instanceCount);
        uint256 featuredCount = 0;
        uint256 nonFeaturedCount = 0;

        // Separate instances into featured and non-featured
        for (uint256 i = 0; i < instanceCount; i++) {
            address inst = allInstances[i];
            if (instanceFeaturedTier[inst] > 0) {
                featured[featuredCount] = inst;
                featuredCount++;
            } else {
                nonFeatured[nonFeaturedCount] = inst;
                nonFeaturedCount++;
            }
        }

        // Sort featured by tier DESC, then by registeredAt DESC (newest first)
        _sortFeaturedByTierAndDate(featured, featuredCount);

        // Sort non-featured by registeredAt DESC (newest first)
        _sortByDate(nonFeatured, nonFeaturedCount);

        // Combine: featured first, then non-featured
        uint256 totalCount = featuredCount + nonFeaturedCount;
        require(endIndex <= totalCount, "End index out of bounds");

        uint256 resultSize = endIndex - startIndex;
        address[] memory result = new address[](resultSize);
        uint256 resultIdx = 0;

        // Fill result array from combined list
        for (uint256 i = startIndex; i < endIndex; i++) {
            if (i < featuredCount) {
                result[resultIdx] = featured[i];
            } else {
                result[resultIdx] = nonFeatured[i - featuredCount];
            }
            resultIdx++;
        }

        return (result, totalCount);
    }

    /**
     * @notice Internal: Sort featured instances by tier DESC, then by registeredAt DESC
     */
    function _sortFeaturedByTierAndDate(address[] memory arr, uint256 len) internal view {
        // Simple bubble sort for featured tier and date
        // Tier DESC, then registeredAt DESC
        for (uint256 i = 0; i < len; i++) {
            for (uint256 j = i + 1; j < len; j++) {
                address instI = arr[i];
                address instJ = arr[j];

                uint256 tierI = instanceFeaturedTier[instI];
                uint256 tierJ = instanceFeaturedTier[instJ];
                uint256 dateI = instanceInfo[instI].registeredAt;
                uint256 dateJ = instanceInfo[instJ].registeredAt;

                // Sort by tier DESC (higher tier first)
                if (tierI < tierJ) {
                    (arr[i], arr[j]) = (arr[j], arr[i]);
                } else if (tierI == tierJ && dateI < dateJ) {
                    // Same tier: sort by date DESC (newer first)
                    (arr[i], arr[j]) = (arr[j], arr[i]);
                }
            }
        }
    }

    /**
     * @notice Internal: Sort instances by registeredAt DESC (newest first)
     */
    function _sortByDate(address[] memory arr, uint256 len) internal view {
        // Simple bubble sort by registeredAt DESC (newest first)
        for (uint256 i = 0; i < len; i++) {
            for (uint256 j = i + 1; j < len; j++) {
                uint256 dateI = instanceInfo[arr[i]].registeredAt;
                uint256 dateJ = instanceInfo[arr[j]].registeredAt;

                if (dateI < dateJ) {
                    (arr[i], arr[j]) = (arr[j], arr[i]);
                }
            }
        }
    }

    /**
     * @notice Set vault registry (Phase 2)
     */
    function setVaultRegistry(address newRegistry) external onlyOwner {
        require(newRegistry != address(0) && newRegistry.code.length > 0, "Invalid registry");
        vaultRegistry = newRegistry;
        emit VaultRegistrySet(newRegistry);
    }

    /**
     * @notice Set featured tier module (Phase 2)
     * @dev This module will be called when instances are registered
     */
    function setFeaturedTierModule(address newModule) external onlyOwner {
        require(newModule == address(0) || newModule.code.length > 0, "Invalid module");
        featuredTierModule = newModule;
        emit FeaturedTierModuleSet(newModule);
    }

    /**
     * @notice Set governance module (Phase 2)
     * @dev This module will handle factory approval voting
     */
    function setGovernanceModule(address newModule) external onlyOwner {
        require(newModule == address(0) || newModule.code.length > 0, "Invalid module");
        governanceModule = newModule;
        emit GovernanceModuleSet(newModule);
    }

    /**
     * @notice Authorize upgrade (UUPS)
     */
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

    function voteOnApplication(address factoryAddress, bool approve) external override {
        require(governanceModule != address(0), "Governance module not set");
        // When called through the proxy directly (not through wrapper), msg.sender is the actual voter
        IFactoryApprovalGovernance(governanceModule).voteOnApplicationWithVoter(factoryAddress, msg.sender, approve);
    }

    function finalizeApplication(address factoryAddress) external override onlyOwner {
        require(governanceModule != address(0), "Governance module not set");
        IFactoryApprovalGovernance(governanceModule).finalizeApplication(factoryAddress);
    }

    function getFactoryApplication(address factoryAddress) external view override returns (FactoryApplication memory) {
        require(governanceModule != address(0), "Governance module not set");
        // Get application from governance module
        IFactoryApprovalGovernance.FactoryApplication memory govApp =
            IFactoryApprovalGovernance(governanceModule).getApplication(factoryAddress);

        // Convert to IMasterRegistry.FactoryApplication
        return FactoryApplication({
            factoryAddress: govApp.factoryAddress,
            applicant: govApp.applicant,
            contractType: govApp.contractType,
            title: govApp.title,
            displayTitle: govApp.displayTitle,
            metadataURI: govApp.metadataURI,
            features: govApp.features,
            status: ApplicationStatus(uint8(govApp.status)),
            applicationFee: govApp.applicationFee,
            createdAt: govApp.createdAt,
            totalVotes: govApp.approvalVotes + govApp.rejectionVotes,
            approvalVotes: govApp.approvalVotes,
            rejectionVotes: govApp.rejectionVotes,
            rejectionReason: govApp.rejectionReason,
            verified: false,
            verificationURI: ""
        });
    }

    // Phase 2 Features - Featured Tier System

    function getCurrentPrice(uint256 tierIndex) external view override returns (uint256) {
        require(tierIndex < tierCount, "Invalid tier index");
        return tierPricing[tierIndex].currentPrice;
    }

    function getTierPricingInfo(uint256 tierIndex) external view override returns (TierPricingInfo memory) {
        require(tierIndex < tierCount, "Invalid tier index");
        FeaturedTierInfo storage tier = tierPricing[tierIndex];
        return TierPricingInfo({
            currentPrice: tier.currentPrice,
            utilizationRate: tier.utilizationRate,
            demandFactor: tier.demandFactor,
            lastPurchaseTime: tier.lastPurchaseTime,
            totalPurchases: tier.totalPurchases
        });
    }

    function purchaseFeaturedPromotion(
        address instance,
        uint256 tierIndex
    ) external payable override nonReentrant {
        require(instanceInfo[instance].instance != address(0), "Instance not registered");
        require(tierIndex >= 1 && tierIndex < tierCount, "Invalid tier index");

        FeaturedTierInfo storage tier = tierPricing[tierIndex];
        uint256 price = tier.currentPrice;

        require(msg.value >= price, "Insufficient payment for tier");

        // Set instance's featured tier
        instanceFeaturedTier[instance] = tierIndex;

        // Update tier pricing
        tier.lastPurchaseTime = block.timestamp;
        tier.totalPurchases++;
        // Simple utilization rate: percentage of total purchases (capped at 100)
        tier.utilizationRate = tier.totalPurchases < 100 ? tier.totalPurchases : 100;
        // Dynamic pricing: increase by 2% per purchase
        tier.currentPrice = (tier.currentPrice * 102) / 100;

        // Refund excess
        if (msg.value > price) {
            payable(msg.sender).transfer(msg.value - price);
        }

        emit FeaturedPromotionPurchased(instance, msg.sender, tierIndex, price);
    }

    // Phase 2 Features - Vault Registry

    function registerVault(
        address vault,
        string memory name,
        string memory metadataURI
    ) external payable override {
        require(vault != address(0), "Invalid vault address");
        require(bytes(name).length > 0 && bytes(name).length <= 256, "Invalid name");
        require(msg.value >= vaultRegistrationFee, "Insufficient registration fee");
        require(!registeredVaults[vault], "Vault already registered");
        require(MetadataUtils.isValidURI(metadataURI), "Invalid metadata URI");
        require(vault.code.length > 0, "Vault must be a contract");

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

        // Refund excess
        if (msg.value > vaultRegistrationFee) {
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

    // Phase 2 Features - Hook Registry

    // Hook registry removed - vaults now manage their own canonical hooks
}

// Interfaces for extension modules
interface IFeaturedTierModule {
    function onInstanceRegistered(address instance) external;
}

interface IFactoryApprovalGovernance {
    enum ApplicationStatus {
        Pending,
        Approved,
        Rejected,
        Withdrawn
    }

    struct FactoryApplication {
        address factoryAddress;
        address applicant;
        string contractType;
        string title;
        string displayTitle;
        string metadataURI;
        bytes32[] features;
        ApplicationStatus status;
        uint256 applicationFee;
        uint256 createdAt;
        uint256 approvalVotes;
        uint256 rejectionVotes;
        string rejectionReason;
    }

    function submitApplication(
        address factoryAddress,
        string memory contractType,
        string memory title,
        string memory displayTitle,
        string memory metadataURI,
        bytes32[] memory features
    ) external payable;

    function submitApplicationWithApplicant(
        address factoryAddress,
        string memory contractType,
        string memory title,
        string memory displayTitle,
        string memory metadataURI,
        bytes32[] memory features,
        address applicant
    ) external payable;

    function voteOnApplication(address factoryAddress, bool approve) external;

    function voteOnApplicationWithVoter(address factoryAddress, address voter, bool approve) external;

    function finalizeApplication(address factoryAddress) external;

    function getApplication(address factoryAddress) external view returns (FactoryApplication memory);
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
