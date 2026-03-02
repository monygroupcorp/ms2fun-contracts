// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IMasterRegistry} from "../../master/interfaces/IMasterRegistry.sol";
import {ERC721AuctionInstance} from "./ERC721AuctionInstance.sol";
import {IAlignmentVault} from "../../interfaces/IAlignmentVault.sol";
import {IFactory} from "../../interfaces/IFactory.sol";
import {PromotionBadges} from "../../promotion/PromotionBadges.sol";
import {FeaturedQueueManager} from "../../master/FeaturedQueueManager.sol";

/**
 * @title ERC721AuctionFactory
 * @notice Factory contract for deploying ERC721 auction instances for 1/1 artists
 */
contract ERC721AuctionFactory is Ownable, ReentrancyGuard, IFactory {
    IMasterRegistry public masterRegistry;
    address public immutable globalMessageRegistry;

    // Protocol revenue
    address public protocolTreasury;
    uint256 public accumulatedProtocolFees;

    // Tiered creation
    enum CreationTier { STANDARD, PREMIUM, LAUNCH }

    /// @dev Packs all per-instance creation params to avoid stack-too-deep in _createInstanceInternal.
    struct CreateArgs {
        string name;
        string metadataURI;
        address creator;
        address vault;
        string symbol;
        uint8 lines;
        uint40 baseDuration;
        uint40 timeBuffer;
        uint256 bidIncrement;
    }

    struct TierConfig {
        uint256 featuredDuration;
        uint256 featuredRankBoost;   // ETH allocated to rank score (0 = duration only)
        PromotionBadges.BadgeType badge;
        uint256 badgeDuration;
    }

    mapping(CreationTier => TierConfig) public tierConfigs;
    PromotionBadges public promotionBadges;
    FeaturedQueueManager public featuredQueueManager;

    event InstanceCreated(
        address indexed instance,
        address indexed creator,
        string name,
        address indexed vault
    );

    event VaultCapabilityWarning(address indexed vault, bytes32 indexed capability);
    event ProtocolTreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event ProtocolFeesWithdrawn(address indexed treasury, uint256 amount);
    event TierConfigUpdated(CreationTier tier);
    event InstanceCreatedWithTier(address indexed instance, CreationTier tier);

    constructor(
        address _masterRegistry,
        address _globalMessageRegistry
    ) {
        _initializeOwner(msg.sender);
        require(_globalMessageRegistry != address(0), "Invalid global message registry");
        masterRegistry = IMasterRegistry(_masterRegistry);
        globalMessageRegistry = _globalMessageRegistry;
    }

    /**
     * @notice Create a new ERC721 auction instance (defaults to STANDARD tier)
     */
    function createInstance(
        string memory _name,
        string memory metadataURI,
        address _creator,
        address _vault,
        string memory _symbol,
        uint8 _lines,
        uint40 _baseDuration,
        uint40 _timeBuffer,
        uint256 _bidIncrement
    ) external payable nonReentrant returns (address instance) {
        return _createInstanceInternal(CreateArgs({
            name: _name, metadataURI: metadataURI, creator: _creator, vault: _vault,
            symbol: _symbol, lines: _lines, baseDuration: _baseDuration,
            timeBuffer: _timeBuffer, bidIncrement: _bidIncrement
        }), CreationTier.STANDARD);
    }

    /**
     * @notice Create a new ERC721 auction instance with a specific creation tier
     */
    function createInstance(
        string memory _name,
        string memory metadataURI,
        address _creator,
        address _vault,
        string memory _symbol,
        uint8 _lines,
        uint40 _baseDuration,
        uint40 _timeBuffer,
        uint256 _bidIncrement,
        CreationTier creationTier
    ) external payable nonReentrant returns (address instance) {
        return _createInstanceInternal(CreateArgs({
            name: _name, metadataURI: metadataURI, creator: _creator, vault: _vault,
            symbol: _symbol, lines: _lines, baseDuration: _baseDuration,
            timeBuffer: _timeBuffer, bidIncrement: _bidIncrement
        }), creationTier);
    }

    function _createInstanceInternal(CreateArgs memory args, CreationTier creationTier)
        internal returns (address instance)
    {
        TierConfig memory config = tierConfigs[creationTier];
        uint256 featuredCost = _computeFeaturedCost(config);
        require(msg.value >= featuredCost, "Insufficient featured fee");
        accumulatedProtocolFees += msg.value - featuredCost;

        require(bytes(args.name).length > 0, "Invalid name");
        require(args.creator != address(0), "Invalid creator");
        require(args.vault != address(0), "Invalid vault");
        require(args.vault.code.length > 0, "Vault must be a contract");

        // Soft capability checks
        try IAlignmentVault(payable(args.vault)).supportsCapability(keccak256("YIELD_GENERATION")) returns (bool supported) {
            if (!supported) {
                emit VaultCapabilityWarning(args.vault, keccak256("YIELD_GENERATION"));
            }
        } catch {
            emit VaultCapabilityWarning(args.vault, keccak256("YIELD_GENERATION"));
        }

        require(!masterRegistry.isNameTaken(args.name), "Name already taken");

        instance = _deployInstance(args);
        masterRegistry.registerInstance(instance, address(this), args.creator, args.name, args.metadataURI, args.vault);

        _applyTierPerks(instance, args.creator, config, featuredCost);

        emit InstanceCreated(instance, args.creator, args.name, args.vault);

        if (creationTier != CreationTier.STANDARD) {
            emit InstanceCreatedWithTier(instance, creationTier);
        }
    }

    function _computeFeaturedCost(TierConfig memory config)
        private view returns (uint256 featuredCost)
    {
        if (config.featuredDuration > 0 && address(featuredQueueManager) != address(0)) {
            featuredCost = featuredQueueManager.quoteDurationCost(config.featuredDuration) + config.featuredRankBoost;
        }
    }

    function _deployInstance(CreateArgs memory args) private returns (address) {
        return address(new ERC721AuctionInstance(
            args.vault, protocolTreasury, args.creator, args.name, args.symbol,
            args.lines, args.baseDuration, args.timeBuffer, args.bidIncrement,
            globalMessageRegistry, address(masterRegistry)
        ));
    }

    function _applyTierPerks(
        address instance,
        address creator_,
        TierConfig memory config,
        uint256 featuredCost
    ) private {
        if (config.featuredDuration > 0 && address(featuredQueueManager) != address(0) && featuredCost > 0) {
            featuredQueueManager.rentFeaturedFor{value: featuredCost}(
                instance, creator_, config.featuredDuration, config.featuredRankBoost
            );
        }
        if (config.badge != PromotionBadges.BadgeType.NONE && address(promotionBadges) != address(0)) {
            promotionBadges.assignBadgeFor(instance, config.badge, config.badgeDuration);
        }
    }

    // ┌─────────────────────────┐
    // │     Admin Functions     │
    // └─────────────────────────┘

    function setTierConfig(CreationTier tier, TierConfig calldata config) external onlyOwner {
        tierConfigs[tier] = config;
        emit TierConfigUpdated(tier);
    }

    function setPromotionBadges(address _promotionBadges) external onlyOwner {
        promotionBadges = PromotionBadges(_promotionBadges);
    }

    function setFeaturedQueueManager(address _featuredQueueManager) external onlyOwner {
        featuredQueueManager = FeaturedQueueManager(payable(_featuredQueueManager));
    }

    function setProtocolTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "Invalid treasury");
        address old = protocolTreasury;
        protocolTreasury = _treasury;
        emit ProtocolTreasuryUpdated(old, _treasury);
    }

    function withdrawProtocolFees() external onlyOwner {
        require(protocolTreasury != address(0), "Treasury not set");
        uint256 amount = accumulatedProtocolFees;
        require(amount > 0, "No protocol fees");
        accumulatedProtocolFees = 0;
        SafeTransferLib.safeTransferETH(protocolTreasury, amount);
        emit ProtocolFeesWithdrawn(protocolTreasury, amount);
    }

    function protocol() external view returns (address) {
        return owner();
    }

    function features() external view returns (bytes32[] memory) {
        return new bytes32[](0);
    }
}
