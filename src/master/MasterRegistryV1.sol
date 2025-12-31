// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UUPSUpgradeable} from "solady/utils/UUPSUpgradeable.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {IMasterRegistry} from "./interfaces/IMasterRegistry.sol";
import {MetadataUtils} from "../shared/libraries/MetadataUtils.sol";
import {VaultRegistry} from "../registry/VaultRegistry.sol";
import {FactoryApprovalGovernance} from "../governance/FactoryApprovalGovernance.sol";
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

    // Phase 2 Registry Contracts
    address public vaultRegistry;
    address public governanceModule;
    address public execToken; // EXEC token for governance voting
    address public globalMessageRegistry; // Global message registry for protocol-wide activity tracking

    // Vault Registry - Hook is now managed by vault, not MasterRegistry
    mapping(address => IMasterRegistry.VaultInfo) public vaultInfo;
    mapping(address => bool) public registeredVaults;
    address[] public vaultList;
    uint256 public vaultRegistrationFee = 0.05 ether;

    // ============ Competitive Rental Queue System ============
    // Note: RentalSlot and PositionDemand structs defined in IMasterRegistry

    // Featured queue (index 0 = position 1 = front)
    RentalSlot[] public featuredQueue;

    // Quick position lookups (1-indexed, 0 = not in queue)
    mapping(address => uint256) public instancePosition;

    // Per-position competitive pricing
    mapping(uint256 => PositionDemand) public positionDemand;

    // Auto-renewal deposits
    mapping(address => uint256) public renewalDeposits;

    // Configuration parameters
    uint256 public baseRentalPrice = 0.001 ether;
    uint256 public minRentalDuration = 7 days;
    uint256 public maxRentalDuration = 365 days;
    uint256 public demandMultiplier = 120;              // 120% = 20% increase per action
    uint256 public renewalDiscount = 90;                // 90% = 10% discount for renewals
    uint256 public cleanupReward = 0.0001 ether;        // Reward per cleanup action
    uint256 public maxQueueSize = 100;
    uint256 public visibleThreshold = 20;               // Frontend shows top N

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
    event GovernanceModuleSet(address indexed newModule);
    event VaultRegistrySet(address indexed newRegistry);

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

        _initialized = true;
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

        // Initialize competitive queue system
        baseRentalPrice = 0.001 ether;
        minRentalDuration = 7 days;
        maxRentalDuration = 365 days;
        demandMultiplier = 120;
        renewalDiscount = 90;
        cleanupReward = 0.0001 ether;
        maxQueueSize = 100;
        visibleThreshold = 20;
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

        // Authorize instance in global message registry (if set)
        if (globalMessageRegistry != address(0)) {
            GlobalMessageRegistry(globalMessageRegistry).authorizeInstance(instance);
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

    // ============ Competitive Rental Queue System ============

    /**
     * @notice Get competitive rental price for a position
     * @param position 1-indexed position (1 = front)
     * @return price Current rental price for this position
     */
    function getPositionRentalPrice(uint256 position) public view returns (uint256) {
        require(position > 0, "Invalid position");

        // Calculate utilization-adjusted base price
        // Formula: basePrice × (1 + utilization)
        // 0% full = 1x, 50% full = 1.5x, 100% full = 2x
        uint256 queueLength = featuredQueue.length;
        uint256 utilizationBps = (queueLength * 10000) / maxQueueSize;  // Basis points
        uint256 adjustedBase = baseRentalPrice + (baseRentalPrice * utilizationBps) / 10000;

        // Check if position has active rental (competitive bidding)
        if (position <= featuredQueue.length) {
            RentalSlot memory slot = featuredQueue[position - 1];
            if (slot.active && block.timestamp < slot.expiresAt) {
                uint256 competitivePrice = (slot.rentPaid * demandMultiplier) / 100;
                // Use higher of competitive price or adjusted base
                return competitivePrice > adjustedBase ? competitivePrice : adjustedBase;
            }
        }

        // Check demand tracking (past competitive activity)
        PositionDemand memory demand = positionDemand[position];
        if (demand.lastRentalTime > 0) {
            uint256 demandPrice = (demand.lastRentalPrice * demandMultiplier) / 100;
            // Use higher of demand price or adjusted base
            return demandPrice > adjustedBase ? demandPrice : adjustedBase;
        }

        // Return utilization-adjusted base price
        return adjustedBase;
    }

    /**
     * @notice Get current queue utilization metrics
     * @return currentUtilization Utilization in basis points (0-10000)
     * @return adjustedBasePrice Current utilization-adjusted base price
     * @return queueLength Current queue length
     * @return maxSize Maximum queue size
     */
    function getQueueUtilization() external view returns (
        uint256 currentUtilization,
        uint256 adjustedBasePrice,
        uint256 queueLength,
        uint256 maxSize
    ) {
        queueLength = featuredQueue.length;
        maxSize = maxQueueSize;
        currentUtilization = (queueLength * 10000) / maxQueueSize;
        adjustedBasePrice = baseRentalPrice + (baseRentalPrice * currentUtilization) / 10000;

        return (currentUtilization, adjustedBasePrice, queueLength, maxSize);
    }

    /**
     * @notice Calculate total rental cost with duration
     * @param position 1-indexed position
     * @param duration Rental duration in seconds
     * @return totalCost Total cost for this rental
     */
    function calculateRentalCost(
        uint256 position,
        uint256 duration
    ) public view returns (uint256 totalCost) {
        require(duration >= minRentalDuration, "Duration too short");
        require(duration <= maxRentalDuration, "Duration too long");

        uint256 basePrice = getPositionRentalPrice(position);
        uint256 durationMultiplier = duration / minRentalDuration;
        totalCost = basePrice * durationMultiplier;

        // Optional: bulk discount for longer durations
        if (duration >= 30 days) {
            totalCost = (totalCost * 9000) / 10000;  // 10% discount
        } else if (duration >= 14 days) {
            totalCost = (totalCost * 9500) / 10000;  // 5% discount
        }

        return totalCost;
    }

    /**
     * @notice Rent a specific position in the featured queue
     * @param instance Instance to promote
     * @param desiredPosition 1-indexed position (1 = front, N+1 = append to back)
     * @param duration Rental duration in seconds
     */
    function rentFeaturedPosition(
        address instance,
        uint256 desiredPosition,
        uint256 duration
    ) external payable nonReentrant {
        require(instanceInfo[instance].instance != address(0), "Instance not registered");
        require(instancePosition[instance] == 0, "Already in queue - use bumpPosition instead");
        require(desiredPosition > 0, "Invalid position");

        uint256 totalCost = calculateRentalCost(desiredPosition, duration);
        require(msg.value >= totalCost, "Insufficient payment");

        uint256 expiresAt = block.timestamp + duration;

        // Insert and shift everyone down
        _insertAtPositionWithShift(instance, desiredPosition, totalCost, expiresAt);

        // Refund excess
        if (msg.value > totalCost) {
            (bool success, ) = payable(msg.sender).call{value: msg.value - totalCost}("");
            require(success, "Refund failed");
        }

        emit PositionRented(instance, msg.sender, desiredPosition, totalCost, duration, expiresAt);
    }

    /**
     * @notice Get featured instances in queue order
     */
    function getFeaturedInstances(
        uint256 startIndex,
        uint256 endIndex
    ) external view returns (address[] memory instances, uint256 total) {
        require(endIndex > startIndex, "Invalid range");
        require(endIndex <= featuredQueue.length, "End index out of bounds");

        uint256 resultSize = endIndex - startIndex;
        address[] memory result = new address[](resultSize);

        for (uint256 i = startIndex; i < endIndex; i++) {
            result[i - startIndex] = featuredQueue[i].instance;
        }

        return (result, featuredQueue.length);
    }

    /**
     * @notice Get rental info for an instance
     */
    function getRentalInfo(address instance) external view returns (
        RentalSlot memory rental,
        uint256 position,
        uint256 renewalDeposit,
        bool isExpired
    ) {
        uint256 pos = instancePosition[instance];
        RentalSlot memory slot;

        if (pos > 0) {
            slot = featuredQueue[pos - 1];
        }

        return (
            slot,
            pos,
            renewalDeposits[instance],
            pos > 0 && slot.active && block.timestamp >= slot.expiresAt
        );
    }

    /**
     * @notice Deposit funds for auto-renewal
     */
    function depositForAutoRenewal(address instance) external payable nonReentrant {
        uint256 position = instancePosition[instance];
        require(position > 0, "Not in queue");
        require(msg.value > 0, "Must deposit funds");

        RentalSlot memory slot = featuredQueue[position - 1];
        require(
            slot.renter == msg.sender ||
            instanceInfo[instance].creator == msg.sender,
            "Not authorized"
        );

        renewalDeposits[instance] += msg.value;
        emit AutoRenewalDeposited(instance, msg.sender, msg.value);
    }

    /**
     * @notice Withdraw unused auto-renewal deposit
     */
    function withdrawRenewalDeposit(address instance) external nonReentrant {
        uint256 position = instancePosition[instance];

        if (position > 0) {
            RentalSlot memory slot = featuredQueue[position - 1];
            require(
                slot.renter == msg.sender ||
                instanceInfo[instance].creator == msg.sender,
                "Not authorized"
            );
        } else {
            require(instanceInfo[instance].creator == msg.sender, "Not authorized");
        }

        uint256 deposit = renewalDeposits[instance];
        require(deposit > 0, "No deposit to withdraw");

        renewalDeposits[instance] = 0;

        (bool success, ) = payable(msg.sender).call{value: deposit}("");
        require(success, "Transfer failed");

        emit RenewalDepositWithdrawn(instance, msg.sender, deposit);
    }

    /**
     * @notice Renew your current position before it expires
     * @param instance Instance to renew
     * @param additionalDuration Additional time to add (in seconds)
     */
    function renewPosition(
        address instance,
        uint256 additionalDuration
    ) external payable nonReentrant {
        uint256 position = instancePosition[instance];
        require(position > 0, "Not in queue");

        uint256 index = position - 1;
        RentalSlot storage slot = featuredQueue[index];

        require(slot.renter == msg.sender, "Not the renter");
        require(slot.active, "Rental not active");
        require(additionalDuration >= minRentalDuration, "Duration too short");

        // Calculate renewal cost (with discount!)
        uint256 basePrice = getPositionRentalPrice(position);
        uint256 durationMultiplier = additionalDuration / minRentalDuration;
        uint256 renewalCost = (basePrice * durationMultiplier * renewalDiscount) / 100;

        require(msg.value >= renewalCost, "Insufficient payment");

        // Extend expiration
        uint256 newExpiration = slot.expiresAt + additionalDuration;
        require(newExpiration <= block.timestamp + maxRentalDuration, "Total duration too long");

        slot.expiresAt = newExpiration;
        slot.rentPaid += renewalCost;

        // Refund excess
        if (msg.value > renewalCost) {
            (bool success, ) = payable(msg.sender).call{value: msg.value - renewalCost}("");
            require(success, "Refund failed");
        }

        emit PositionRenewed(instance, position, additionalDuration, renewalCost, newExpiration);
    }

    /**
     * @notice Bump your position up in the queue
     * @param instance Your instance that's currently in the queue
     * @param targetPosition Position you want to move to (must be higher than current)
     * @param additionalDuration Additional time to add to your rental (optional, can be 0)
     */
    function bumpPosition(
        address instance,
        uint256 targetPosition,
        uint256 additionalDuration
    ) external payable nonReentrant {
        uint256 currentPosition = instancePosition[instance];
        require(currentPosition > 0, "Not in queue");
        require(targetPosition > 0 && targetPosition < currentPosition, "Invalid target position");

        uint256 currentIndex = currentPosition - 1;
        RentalSlot storage currentSlot = featuredQueue[currentIndex];

        require(currentSlot.renter == msg.sender, "Not your rental");
        require(currentSlot.active, "Rental not active");
        require(block.timestamp < currentSlot.expiresAt, "Rental expired");

        // Get the FULL competitive price (what next person would pay)
        uint256 fullCompetitivePrice = getPositionRentalPrice(targetPosition);

        // Calculate what THIS user pays (with their credit)
        uint256 bumpCost = _calculateBumpCost(currentPosition, targetPosition, additionalDuration);
        require(msg.value >= bumpCost, "Insufficient payment");

        // Update rental details
        currentSlot.rentPaid += bumpCost;
        if (additionalDuration > 0) {
            currentSlot.expiresAt += additionalDuration;
        }

        // Save the moving slot
        RentalSlot memory movingSlot = currentSlot;

        // Shift everyone between target and current position down by 1
        for (uint256 i = currentIndex; i > targetPosition - 1; i--) {
            featuredQueue[i] = featuredQueue[i - 1];

            if (featuredQueue[i].active) {
                instancePosition[featuredQueue[i].instance] = i + 1;
                emit PositionShifted(featuredQueue[i].instance, i, i + 1);
            }
        }

        // Place at target position
        featuredQueue[targetPosition - 1] = movingSlot;
        instancePosition[instance] = targetPosition;

        // Update demand tracking with FULL competitive price
        positionDemand[targetPosition] = PositionDemand({
            lastRentalPrice: fullCompetitivePrice,
            lastRentalTime: block.timestamp,
            totalRentalsAllTime: positionDemand[targetPosition].totalRentalsAllTime + 1
        });

        // Refund excess
        if (msg.value > bumpCost) {
            (bool success, ) = payable(msg.sender).call{value: msg.value - bumpCost}("");
            require(success, "Refund failed");
        }

        emit PositionBumped(instance, currentPosition, targetPosition, bumpCost, additionalDuration);
    }

    /**
     * @notice Clean up expired rentals (incentivized public function)
     * @param maxCleanup Maximum number of slots to process
     */
    function cleanupExpiredRentals(uint256 maxCleanup) external nonReentrant {
        require(maxCleanup > 0 && maxCleanup <= 50, "Invalid cleanup limit");

        uint256 cleanedCount = 0;
        uint256 renewedCount = 0;

        // Scan from back to front
        uint256 i = featuredQueue.length;

        while (i > 0 && (cleanedCount + renewedCount) < maxCleanup) {
            i--;
            RentalSlot storage slot = featuredQueue[i];

            // Only process active slots
            if (!slot.active) continue;

            // Check if expired
            if (block.timestamp >= slot.expiresAt) {
                // Try auto-renewal first
                if (_attemptAutoRenewal(slot.instance, i + 1)) {
                    renewedCount++;
                } else {
                    // No renewal possible, mark as inactive
                    slot.active = false;
                    instancePosition[slot.instance] = 0;
                    cleanedCount++;

                    emit RentalExpired(slot.instance, i + 1, slot.expiresAt);
                }
            }
        }

        // Compact the queue
        _compactQueue();

        // Pay reward to caller
        uint256 totalActions = cleanedCount + renewedCount;
        if (totalActions > 0) {
            uint256 reward = totalActions * cleanupReward;
            (bool success, ) = payable(msg.sender).call{value: reward}("");
            require(success, "Reward payment failed");

            emit CleanupRewardPaid(msg.sender, cleanedCount, renewedCount, reward);
        }
    }

    // ============ Internal Helper Functions ============

    /**
     * @notice Insert at position and shift everyone else down
     */
    function _insertAtPositionWithShift(
        address instance,
        uint256 position,
        uint256 rentPaid,
        uint256 expiresAt
    ) internal {
        uint256 index = position - 1;

        RentalSlot memory newSlot = RentalSlot({
            instance: instance,
            renter: msg.sender,
            rentPaid: rentPaid,
            rentedAt: block.timestamp,
            expiresAt: expiresAt,
            originalPosition: position,
            active: true
        });

        // Case 1: Appending to back (no shifting needed)
        if (position > featuredQueue.length) {
            // Fill any gaps with empty slots if needed
            while (featuredQueue.length < position - 1) {
                featuredQueue.push(RentalSlot({
                    instance: address(0),
                    renter: address(0),
                    rentPaid: 0,
                    rentedAt: 0,
                    expiresAt: 0,
                    originalPosition: 0,
                    active: false
                }));
            }

            featuredQueue.push(newSlot);
            instancePosition[instance] = position;
        }
        // Case 2: Inserting in middle/front - shift everyone down
        else {
            // Add new slot at the end
            featuredQueue.push(RentalSlot({
                instance: address(0),
                renter: address(0),
                rentPaid: 0,
                rentedAt: 0,
                expiresAt: 0,
                originalPosition: 0,
                active: false
            }));

            // Shift everyone from position onwards down by 1
            for (uint256 i = featuredQueue.length - 1; i > index; i--) {
                featuredQueue[i] = featuredQueue[i - 1];

                // Update their position mapping (they got pushed down)
                if (featuredQueue[i].active) {
                    instancePosition[featuredQueue[i].instance] = i + 1;
                    emit PositionShifted(featuredQueue[i].instance, i, i + 1);
                }
            }

            // Insert new renter at desired position
            featuredQueue[index] = newSlot;
            instancePosition[instance] = position;
        }

        // Update demand tracking for this position
        positionDemand[position] = PositionDemand({
            lastRentalPrice: rentPaid,
            lastRentalTime: block.timestamp,
            totalRentalsAllTime: positionDemand[position].totalRentalsAllTime + 1
        });
    }

    /**
     * @notice Calculate cost to bump from current position to target position
     */
    function _calculateBumpCost(
        uint256 currentPosition,
        uint256 targetPosition,
        uint256 additionalDuration
    ) internal view returns (uint256) {
        require(targetPosition < currentPosition, "Target must be higher than current");

        // Base cost is the competitive price for the target position
        uint256 baseCost = getPositionRentalPrice(targetPosition);

        // Get what you already paid
        uint256 currentIndex = currentPosition - 1;
        RentalSlot memory currentSlot = featuredQueue[currentIndex];

        // Calculate value already paid (proportional to time remaining)
        uint256 timeRemaining = currentSlot.expiresAt > block.timestamp
            ? currentSlot.expiresAt - block.timestamp
            : 0;
        uint256 totalDuration = currentSlot.expiresAt - currentSlot.rentedAt;
        uint256 remainingValue = (currentSlot.rentPaid * timeRemaining) / totalDuration;

        // Cost to bump = competitive price for target - credit from current position
        uint256 bumpCost = baseCost > remainingValue ? baseCost - remainingValue : 0;

        // Add cost for additional duration if requested
        if (additionalDuration > 0) {
            uint256 durationMultiplier = additionalDuration / minRentalDuration;
            bumpCost += (getPositionRentalPrice(targetPosition) * durationMultiplier);
        }

        return bumpCost;
    }

    /**
     * @notice Attempt to auto-renew a position using deposited funds
     */
    function _attemptAutoRenewal(address instance, uint256 position) internal returns (bool) {
        uint256 deposit = renewalDeposits[instance];
        if (deposit == 0) return false;

        // Calculate renewal cost for minimum duration
        uint256 renewalCost = calculateRentalCost(position, minRentalDuration);
        renewalCost = (renewalCost * renewalDiscount) / 100;  // Apply discount

        if (deposit < renewalCost) return false;

        // Deduct from deposit
        renewalDeposits[instance] -= renewalCost;

        // Extend the rental
        uint256 index = position - 1;
        RentalSlot storage slot = featuredQueue[index];
        slot.expiresAt = block.timestamp + minRentalDuration;
        slot.rentPaid += renewalCost;

        emit PositionAutoRenewed(instance, position, renewalCost, slot.expiresAt);
        return true;
    }

    /**
     * @notice Remove trailing inactive slots from queue
     */
    function _compactQueue() internal {
        while (featuredQueue.length > 0 && !featuredQueue[featuredQueue.length - 1].active) {
            featuredQueue.pop();
        }
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
