// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IMasterRegistry} from "../../master/interfaces/IMasterRegistry.sol";
import {ERC1155Instance} from "./ERC1155Instance.sol";
import {IAlignmentVault} from "../../interfaces/IAlignmentVault.sol";
import {IFactory} from "../../interfaces/IFactory.sol";
import {PromotionBadges} from "../../promotion/PromotionBadges.sol";
import {FeaturedQueueManager} from "../../master/FeaturedQueueManager.sol";
import {IComponentRegistry} from "../../registry/interfaces/IComponentRegistry.sol";

/**
 * @title ERC1155Factory
 * @notice Factory contract for deploying ERC1155 token instances for open edition artists
 */
contract ERC1155Factory is Ownable, ReentrancyGuard, IFactory {
    IMasterRegistry public masterRegistry;
    address public immutable globalMessageRegistry;
    IComponentRegistry public immutable componentRegistry;
    address public instanceTemplate;

    // Protocol revenue
    address public protocolTreasury;
    uint256 public accumulatedProtocolFees;

    // Trusted agents that can add editions on behalf of users
    mapping(address => bool) public isAgent;

    // Tiered creation
    enum CreationTier { STANDARD, PREMIUM, LAUNCH }

    struct TierConfig {
        uint256 featuredDuration;    // 0 = no featured placement
        uint256 featuredRankBoost;   // ETH allocated to rank score (0 = duration only)
        PromotionBadges.BadgeType badge; // NONE = no badge
        uint256 badgeDuration;       // 0 = no badge
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

    event EditionAdded(
        address indexed instance,
        uint256 indexed editionId,
        string pieceTitle,
        uint256 basePrice,
        uint256 supply,
        ERC1155Instance.PricingModel pricingModel
    );
    event ProtocolTreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event ProtocolFeesWithdrawn(address indexed treasury, uint256 amount);
    event TierConfigUpdated(CreationTier tier);
    event InstanceCreatedWithTier(address indexed instance, CreationTier tier);
    event AgentUpdated(address indexed agent, bool authorized);

    constructor(
        address _masterRegistry,
        address _instanceTemplate,
        address _globalMessageRegistry,
        address _componentRegistry
    ) {
        _initializeOwner(msg.sender);
        require(_globalMessageRegistry != address(0), "Invalid global message registry");
        masterRegistry = IMasterRegistry(_masterRegistry);
        globalMessageRegistry = _globalMessageRegistry;
        componentRegistry = IComponentRegistry(_componentRegistry);
        instanceTemplate = _instanceTemplate;
    }

    /**
     * @notice Create a new ERC1155 instance (backward-compatible, defaults to STANDARD tier)
     */
    function createInstance(
        string memory name,
        string memory metadataURI,
        address creator,
        address vault,
        string memory styleUri
    ) external payable nonReentrant returns (address instance) {
        return _createInstanceInternal(name, metadataURI, creator, vault, styleUri, CreationTier.STANDARD, address(0));
    }

    /**
     * @notice Create a new ERC1155 instance with a specific creation tier
     */
    function createInstance(
        string memory name,
        string memory metadataURI,
        address creator,
        address vault,
        string memory styleUri,
        CreationTier creationTier
    ) external payable nonReentrant returns (address instance) {
        return _createInstanceInternal(name, metadataURI, creator, vault, styleUri, creationTier, address(0));
    }

    /**
     * @notice Create a new ERC1155 instance with a gating component.
     * @param gatingModule address(0) = open; otherwise must be approved in ComponentRegistry.
     */
    function createInstance(
        string memory name,
        string memory metadataURI,
        address creator,
        address vault,
        string memory styleUri,
        address gatingModule
    ) external payable nonReentrant returns (address instance) {
        if (gatingModule != address(0)) {
            require(componentRegistry.isApprovedComponent(gatingModule), "Unapproved component");
        }
        return _createInstanceInternal(name, metadataURI, creator, vault, styleUri, CreationTier.STANDARD, gatingModule);
    }

    function _createInstanceInternal(
        string memory name,
        string memory metadataURI,
        address creator,
        address vault,
        string memory styleUri,
        CreationTier creationTier,
        address gatingModule
    ) internal returns (address instance) {
        TierConfig memory config = tierConfigs[creationTier];

        // Compute featured cost upfront so it can be forwarded (not accumulated)
        uint256 featuredCost = 0;
        if (config.featuredDuration > 0 && address(featuredQueueManager) != address(0)) {
            featuredCost = featuredQueueManager.quoteDurationCost(config.featuredDuration) + config.featuredRankBoost;
        }

        require(msg.value >= featuredCost, "Insufficient featured fee");

        // All non-featured payment goes to protocol
        accumulatedProtocolFees += msg.value - featuredCost;

        require(bytes(name).length > 0, "Invalid name");
        require(creator != address(0), "Invalid creator");
        require(vault != address(0), "Invalid vault");
        require(vault.code.length > 0, "Vault must be a contract");

        // Soft capability checks — emit warnings, never revert
        try IAlignmentVault(payable(vault)).supportsCapability(keccak256("YIELD_GENERATION")) returns (bool supported) {
            if (!supported) {
                emit VaultCapabilityWarning(vault, keccak256("YIELD_GENERATION"));
            }
        } catch {
            emit VaultCapabilityWarning(vault, keccak256("YIELD_GENERATION"));
        }

        // Check namespace availability before deploying (saves gas on collision)
        require(!masterRegistry.isNameTaken(name), "Name already taken");

        instance = _deployAndRegister(name, metadataURI, creator, vault, styleUri, gatingModule);

        // Apply tier perks AFTER successful deployment and registration
        if (config.featuredDuration > 0 && address(featuredQueueManager) != address(0) && featuredCost > 0) {
            featuredQueueManager.rentFeaturedFor{value: featuredCost}(
                instance, creator, config.featuredDuration, config.featuredRankBoost
            );
        }

        if (config.badge != PromotionBadges.BadgeType.NONE && address(promotionBadges) != address(0)) {
            promotionBadges.assignBadgeFor(instance, config.badge, config.badgeDuration);
        }

        emit InstanceCreated(instance, creator, name, vault);

        if (creationTier != CreationTier.STANDARD) {
            emit InstanceCreatedWithTier(instance, creationTier);
        }
    }

    function _deployAndRegister(
        string memory name,
        string memory metadataURI,
        address creator,
        address vault,
        string memory styleUri,
        address gatingModule
    ) private returns (address instance) {
        instance = address(new ERC1155Instance(
            name,
            metadataURI,
            creator,
            address(this),
            vault,
            styleUri,
            globalMessageRegistry,
            protocolTreasury,
            address(masterRegistry),
            gatingModule
        ));
        masterRegistry.registerInstance(
            instance,
            address(this),
            creator,
            name,
            metadataURI,
            vault
        );
    }

    /**
     * @notice Add an edition to an instance
     */
    function addEdition(
        address instance,
        string memory pieceTitle,
        uint256 basePrice,
        uint256 supply,
        string memory metadataURI,
        ERC1155Instance.PricingModel pricingModel,
        uint256 priceIncreaseRate,
        uint256 openTime
    ) external returns (uint256 editionId) {
        require(isAgent[msg.sender], "Not authorized agent");
        ERC1155Instance instanceContract = ERC1155Instance(instance);

        instanceContract.addEdition(
            pieceTitle,
            basePrice,
            supply,
            metadataURI,
            pricingModel,
            priceIncreaseRate,
            openTime
        );

        editionId = instanceContract.nextEditionId() - 1;

        emit EditionAdded(instance, editionId, pieceTitle, basePrice, supply, pricingModel);
    }

    /**
     * @notice Set tier configuration (owner only)
     */
    function setTierConfig(CreationTier tier, TierConfig calldata config) external onlyOwner {
        tierConfigs[tier] = config;
        emit TierConfigUpdated(tier);
    }

    /**
     * @notice Set PromotionBadges contract reference
     */
    function setPromotionBadges(address _promotionBadges) external onlyOwner {
        promotionBadges = PromotionBadges(_promotionBadges);
    }

    /**
     * @notice Set FeaturedQueueManager contract reference
     */
    function setFeaturedQueueManager(address _featuredQueueManager) external onlyOwner {
        featuredQueueManager = FeaturedQueueManager(payable(_featuredQueueManager));
    }

    /**
     * @notice Set agent authorization (owner only)
     */
    function setAgent(address agent, bool authorized) external onlyOwner {
        isAgent[agent] = authorized;
        emit AgentUpdated(agent, authorized);
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
}
