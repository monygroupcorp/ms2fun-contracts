// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UUPSUpgradeable} from "solady/utils/UUPSUpgradeable.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {IMasterRegistry} from "./interfaces/IMasterRegistry.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/**
 * @title FeaturedQueueManager
 * @notice Competitive featured placement for the protocol landing page.
 *
 * Three independent mechanics — each a separate payment, each doing one thing:
 *
 *   rentFeatured(instance, duration, rankBoost)
 *     Pay durationCost + rankBoost. durationCost buys time in the featured set.
 *     rankBoost is added to the instance's cumulative rank score.
 *     Rank from previous slots carries forward (decayed). No refunds on being outranked.
 *
 *   boostRank(instance)
 *     Anyone can send ETH directly to an instance's rank score.
 *     Crystallises accumulated decay then adds the new amount.
 *
 *   renewDuration(instance, duration)
 *     Anyone can extend an active slot's expiry at the flat daily rate.
 *     Zero effect on rank.
 *
 * Rank decays linearly at dailyDecayRate per day, computed lazily at read time.
 * getFeaturedInstances returns active slots sorted by effective rank — position 1 first.
 */
contract FeaturedQueueManager is UUPSUpgradeable, Ownable, ReentrancyGuard {

    // ── Data ───────────────────────────────────────────────────────────────

    struct FeaturedSlot {
        address renter;
        uint256 rankScore;      // raw accumulated rank (before decay)
        uint256 lastBoostTime;  // decay reference — updated on every rank write
        uint256 expiresAt;      // visibility cutoff
    }

    // ── State ──────────────────────────────────────────────────────────────

    IMasterRegistry public masterRegistry;

    mapping(address => FeaturedSlot) public slots;
    address[] private _featuredList;
    mapping(address => bool) private _inList;

    uint256 public dailyRate       = 0.001 ether;   // duration cost per day
    uint256 public dailyDecayRate  = 0.0001 ether;  // linear rank decay per day
    uint256 public minDuration     = 7 days;
    uint256 public maxDuration     = 365 days;
    uint256 public maxFeaturedSize = 100;

    address public protocolTreasury;
    mapping(address => bool)    public authorizedFactories;
    mapping(address => uint256) public factoryDiscountBps;  // duration discount, e.g. 1000 = 10%

    bool private _initialized;

    // ── Events ─────────────────────────────────────────────────────────────

    event FeaturedRented(
        address indexed instance,
        address indexed renter,
        uint256 duration,
        uint256 durationCost,
        uint256 rankBoost,
        uint256 expiresAt
    );
    event RankBoosted(
        address indexed instance,
        address indexed booster,
        uint256 amount,
        uint256 newEffectiveRank
    );
    event DurationRenewed(
        address indexed instance,
        address indexed renewer,
        uint256 additionalDuration,
        uint256 cost,
        uint256 newExpiresAt
    );
    event ProtocolFeesWithdrawn(address indexed treasury, uint256 amount);
    event MasterRegistrySet(address indexed registry);
    event ProtocolTreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event AuthorizedFactoryUpdated(address indexed factory, bool authorized, uint256 discountBps);

    // ── Constructor / Init ─────────────────────────────────────────────────

    constructor() {
        _initializeOwner(msg.sender);
    }

    function initialize(address _masterRegistry, address _owner) external {
        require(!_initialized, "Already initialized");
        require(_masterRegistry != address(0), "Invalid master registry");
        require(_owner != address(0), "Invalid owner");

        _initialized = true;
        masterRegistry = IMasterRegistry(_masterRegistry);
        _setOwner(_owner);

        dailyRate       = 0.001 ether;
        dailyDecayRate  = 0.0001 ether;
        minDuration     = 7 days;
        maxDuration     = 365 days;
        maxFeaturedSize = 100;
    }

    // ── Core Write Functions ───────────────────────────────────────────────

    /**
     * @notice Enter the featured set. Payment explicitly splits between duration and rank.
     * @param instance   Registered instance to feature
     * @param duration   How long to be visible (seconds); msg.value must cover durationCost
     * @param rankBoost  Additional ETH allocated to rank score; competes for position
     */
    function rentFeatured(
        address instance,
        uint256 duration,
        uint256 rankBoost
    ) external payable nonReentrant {
        require(_isInstanceRegistered(instance), "Instance not registered");
        require(block.timestamp >= slots[instance].expiresAt, "Already featured");
        require(duration >= minDuration && duration <= maxDuration, "Invalid duration");

        uint256 durationCost = (dailyRate * duration) / 1 days;
        require(msg.value >= durationCost + rankBoost, "Insufficient payment");
        require(_activeCount() < maxFeaturedSize, "Featured set full");

        _addToList(instance);

        // Carry decayed rank forward, add new boost
        uint256 newRank = _effectiveRank(slots[instance]) + rankBoost;

        slots[instance] = FeaturedSlot({
            renter:        msg.sender,
            rankScore:     newRank,
            lastBoostTime: block.timestamp,
            expiresAt:     block.timestamp + duration
        });

        if (msg.value > durationCost + rankBoost) {
            SafeTransferLib.safeTransferETH(msg.sender, msg.value - durationCost - rankBoost);
        }

        emit FeaturedRented(instance, msg.sender, duration, durationCost, rankBoost, slots[instance].expiresAt);
    }

    /**
     * @notice Add to an instance's rank score. Anyone can boost.
     *         Crystallises decay accrued since lastBoostTime, then adds the new amount.
     * @param instance  Active featured instance to boost
     */
    function boostRank(address instance) external payable nonReentrant {
        require(msg.value > 0, "Must send ETH");
        require(block.timestamp < slots[instance].expiresAt, "Slot not active");

        uint256 newRank = _effectiveRank(slots[instance]) + msg.value;
        slots[instance].rankScore     = newRank;
        slots[instance].lastBoostTime = block.timestamp;

        emit RankBoosted(instance, msg.sender, msg.value, newRank);
    }

    /**
     * @notice Extend an active slot's duration. Anyone can renew — fans can keep
     *         their favourite project visible. Zero effect on rank.
     * @param instance           Active featured instance
     * @param additionalDuration Extra seconds to add to expiresAt
     */
    function renewDuration(
        address instance,
        uint256 additionalDuration
    ) external payable nonReentrant {
        require(block.timestamp < slots[instance].expiresAt, "Slot expired - use rentFeatured");
        require(additionalDuration >= minDuration, "Duration too short");
        require(additionalDuration <= maxDuration, "Duration too long");

        uint256 cost = (dailyRate * additionalDuration) / 1 days;
        require(msg.value >= cost, "Insufficient payment");

        slots[instance].expiresAt += additionalDuration;

        if (msg.value > cost) {
            SafeTransferLib.safeTransferETH(msg.sender, msg.value - cost);
        }

        emit DurationRenewed(instance, msg.sender, additionalDuration, cost, slots[instance].expiresAt);
    }

    /**
     * @notice Authorized factory entry point for bundle packages.
     *         Applies a factory-specific duration discount (rank boost priced normally).
     * @param instance   Instance being deployed
     * @param renter     Address credited as renter (the deploying creator)
     * @param duration   Featured duration
     * @param rankBoost  Initial rank allocation
     */
    function rentFeaturedFor(
        address instance,
        address renter,
        uint256 duration,
        uint256 rankBoost
    ) external payable nonReentrant {
        require(authorizedFactories[msg.sender], "Not authorized");
        require(_isInstanceRegistered(instance), "Instance not registered");
        require(block.timestamp >= slots[instance].expiresAt, "Already featured");
        require(duration >= minDuration && duration <= maxDuration, "Invalid duration");

        uint256 discount     = factoryDiscountBps[msg.sender];
        uint256 durationCost = ((dailyRate * duration) / 1 days) * (10000 - discount) / 10000;
        require(msg.value >= durationCost + rankBoost, "Insufficient payment");
        require(_activeCount() < maxFeaturedSize, "Featured set full");

        _addToList(instance);

        uint256 newRank = _effectiveRank(slots[instance]) + rankBoost;

        slots[instance] = FeaturedSlot({
            renter:        renter,
            rankScore:     newRank,
            lastBoostTime: block.timestamp,
            expiresAt:     block.timestamp + duration
        });

        if (msg.value > durationCost + rankBoost) {
            SafeTransferLib.safeTransferETH(msg.sender, msg.value - durationCost - rankBoost);
        }

        emit FeaturedRented(instance, renter, duration, durationCost, rankBoost, slots[instance].expiresAt);
    }

    // ── Read Functions ─────────────────────────────────────────────────────

    /**
     * @notice Active featured instances sorted by effective rank, position 1 first.
     * @param offset  Start index into the active-only list
     * @param limit   Max results to return
     * @return instances Sorted active instances
     * @return total     Total number of active featured slots
     */
    function getFeaturedInstances(
        uint256 offset,
        uint256 limit
    ) external view returns (address[] memory instances, uint256 total) {
        // Pass 1: count active
        uint256 activeCount = 0;
        for (uint256 i = 0; i < _featuredList.length; i++) {
            if (block.timestamp < slots[_featuredList[i]].expiresAt) activeCount++;
        }
        total = activeCount;

        if (offset >= activeCount || limit == 0) return (new address[](0), total);

        // Pass 2: collect active addresses and their effective ranks
        address[] memory active = new address[](activeCount);
        uint256[] memory ranks  = new uint256[](activeCount);
        uint256 idx = 0;
        for (uint256 i = 0; i < _featuredList.length; i++) {
            address inst = _featuredList[i];
            if (block.timestamp < slots[inst].expiresAt) {
                active[idx] = inst;
                ranks[idx]  = _effectiveRank(slots[inst]);
                idx++;
            }
        }

        // Pass 3: insertion sort descending by effective rank
        for (uint256 i = 1; i < activeCount; i++) {
            address keyAddr = active[i];
            uint256 keyRank = ranks[i];
            uint256 j = i;
            while (j > 0 && ranks[j - 1] < keyRank) {
                active[j] = active[j - 1];
                ranks[j]  = ranks[j - 1];
                j--;
            }
            active[j] = keyAddr;
            ranks[j]  = keyRank;
        }

        // Pass 4: return paginated slice
        uint256 end = offset + limit > activeCount ? activeCount : offset + limit;
        instances = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            instances[i - offset] = active[i];
        }
    }

    /**
     * @notice Slot info for an instance.
     * @return renter        Address that rented the slot
     * @return effectiveRank Current rank after linear decay
     * @return expiresAt     Slot expiry timestamp
     * @return isActive      True if slot is currently active
     */
    function getRentalInfo(address instance) external view returns (
        address renter,
        uint256 effectiveRank,
        uint256 expiresAt,
        bool isActive
    ) {
        FeaturedSlot memory slot = slots[instance];
        return (
            slot.renter,
            _effectiveRank(slot),
            slot.expiresAt,
            block.timestamp < slot.expiresAt
        );
    }

    /**
     * @notice Effective rank for an instance after applying linear decay.
     */
    function getEffectiveRank(address instance) external view returns (uint256) {
        return _effectiveRank(slots[instance]);
    }

    /**
     * @notice Number of currently active featured slots.
     */
    function queueLength() external view returns (uint256) {
        return _activeCount();
    }

    /**
     * @notice Duration cost for a given number of seconds.
     */
    function quoteDurationCost(uint256 duration) external view returns (uint256) {
        return (dailyRate * duration) / 1 days;
    }

    // ── Internal Helpers ───────────────────────────────────────────────────

    function _effectiveRank(FeaturedSlot memory slot) internal view returns (uint256) {
        if (slot.lastBoostTime == 0) return 0;
        uint256 daysPassed = (block.timestamp - slot.lastBoostTime) / 1 days;
        uint256 decayed    = dailyDecayRate * daysPassed;
        return slot.rankScore > decayed ? slot.rankScore - decayed : 0;
    }

    function _activeCount() internal view returns (uint256) {
        uint256 count = 0;
        for (uint256 i = 0; i < _featuredList.length; i++) {
            if (block.timestamp < slots[_featuredList[i]].expiresAt) count++;
        }
        return count;
    }

    function _addToList(address instance) internal {
        if (!_inList[instance]) {
            _featuredList.push(instance);
            _inList[instance] = true;
        }
    }

    function _isInstanceRegistered(address instance) internal view returns (bool) {
        try masterRegistry.getInstanceInfo(instance) returns (IMasterRegistry.InstanceInfo memory) {
            return true;
        } catch {
            return false;
        }
    }

    // ── Admin ──────────────────────────────────────────────────────────────

    function setMasterRegistry(address _masterRegistry) external onlyOwner {
        require(_masterRegistry != address(0), "Invalid address");
        masterRegistry = IMasterRegistry(_masterRegistry);
        emit MasterRegistrySet(_masterRegistry);
    }

    function setProtocolTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "Invalid address");
        address old = protocolTreasury;
        protocolTreasury = _treasury;
        emit ProtocolTreasuryUpdated(old, _treasury);
    }

    function setDailyRate(uint256 _dailyRate) external onlyOwner {
        dailyRate = _dailyRate;
    }

    function setDailyDecayRate(uint256 _dailyDecayRate) external onlyOwner {
        dailyDecayRate = _dailyDecayRate;
    }

    function setDurationBounds(uint256 _min, uint256 _max) external onlyOwner {
        require(_min > 0 && _max > _min, "Invalid bounds");
        minDuration = _min;
        maxDuration = _max;
    }

    function setMaxFeaturedSize(uint256 _max) external onlyOwner {
        require(_max > 0, "Invalid size");
        maxFeaturedSize = _max;
    }

    /**
     * @notice Authorize a factory for bundle placement with an optional duration discount.
     * @param discountBps Basis points off the daily rate, max 5000 (50%)
     */
    function setAuthorizedFactory(address factory, bool authorized, uint256 discountBps) external onlyOwner {
        require(discountBps <= 5000, "Discount too high");
        authorizedFactories[factory]  = authorized;
        factoryDiscountBps[factory]   = authorized ? discountBps : 0;
        emit AuthorizedFactoryUpdated(factory, authorized, discountBps);
    }

    function withdrawProtocolFees() external onlyOwner {
        require(protocolTreasury != address(0), "Treasury not set");
        uint256 balance = address(this).balance;
        require(balance > 0, "Nothing to withdraw");
        SafeTransferLib.safeTransferETH(protocolTreasury, balance);
        emit ProtocolFeesWithdrawn(protocolTreasury, balance);
    }

    // ── UUPS ───────────────────────────────────────────────────────────────

    function _authorizeUpgrade(address) internal override onlyOwner {}

    receive() external payable {}
}
