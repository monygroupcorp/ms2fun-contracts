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

/**
 * @title ERC1155Factory
 * @notice Factory contract for deploying ERC1155 token instances for open edition artists
 */
contract ERC1155Factory is Ownable, ReentrancyGuard, IFactory {
    IMasterRegistry public masterRegistry;
    address public instanceTemplate;
    uint256 public instanceCreationFee;

    // Protocol revenue
    address public protocolTreasury;

    // Creator incentives
    address public immutable creator;
    uint256 public immutable creatorFeeBps;
    uint256 public accumulatedCreatorFees;
    uint256 public accumulatedProtocolFees;

    // Trusted agents that can add editions on behalf of users
    mapping(address => bool) public isAgent;

    // Tiered creation
    enum CreationTier { STANDARD, PREMIUM, LAUNCH }

    struct TierConfig {
        uint256 fee;
        uint256 featuredDuration;    // 0 = no featured placement
        uint256 featuredPosition;    // Position to place in queue (0 = no placement)
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

    event InstanceCreationFeeUpdated(uint256 newFee);
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
    event CreatorFeesWithdrawn(address indexed creator, uint256 amount);
    event TierConfigUpdated(CreationTier tier, uint256 fee);
    event InstanceCreatedWithTier(address indexed instance, CreationTier tier, uint256 fee);
    event AgentUpdated(address indexed agent, bool authorized);

    constructor(
        address _masterRegistry,
        address _instanceTemplate,
        address _creator,
        uint256 _creatorFeeBps
    ) {
        _initializeOwner(msg.sender);
        require(_creatorFeeBps <= 10000, "Invalid creator fee bps");
        creator = _creator;
        creatorFeeBps = _creatorFeeBps;
        masterRegistry = IMasterRegistry(_masterRegistry);
        instanceTemplate = _instanceTemplate;
        instanceCreationFee = 0.01 ether;
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
        return _createInstanceInternal(name, metadataURI, creator, vault, styleUri, CreationTier.STANDARD);
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
        return _createInstanceInternal(name, metadataURI, creator, vault, styleUri, creationTier);
    }

    function _createInstanceInternal(
        string memory name,
        string memory metadataURI,
        address creator,
        address vault,
        string memory styleUri,
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

        // Split fee between protocol and creator
        uint256 creatorCut = (fee * creatorFeeBps) / 10000;
        uint256 protocolCut = fee - creatorCut;
        accumulatedCreatorFees += creatorCut;
        accumulatedProtocolFees += protocolCut;

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

        // Deploy new instance
        instance = address(new ERC1155Instance(
            name,
            metadataURI,
            creator,
            address(this),
            vault,
            styleUri,
            address(masterRegistry),
            protocolTreasury
        ));

        // Register with master registry
        masterRegistry.registerInstance(
            instance,
            address(this),
            creator,
            name,
            metadataURI,
            vault
        );

        // Apply tier perks AFTER successful deployment and registration
        if (config.featuredDuration > 0 && address(featuredQueueManager) != address(0)) {
            featuredQueueManager.rentFeaturedPositionFor(
                instance, config.featuredPosition, config.featuredDuration
            );
        }

        if (config.badge != PromotionBadges.BadgeType.NONE && address(promotionBadges) != address(0)) {
            promotionBadges.assignBadgeFor(instance, config.badge, config.badgeDuration);
        }

        // Refund excess
        if (msg.value > fee) {
            SafeTransferLib.safeTransferETH(msg.sender, msg.value - fee);
        }

        emit InstanceCreated(instance, creator, name, vault);

        if (creationTier != CreationTier.STANDARD) {
            emit InstanceCreatedWithTier(instance, creationTier, fee);
        }
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
        uint256 priceIncreaseRate
    ) external returns (uint256 editionId) {
        require(isAgent[msg.sender], "Not authorized agent");
        ERC1155Instance instanceContract = ERC1155Instance(instance);

        instanceContract.addEdition(
            pieceTitle,
            basePrice,
            supply,
            metadataURI,
            pricingModel,
            priceIncreaseRate
        );

        editionId = instanceContract.nextEditionId() - 1;

        emit EditionAdded(instance, editionId, pieceTitle, basePrice, supply, pricingModel);
    }

    /**
     * @notice Set instance creation fee (owner only)
     */
    function setInstanceCreationFee(uint256 _fee) external onlyOwner {
        instanceCreationFee = _fee;
        emit InstanceCreationFeeUpdated(_fee);
    }

    /**
     * @notice Set tier configuration (owner only)
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
