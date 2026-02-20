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
    uint256 public instanceCreationFee;

    // Protocol revenue
    address public protocolTreasury;

    // Creator incentives
    address public immutable creator;
    uint256 public immutable creatorFeeBps;
    uint256 public accumulatedCreatorFees;
    uint256 public accumulatedProtocolFees;

    // Tiered creation
    enum CreationTier { STANDARD, PREMIUM, LAUNCH }

    struct TierConfig {
        uint256 fee;
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

    event InstanceCreationFeeUpdated(uint256 newFee);
    event VaultCapabilityWarning(address indexed vault, bytes32 indexed capability);
    event ProtocolTreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event ProtocolFeesWithdrawn(address indexed treasury, uint256 amount);
    event CreatorFeesWithdrawn(address indexed creator, uint256 amount);
    event TierConfigUpdated(CreationTier tier, uint256 fee);
    event InstanceCreatedWithTier(address indexed instance, CreationTier tier, uint256 fee);

    constructor(
        address _masterRegistry,
        address _creator,
        uint256 _creatorFeeBps,
        address _globalMessageRegistry
    ) {
        _initializeOwner(msg.sender);
        require(_creatorFeeBps <= 10000, "Invalid creator fee bps");
        require(_globalMessageRegistry != address(0), "Invalid global message registry");
        creator = _creator;
        creatorFeeBps = _creatorFeeBps;
        masterRegistry = IMasterRegistry(_masterRegistry);
        globalMessageRegistry = _globalMessageRegistry;
        instanceCreationFee = 0.01 ether;
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
        return _createInstanceInternal(
            _name, metadataURI, _creator, _vault, _symbol,
            _lines, _baseDuration, _timeBuffer, _bidIncrement,
            CreationTier.STANDARD
        );
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
        return _createInstanceInternal(
            _name, metadataURI, _creator, _vault, _symbol,
            _lines, _baseDuration, _timeBuffer, _bidIncrement,
            creationTier
        );
    }

    function _createInstanceInternal(
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
    ) internal returns (address instance) {
        // Determine fee based on tier
        TierConfig memory config = tierConfigs[creationTier];
        uint256 fee;
        if (config.fee > 0) {
            fee = config.fee;
        } else if (creationTier == CreationTier.STANDARD) {
            fee = instanceCreationFee;
        } else {
            revert("Tier not configured");
        }

        require(msg.value >= fee, "Insufficient fee");

        // Compute featured cost upfront so it can be forwarded (not accumulated)
        uint256 featuredCost = 0;
        if (config.featuredDuration > 0 && address(featuredQueueManager) != address(0)) {
            featuredCost = featuredQueueManager.quoteDurationCost(config.featuredDuration) + config.featuredRankBoost;
        }

        // Split the non-featured portion of the fee between protocol and creator
        uint256 creatorCut = ((fee - featuredCost) * creatorFeeBps) / 10000;
        uint256 protocolCut = fee - featuredCost - creatorCut;
        accumulatedCreatorFees += creatorCut;
        accumulatedProtocolFees += protocolCut;

        require(bytes(_name).length > 0, "Invalid name");
        require(_creator != address(0), "Invalid creator");
        require(_vault != address(0), "Invalid vault");
        require(_vault.code.length > 0, "Vault must be a contract");

        // Soft capability checks
        try IAlignmentVault(payable(_vault)).supportsCapability(keccak256("YIELD_GENERATION")) returns (bool supported) {
            if (!supported) {
                emit VaultCapabilityWarning(_vault, keccak256("YIELD_GENERATION"));
            }
        } catch {
            emit VaultCapabilityWarning(_vault, keccak256("YIELD_GENERATION"));
        }

        // Check namespace availability
        require(!masterRegistry.isNameTaken(_name), "Name already taken");

        // Deploy new instance
        instance = address(new ERC721AuctionInstance(
            _vault,
            protocolTreasury,
            _creator,
            _name,
            _symbol,
            _lines,
            _baseDuration,
            _timeBuffer,
            _bidIncrement,
            globalMessageRegistry
        ));

        // Register with master registry
        masterRegistry.registerInstance(
            instance,
            address(this),
            _creator,
            _name,
            metadataURI,
            _vault
        );

        // Apply tier perks
        if (config.featuredDuration > 0 && address(featuredQueueManager) != address(0) && featuredCost > 0) {
            featuredQueueManager.rentFeaturedFor{value: featuredCost}(
                instance, _creator, config.featuredDuration, config.featuredRankBoost
            );
        }

        if (config.badge != PromotionBadges.BadgeType.NONE && address(promotionBadges) != address(0)) {
            promotionBadges.assignBadgeFor(instance, config.badge, config.badgeDuration);
        }

        // Refund excess
        if (msg.value > fee) {
            SafeTransferLib.safeTransferETH(msg.sender, msg.value - fee);
        }

        emit InstanceCreated(instance, _creator, _name, _vault);

        if (creationTier != CreationTier.STANDARD) {
            emit InstanceCreatedWithTier(instance, creationTier, fee);
        }
    }

    // ┌─────────────────────────┐
    // │     Admin Functions     │
    // └─────────────────────────┘

    function setInstanceCreationFee(uint256 _fee) external onlyOwner {
        instanceCreationFee = _fee;
        emit InstanceCreationFeeUpdated(_fee);
    }

    function setTierConfig(CreationTier tier, TierConfig calldata config) external onlyOwner {
        require(config.fee > 0, "Fee must be positive");
        tierConfigs[tier] = config;
        emit TierConfigUpdated(tier, config.fee);
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

    function withdrawCreatorFees() external {
        require(msg.sender == creator, "Only creator");
        uint256 amount = accumulatedCreatorFees;
        require(amount > 0, "No creator fees");
        accumulatedCreatorFees = 0;
        SafeTransferLib.safeTransferETH(creator, amount);
        emit CreatorFeesWithdrawn(creator, amount);
    }

    function protocol() external view returns (address) {
        return owner();
    }
}
