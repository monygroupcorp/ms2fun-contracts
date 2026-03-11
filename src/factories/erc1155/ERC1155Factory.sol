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
import {FeatureUtils} from "../../master/libraries/FeatureUtils.sol";
import {FreeMintParams} from "../../interfaces/IFactoryTypes.sol";
import {GatingScope} from "../../gating/IGatingModule.sol";
import {ICreateX, CREATEX} from "../../shared/CreateXConstants.sol";

/**
 * @title ERC1155Factory
 * @notice Factory contract for deploying ERC1155 token instances for open edition artists
 */
contract ERC1155Factory is Ownable, ReentrancyGuard, IFactory {
    error InvalidAddress();
    error UnapprovedComponent();
    error InsufficientPayment();
    error InvalidName();
    error VaultMustBeContract();
    error NameAlreadyTaken();
    error TreasuryNotSet();
    error NoProtocolFees();
    error NotAuthorizedAgent();

    // slither-disable-next-line immutable-states
    IMasterRegistry public masterRegistry;
    address public immutable globalMessageRegistry;
    IComponentRegistry public immutable componentRegistry;
    // slither-disable-next-line immutable-states
    address public instanceTemplate;
    address public dynamicPricingModule;

    // Protocol revenue
    address public protocolTreasury;
    uint256 public accumulatedProtocolFees;

    // Pluggable component tags
    bytes32[] internal _features;

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
    constructor(
        address _masterRegistry,
        // slither-disable-next-line missing-zero-check
        address _instanceTemplate,
        address _globalMessageRegistry,
        address _componentRegistry
    ) {
        _initializeOwner(msg.sender);
        if (_globalMessageRegistry == address(0)) revert InvalidAddress();
        masterRegistry = IMasterRegistry(_masterRegistry);
        globalMessageRegistry = _globalMessageRegistry;
        componentRegistry = IComponentRegistry(_componentRegistry);
        instanceTemplate = _instanceTemplate;
        _features.push(FeatureUtils.GATING);
    }

    /**
     * @notice Create a new ERC1155 instance (backward-compatible, defaults to STANDARD tier)
     */
    function createInstance(
        bytes32 salt,
        string memory name,
        string memory metadataURI,
        address creator,
        address vault,
        string memory styleUri
    ) external payable nonReentrant returns (address instance) {
        return _createInstanceInternal(salt, name, metadataURI, creator, vault, styleUri, CreationTier.STANDARD, address(0),
            FreeMintParams({ allocation: 0, scope: GatingScope.BOTH }));
    }

    /**
     * @notice Create a new ERC1155 instance with a specific creation tier
     */
    function createInstance(
        bytes32 salt,
        string memory name,
        string memory metadataURI,
        address creator,
        address vault,
        string memory styleUri,
        CreationTier creationTier
    ) external payable nonReentrant returns (address instance) {
        return _createInstanceInternal(salt, name, metadataURI, creator, vault, styleUri, creationTier, address(0),
            FreeMintParams({ allocation: 0, scope: GatingScope.BOTH }));
    }

    /**
     * @notice Create a new ERC1155 instance with a gating component.
     * @param gatingModule address(0) = open; otherwise must be approved in ComponentRegistry.
     */
    function createInstance(
        bytes32 salt,
        string memory name,
        string memory metadataURI,
        address creator,
        address vault,
        string memory styleUri,
        address gatingModule
    ) external payable nonReentrant returns (address instance) {
        if (gatingModule != address(0)) {
            if (!componentRegistry.isApprovedComponent(gatingModule)) revert UnapprovedComponent();
        }
        return _createInstanceInternal(salt, name, metadataURI, creator, vault, styleUri, CreationTier.STANDARD, gatingModule,
            FreeMintParams({ allocation: 0, scope: GatingScope.BOTH }));
    }

    /// @notice Create an instance with gating module and free mint configuration.
    function createInstance(
        bytes32 salt,
        string memory name,
        string memory metadataURI,
        address creator,
        address vault,
        string memory styleUri,
        address gatingModule,
        FreeMintParams calldata freeMint
    ) external payable nonReentrant returns (address instance) {
        if (gatingModule != address(0)) {
            if (!componentRegistry.isApprovedComponent(gatingModule)) revert UnapprovedComponent();
        }
        return _createInstanceInternal(salt, name, metadataURI, creator, vault, styleUri, CreationTier.STANDARD, gatingModule, freeMint);
    }

    function _createInstanceInternal(
        bytes32 salt,
        string memory name,
        string memory metadataURI,
        address creator,
        address vault,
        string memory styleUri,
        CreationTier creationTier,
        address gatingModule,
        FreeMintParams memory freeMint
    ) internal returns (address instance) {
        TierConfig memory config = tierConfigs[creationTier];

        // Compute featured cost upfront so it can be forwarded (not accumulated)
        uint256 featuredCost = 0;
        if (config.featuredDuration > 0 && address(featuredQueueManager) != address(0)) {
            featuredCost = featuredQueueManager.quoteDurationCost(config.featuredDuration) + config.featuredRankBoost;
        }

        if (msg.value < featuredCost) revert InsufficientPayment();

        // All non-featured payment goes to protocol
        accumulatedProtocolFees += msg.value - featuredCost;

        if (bytes(name).length == 0) revert InvalidName();
        if (creator == address(0)) revert InvalidAddress();
        if (vault == address(0)) revert InvalidAddress();
        if (vault.code.length == 0) revert VaultMustBeContract();

        // Agent-on-behalf-of check
        bool agentCreated = false;
        if (msg.sender != creator) {
            if (!masterRegistry.isAgent(msg.sender)) revert NotAuthorizedAgent();
            agentCreated = true;
        }

        // Soft capability check — emit warning if vault lacks yield generation, never revert
        { bytes32 _cap = keccak256("YIELD_GENERATION");
          try IAlignmentVault(payable(vault)).supportsCapability(_cap) returns (bool supported) {
              if (!supported) emit VaultCapabilityWarning(vault, _cap);
          } catch { emit VaultCapabilityWarning(vault, _cap); } }

        // Check namespace availability before deploying (saves gas on collision)
        if (masterRegistry.isNameTaken(name)) revert NameAlreadyTaken();

        instance = _deployAndRegister(salt, name, metadataURI, creator, vault, styleUri,
            ERC1155Instance.ComponentAddresses({ gatingModule: gatingModule, dynamicPricingModule: dynamicPricingModule }),
            agentCreated);
        // Wire free mint tranche (no-op when allocation == 0)
        ERC1155Instance(instance).initializeFreeMint(freeMint.allocation, freeMint.scope);

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
        bytes32 salt,
        string memory name,
        string memory metadataURI,
        address creator,
        address vault,
        string memory styleUri,
        ERC1155Instance.ComponentAddresses memory components,
        bool agentCreated
    ) private returns (address instance) {
        bytes memory initCode = abi.encodePacked(
            type(ERC1155Instance).creationCode,
            abi.encode(
                name, metadataURI, creator, address(this), vault, styleUri,
                globalMessageRegistry, protocolTreasury, address(masterRegistry),
                components, agentCreated
            )
        );
        instance = ICreateX(CREATEX).deployCreate3(salt, initCode);
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
    // slither-disable-next-line reentrancy-events
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
        if (!masterRegistry.isAgent(msg.sender)) revert NotAuthorizedAgent();
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

    /// @notice Set the default dynamic pricing module for new instances.
    ///         address(0) disables dynamic pricing for new deployments.
    /// @dev Module must be approved in ComponentRegistry under tag keccak256("dynamic_pricing").
    function setDynamicPricingModule(address module) external onlyOwner {
        if (module != address(0)) {
            if (!componentRegistry.isApprovedComponent(module)) revert UnapprovedComponent();
        }
        dynamicPricingModule = module;
    }

    function setProtocolTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert InvalidAddress();
        address old = protocolTreasury;
        protocolTreasury = _treasury;
        emit ProtocolTreasuryUpdated(old, _treasury);
    }

    function withdrawProtocolFees() external onlyOwner {
        if (protocolTreasury == address(0)) revert TreasuryNotSet();
        uint256 amount = accumulatedProtocolFees;
        if (amount == 0) revert NoProtocolFees();
        accumulatedProtocolFees = 0;
        SafeTransferLib.safeTransferETH(protocolTreasury, amount);
        emit ProtocolFeesWithdrawn(protocolTreasury, amount);
    }

    function protocol() external view returns (address) {
        return owner();
    }

    function features() external view returns (bytes32[] memory) {
        return _features;
    }

    function requiredFeatures() external pure returns (bytes32[] memory) {
        return new bytes32[](0);
    }

    /// @notice Preview the deterministic address for a given salt
    function computeInstanceAddress(bytes32 salt) external view returns (address) {
        bytes32 guardedSalt = keccak256(abi.encodePacked(uint256(uint160(address(this))), salt));
        return ICreateX(CREATEX).computeCreate3Address(guardedSalt, CREATEX);
    }
}
