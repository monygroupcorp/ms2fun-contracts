// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UUPSUpgradeable} from "solady/utils/UUPSUpgradeable.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {IMasterRegistry} from "./interfaces/IMasterRegistry.sol";

/**
 * @title FeaturedQueueManager
 * @notice Manages the competitive rental queue system for featured instances
 * @dev Extracted from MasterRegistryV1 to meet bytecode size limits
 *
 * Core Features:
 * - Competitive position rental with dynamic pricing
 * - Queue-based featured promotion system
 * - Time-based expiration with auto-renewal
 * - Cleanup incentives for expired rentals
 */
contract FeaturedQueueManager is UUPSUpgradeable, Ownable, ReentrancyGuard {
    // Reference to MasterRegistry for instance validation
    IMasterRegistry public masterRegistry;

    // ============ Competitive Rental Queue System ============

    // Featured queue (index 0 = position 1 = front)
    IMasterRegistry.RentalSlot[] public featuredQueue;

    // Quick position lookups (1-indexed, 0 = not in queue)
    mapping(address => uint256) public instancePosition;

    // Per-position competitive pricing
    mapping(uint256 => IMasterRegistry.PositionDemand) public positionDemand;

    // Auto-renewal deposits
    mapping(address => uint256) public renewalDeposits;

    // Configuration parameters
    uint256 public baseRentalPrice = 0.001 ether;
    uint256 public minRentalDuration = 7 days;
    uint256 public maxRentalDuration = 365 days;
    uint256 public demandMultiplier = 120;              // 120% = 20% increase per action
    uint256 public renewalDiscount = 90;                // 90% = 10% discount for renewals

    // Gas-based reward system (M-04 security fix)
    uint256 public constant CLEANUP_BASE_GAS = 50_000;  // Fixed overhead for cleanup
    uint256 public constant GAS_PER_ACTION = 25_000;    // Per-action cleanup cost
    uint256 public standardCleanupReward = 0.0012 ether; // Fixed incentive (~$3, post-Hasaka)

    uint256 public maxQueueSize = 100;
    uint256 public visibleThreshold = 20;               // Frontend shows top N

    // Events
    event PositionRented(address indexed instance, address indexed renter, uint256 position, uint256 cost, uint256 duration, uint256 expiresAt);
    event PositionRenewed(address indexed instance, uint256 position, uint256 additionalDuration, uint256 cost, uint256 newExpiration);
    event PositionBumped(address indexed instance, uint256 oldPosition, uint256 newPosition, uint256 cost, uint256 additionalDuration);
    event PositionShifted(address indexed instance, uint256 oldPosition, uint256 newPosition);
    event RentalExpired(address indexed instance, uint256 position, uint256 expiresAt);
    event PositionAutoRenewed(address indexed instance, uint256 position, uint256 cost, uint256 newExpiration);
    event AutoRenewalDeposited(address indexed instance, address indexed depositor, uint256 amount);
    event RenewalDepositWithdrawn(address indexed instance, address indexed withdrawer, uint256 amount);
    event CleanupRewardPaid(address indexed caller, uint256 cleaned, uint256 renewed, uint256 reward);
    event CleanupRewardRejected(address indexed caller, uint256 rewardAmount);
    event InsufficientCleanupRewardBalance(address indexed caller, uint256 rewardAmount, uint256 contractBalance);
    event MasterRegistrySet(address indexed newRegistry);

    // Constructor
    constructor() {
        _initializeOwner(msg.sender);
    }

    /**
     * @notice Initialize the contract
     * @param _masterRegistry Address of the MasterRegistry contract
     */
    function initialize(address _masterRegistry, address _owner) public {
        require(address(masterRegistry) == address(0), "Already initialized");
        require(_masterRegistry != address(0), "Invalid master registry");
        require(_owner != address(0), "Invalid owner");

        masterRegistry = IMasterRegistry(_masterRegistry);
        _setOwner(_owner);

        // Initialize competitive queue system
        baseRentalPrice = 0.001 ether;
        minRentalDuration = 7 days;
        maxRentalDuration = 365 days;
        demandMultiplier = 120;
        renewalDiscount = 90;
        standardCleanupReward = 0.0012 ether;
        maxQueueSize = 100;
        visibleThreshold = 20;
    }

    /**
     * @notice Set MasterRegistry address
     * @param _masterRegistry New MasterRegistry address
     */
    function setMasterRegistry(address _masterRegistry) external onlyOwner {
        require(_masterRegistry != address(0), "Invalid master registry");
        masterRegistry = IMasterRegistry(_masterRegistry);
        emit MasterRegistrySet(_masterRegistry);
    }

    /**
     * @notice Get competitive rental price for a position
     * @param position 1-indexed position (1 = front)
     * @return price Current rental price for this position
     */
    function getPositionRentalPrice(uint256 position) public view returns (uint256) {
        require(position > 0, "Invalid position");

        // Calculate utilization-adjusted base price
        uint256 queueLength = featuredQueue.length;
        uint256 utilizationBps = (queueLength * 10000) / maxQueueSize;
        uint256 adjustedBase = baseRentalPrice + (baseRentalPrice * utilizationBps) / 10000;

        // Check if position has active rental (competitive bidding)
        if (position <= featuredQueue.length) {
            IMasterRegistry.RentalSlot memory slot = featuredQueue[position - 1];
            if (slot.active && block.timestamp < slot.expiresAt) {
                uint256 competitivePrice = (slot.rentPaid * demandMultiplier) / 100;
                return competitivePrice > adjustedBase ? competitivePrice : adjustedBase;
            }
        }

        // Check demand tracking
        IMasterRegistry.PositionDemand memory demand = positionDemand[position];
        if (demand.lastRentalTime > 0) {
            uint256 demandPrice = (demand.lastRentalPrice * demandMultiplier) / 100;
            return demandPrice > adjustedBase ? demandPrice : adjustedBase;
        }

        return adjustedBase;
    }

    /**
     * @notice Get current queue length
     */
    function queueLength() external view returns (uint256) {
        return featuredQueue.length;
    }

    /**
     * @notice Get current queue utilization metrics
     */
    function getQueueUtilization() external view returns (
        uint256 currentUtilization,
        uint256 adjustedBasePrice,
        uint256 length,
        uint256 maxSize
    ) {
        length = featuredQueue.length;
        maxSize = maxQueueSize;
        currentUtilization = (length * 10000) / maxQueueSize;
        adjustedBasePrice = baseRentalPrice + (baseRentalPrice * currentUtilization) / 10000;

        return (currentUtilization, adjustedBasePrice, length, maxSize);
    }

    /**
     * @notice Calculate total rental cost with duration
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
     */
    function rentFeaturedPosition(
        address instance,
        uint256 desiredPosition,
        uint256 duration
    ) external payable nonReentrant {
        // Validate instance exists in MasterRegistry
        require(_isInstanceRegistered(instance), "Instance not registered");
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
        IMasterRegistry.RentalSlot memory rental,
        uint256 position,
        uint256 renewalDeposit,
        bool isExpired
    ) {
        uint256 pos = instancePosition[instance];
        IMasterRegistry.RentalSlot memory slot;

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

        IMasterRegistry.RentalSlot memory slot = featuredQueue[position - 1];

        // Get instance info from MasterRegistry
        IMasterRegistry.InstanceInfo memory info = masterRegistry.getInstanceInfo(instance);

        require(
            slot.renter == msg.sender || info.creator == msg.sender,
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
        IMasterRegistry.InstanceInfo memory info = masterRegistry.getInstanceInfo(instance);

        if (position > 0) {
            IMasterRegistry.RentalSlot memory slot = featuredQueue[position - 1];
            require(
                slot.renter == msg.sender || info.creator == msg.sender,
                "Not authorized"
            );
        } else {
            require(info.creator == msg.sender, "Not authorized");
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
     */
    function renewPosition(
        address instance,
        uint256 additionalDuration
    ) external payable nonReentrant {
        uint256 position = instancePosition[instance];
        require(position > 0, "Not in queue");

        uint256 index = position - 1;
        IMasterRegistry.RentalSlot storage slot = featuredQueue[index];

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
        IMasterRegistry.RentalSlot storage currentSlot = featuredQueue[currentIndex];

        require(currentSlot.renter == msg.sender, "Not your rental");
        require(currentSlot.active, "Rental not active");
        require(block.timestamp < currentSlot.expiresAt, "Rental expired");

        // Get the FULL competitive price
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
        IMasterRegistry.RentalSlot memory movingSlot = currentSlot;

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
        positionDemand[targetPosition] = IMasterRegistry.PositionDemand({
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
     */
    function cleanupExpiredRentals(uint256 maxCleanup) external nonReentrant {
        require(maxCleanup > 0 && maxCleanup <= 50, "Invalid cleanup limit");

        uint256 cleanedCount = 0;
        uint256 renewedCount = 0;

        // Scan from back to front
        uint256 i = featuredQueue.length;

        while (i > 0 && (cleanedCount + renewedCount) < maxCleanup) {
            i--;
            IMasterRegistry.RentalSlot storage slot = featuredQueue[i];

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

        // Pay reward to caller (M-04 Security Fix: Gas-based + graceful degradation)
        uint256 totalActions = cleanedCount + renewedCount;
        if (totalActions > 0) {
            uint256 estimatedGas = CLEANUP_BASE_GAS + (totalActions * GAS_PER_ACTION);
            uint256 gasCost = estimatedGas * tx.gasprice;
            uint256 reward = gasCost + standardCleanupReward;

            if (address(this).balance >= reward) {
                (bool success, ) = payable(msg.sender).call{value: reward}("");
                if (success) {
                    emit CleanupRewardPaid(msg.sender, cleanedCount, renewedCount, reward);
                } else {
                    emit CleanupRewardRejected(msg.sender, reward);
                }
            } else {
                emit InsufficientCleanupRewardBalance(msg.sender, reward, address(this).balance);
            }
        }
    }

    // ============ Internal Helper Functions ============

    /**
     * @notice Check if instance is registered in MasterRegistry
     */
    function _isInstanceRegistered(address instance) internal view returns (bool) {
        try masterRegistry.getInstanceInfo(instance) returns (IMasterRegistry.InstanceInfo memory) {
            return true;
        } catch {
            return false;
        }
    }

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

        IMasterRegistry.RentalSlot memory newSlot = IMasterRegistry.RentalSlot({
            instance: instance,
            renter: msg.sender,
            rentPaid: rentPaid,
            rentedAt: block.timestamp,
            expiresAt: expiresAt,
            originalPosition: position,
            active: true
        });

        // Case 1: Appending to back
        if (position > featuredQueue.length) {
            while (featuredQueue.length < position - 1) {
                featuredQueue.push(IMasterRegistry.RentalSlot({
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
        // Case 2: Inserting in middle/front
        else {
            featuredQueue.push(IMasterRegistry.RentalSlot({
                instance: address(0),
                renter: address(0),
                rentPaid: 0,
                rentedAt: 0,
                expiresAt: 0,
                originalPosition: 0,
                active: false
            }));

            // Shift everyone down
            for (uint256 i = featuredQueue.length - 1; i > index; i--) {
                featuredQueue[i] = featuredQueue[i - 1];

                if (featuredQueue[i].active) {
                    instancePosition[featuredQueue[i].instance] = i + 1;
                    emit PositionShifted(featuredQueue[i].instance, i, i + 1);
                }
            }

            featuredQueue[index] = newSlot;
            instancePosition[instance] = position;
        }

        // Update demand tracking
        positionDemand[position] = IMasterRegistry.PositionDemand({
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

        uint256 baseCost = getPositionRentalPrice(targetPosition);

        uint256 currentIndex = currentPosition - 1;
        IMasterRegistry.RentalSlot memory currentSlot = featuredQueue[currentIndex];

        uint256 timeRemaining = currentSlot.expiresAt > block.timestamp
            ? currentSlot.expiresAt - block.timestamp
            : 0;
        uint256 totalDuration = currentSlot.expiresAt - currentSlot.rentedAt;
        uint256 remainingValue = (currentSlot.rentPaid * timeRemaining) / totalDuration;

        uint256 bumpCost = baseCost > remainingValue ? baseCost - remainingValue : 0;

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

        uint256 renewalCost = calculateRentalCost(position, minRentalDuration);
        renewalCost = (renewalCost * renewalDiscount) / 100;

        if (deposit < renewalCost) return false;

        renewalDeposits[instance] -= renewalCost;

        uint256 index = position - 1;
        IMasterRegistry.RentalSlot storage slot = featuredQueue[index];
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

    /**
     * @notice Update standard cleanup reward
     */
    function setStandardCleanupReward(uint256 newReward) external onlyOwner {
        require(newReward <= 0.05 ether, "Reward too high (max 0.05 ETH)");
        standardCleanupReward = newReward;
    }

    // UUPS Upgrade Authorization
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // Allow contract to receive ETH
    receive() external payable {}
}
