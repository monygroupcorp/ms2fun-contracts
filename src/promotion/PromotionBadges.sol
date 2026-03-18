// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {SmartTransferLib} from "../libraries/SmartTransferLib.sol";

/**
 * @title PromotionBadges
 * @notice Standalone contract for time-limited visual badge assignments for instances
 * @dev Badges provide visual distinction independent of queue position.
 *      One badge per instance at a time. Anyone can purchase a badge for any instance.
 */
contract PromotionBadges is Ownable, ReentrancyGuard {
    error InvalidDuration();
    error InvalidBadge();
    error InsufficientPayment();
    error DifferentBadgeActive();
    error TreasuryNotSet();
    error NoFees();
    error InvalidAddress();
    error InvalidBounds();

    enum BadgeType {
        NONE,
        HIGHLIGHT,    // Visual highlight/glow effect
        TRENDING,     // "Trending" indicator
        VERIFIED,     // Checkmark/verified badge
        SPOTLIGHT     // Premium spotlight treatment
    }

    struct Badge {
        BadgeType badgeType;
        uint256 expiresAt;
        uint256 paidAmount;
    }

    mapping(address => Badge) public instanceBadges;
    mapping(BadgeType => uint256) public badgePricePerDay;
    address public protocolTreasury;

    uint256 public minBadgeDuration = 1 days;
    uint256 public maxBadgeDuration = 90 days;

    // Authorized factories for privileged badge assignment
    mapping(address => bool) public authorizedFactories;
    address public weth;

    event BadgePurchased(address indexed instance, address indexed buyer, BadgeType badgeType, uint256 duration, uint256 cost);
    event BadgePriceUpdated(BadgeType badgeType, uint256 newPricePerDay);
    event ProtocolFeesWithdrawn(uint256 amount);
    event BadgeAssigned(address indexed instance, address indexed factory, BadgeType badgeType, uint256 duration);
    event AuthorizedFactoryUpdated(address indexed factory, bool authorized);
    event ProtocolTreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event DurationBoundsUpdated(uint256 minDuration, uint256 maxDuration);

    // slither-disable-next-line missing-zero-check
    constructor(address _protocolTreasury) {
        _initializeOwner(msg.sender);
        protocolTreasury = _protocolTreasury;

        // Default pricing
        badgePricePerDay[BadgeType.HIGHLIGHT] = 0.001 ether;
        badgePricePerDay[BadgeType.TRENDING] = 0.002 ether;
        badgePricePerDay[BadgeType.VERIFIED] = 0.005 ether;
        badgePricePerDay[BadgeType.SPOTLIGHT] = 0.01 ether;
    }

    /**
     * @notice Purchase a time-limited badge for an instance
     * @param instance Instance address to badge
     * @param badgeType Type of badge to purchase
     * @param duration Duration in seconds
     */
    // slither-disable-next-line timestamp
    function purchaseBadge(
        address instance,
        BadgeType badgeType,
        uint256 duration
    ) external payable nonReentrant {
        if (duration < minBadgeDuration || duration > maxBadgeDuration) revert InvalidDuration();
        if (badgeType == BadgeType.NONE) revert InvalidBadge();

        uint256 cost = (badgePricePerDay[badgeType] * duration) / 1 days; // round down: favors buyer
        if (msg.value < cost) revert InsufficientPayment();

        Badge storage current = instanceBadges[instance];
        if (current.badgeType != BadgeType.NONE && block.timestamp < current.expiresAt) {
            // Active badge exists — only allow extending same type
            if (current.badgeType != badgeType) revert DifferentBadgeActive();
            instanceBadges[instance] = Badge({
                badgeType: badgeType,
                expiresAt: current.expiresAt + duration,
                paidAmount: current.paidAmount + cost
            });
        } else {
            // No active badge — set new
            instanceBadges[instance] = Badge({
                badgeType: badgeType,
                expiresAt: block.timestamp + duration,
                paidAmount: cost
            });
        }

        // Refund excess
        if (msg.value > cost) {
            SmartTransferLib.smartTransferETH(msg.sender, msg.value - cost, weth);
        }

        emit BadgePurchased(instance, msg.sender, badgeType, duration, cost);
    }

    /**
     * @notice Get active badge for an instance (returns NONE if expired)
     */
    // slither-disable-next-line incorrect-equality,timestamp
    function getActiveBadge(address instance) external view returns (BadgeType, uint256 expiresAt) {
        Badge memory badge = instanceBadges[instance];
        if (badge.badgeType == BadgeType.NONE || block.timestamp >= badge.expiresAt) {
            return (BadgeType.NONE, 0);
        }
        return (badge.badgeType, badge.expiresAt);
    }

    /**
     * @notice Batch query active badges for multiple instances
     */
    // slither-disable-next-line timestamp
    function getActiveBadges(
        address[] calldata instances
    ) external view returns (BadgeType[] memory badges, uint256[] memory expirations) {
        badges = new BadgeType[](instances.length);
        expirations = new uint256[](instances.length);
        for (uint256 i = 0; i < instances.length; i++) {
            Badge memory b = instanceBadges[instances[i]];
            if (b.badgeType != BadgeType.NONE && block.timestamp < b.expiresAt) {
                badges[i] = b.badgeType;
                expirations[i] = b.expiresAt;
            }
        }
    }

    /**
     * @notice Privileged badge assignment for authorized factories (no payment)
     * @param instance Instance to assign badge to
     * @param badgeType Badge type to assign
     * @param duration Duration in seconds
     */
    function assignBadgeFor(
        address instance,
        BadgeType badgeType,
        uint256 duration
    ) external {
        if (!authorizedFactories[msg.sender]) revert Unauthorized();
        if (badgeType == BadgeType.NONE) revert InvalidBadge();

        instanceBadges[instance] = Badge({
            badgeType: badgeType,
            expiresAt: block.timestamp + duration,
            paidAmount: 0
        });

        emit BadgeAssigned(instance, msg.sender, badgeType, duration);
    }

    /**
     * @notice Withdraw accumulated fees to protocol treasury
     */
    // slither-disable-next-line incorrect-equality
    function withdrawProtocolFees() external onlyOwner {
        if (protocolTreasury == address(0)) revert TreasuryNotSet();
        uint256 balance = address(this).balance;
        if (balance == 0) revert NoFees();
        SafeTransferLib.safeTransferETH(protocolTreasury, balance);
        emit ProtocolFeesWithdrawn(balance);
    }

    /**
     * @notice Set price per day for a badge type (owner only)
     */
    function setBadgePrice(BadgeType badgeType, uint256 pricePerDay) external onlyOwner {
        if (badgeType == BadgeType.NONE) revert InvalidBadge();
        badgePricePerDay[badgeType] = pricePerDay;
        emit BadgePriceUpdated(badgeType, pricePerDay);
    }

    /**
     * @notice Authorize or deauthorize a factory for privileged badge assignment
     */
    function setAuthorizedFactory(address factory, bool authorized) external onlyOwner {
        authorizedFactories[factory] = authorized;
        emit AuthorizedFactoryUpdated(factory, authorized);
    }

    /**
     * @notice Update protocol treasury address
     */
    function setWeth(address _weth) external onlyOwner {
        if (_weth == address(0)) revert InvalidAddress();
        weth = _weth;
    }

    function setProtocolTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert InvalidAddress();
        address old = protocolTreasury;
        protocolTreasury = _treasury;
        emit ProtocolTreasuryUpdated(old, _treasury);
    }

    /**
     * @notice Update min/max badge duration bounds
     */
    function setDurationBounds(uint256 _min, uint256 _max) external onlyOwner {
        if (_min == 0 || _max <= _min) revert InvalidBounds();
        minBadgeDuration = _min;
        maxBadgeDuration = _max;
        emit DurationBoundsUpdated(_min, _max);
    }
}
