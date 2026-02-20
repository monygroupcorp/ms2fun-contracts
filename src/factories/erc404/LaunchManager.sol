// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "solady/auth/Ownable.sol";
import {PromotionBadges} from "../../promotion/PromotionBadges.sol";
import {FeaturedQueueManager} from "../../master/FeaturedQueueManager.sol";

/**
 * @title LaunchManager
 * @notice Manages tiered creation, featured queue placement, and badge assignment for ERC404Factory instances
 * @dev Extracted from ERC404Factory to reduce bytecode size. Owns all tier/promotion concerns.
 */
contract LaunchManager is Ownable {
    // Tiered creation
    enum CreationTier { STANDARD, PREMIUM, LAUNCH }

    struct TierConfig {
        uint256 fee;
        uint256 featuredDuration;    // 0 = no featured placement
        uint256 featuredRankBoost;   // ETH allocated to rank score (0 = duration only)
        PromotionBadges.BadgeType badge; // NONE = no badge
        uint256 badgeDuration;       // 0 = no badge
    }

    mapping(CreationTier => TierConfig) public tierConfigs;
    PromotionBadges public promotionBadges;
    FeaturedQueueManager public featuredQueueManager;

    event TierConfigUpdated(CreationTier tier, uint256 fee);
    event PromotionBadgesUpdated(address indexed promotionBadges);
    event FeaturedQueueManagerUpdated(address indexed featuredQueueManager);

    constructor(address _protocol) {
        require(_protocol != address(0), "Invalid protocol");
        _initializeOwner(_protocol);
    }

    /**
     * @notice Set configuration for a creation tier
     */
    function setTierConfig(CreationTier tier, TierConfig calldata config) external onlyOwner {
        require(config.fee > 0, "Fee must be positive");
        tierConfigs[tier] = config;
        emit TierConfigUpdated(tier, config.fee);
    }

    /**
     * @notice Set PromotionBadges contract reference
     */
    function setPromotionBadges(address _promotionBadges) external onlyOwner {
        promotionBadges = PromotionBadges(_promotionBadges);
        emit PromotionBadgesUpdated(_promotionBadges);
    }

    /**
     * @notice Set FeaturedQueueManager contract reference
     */
    function setFeaturedQueueManager(address _featuredQueueManager) external onlyOwner {
        featuredQueueManager = FeaturedQueueManager(payable(_featuredQueueManager));
        emit FeaturedQueueManagerUpdated(_featuredQueueManager);
    }

    /**
     * @notice Apply featured queue placement and badge assignment for a newly created instance
     * @param instance The deployed instance address
     * @param tier The creation tier used
     * @param renter The creator address credited as renter
     */
    function applyTierPerks(address instance, CreationTier tier, address renter) external payable {
        TierConfig memory config = tierConfigs[tier];

        if (config.featuredDuration > 0 && address(featuredQueueManager) != address(0)) {
            uint256 featuredCost = featuredQueueManager.quoteDurationCost(config.featuredDuration) + config.featuredRankBoost;
            if (featuredCost > 0) {
                featuredQueueManager.rentFeaturedFor{value: featuredCost}(
                    instance, renter, config.featuredDuration, config.featuredRankBoost
                );
            }
        }

        if (config.badge != PromotionBadges.BadgeType.NONE && address(promotionBadges) != address(0)) {
            promotionBadges.assignBadgeFor(instance, config.badge, config.badgeDuration);
        }
    }

    /**
     * @notice Return the fee for a given tier, falling back to defaultFee for STANDARD with no config
     * @param tier The creation tier
     * @param defaultFee The fallback fee (used for STANDARD when no config set)
     * @return fee The resolved fee
     */
    function getTierFee(CreationTier tier, uint256 defaultFee) external view returns (uint256 fee) {
        TierConfig memory config = tierConfigs[tier];
        if (config.fee > 0) {
            return config.fee;
        } else if (tier == CreationTier.STANDARD) {
            return defaultFee;
        } else {
            revert("Tier not configured");
        }
    }
}
