// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IMasterRegistry} from "../../master/interfaces/IMasterRegistry.sol";
import {FeatureUtils} from "../../master/libraries/FeatureUtils.sol";
import {IAlignmentVault} from "../../interfaces/IAlignmentVault.sol";
import {IFactory} from "../../interfaces/IFactory.sol";
import {ERC404BondingInstance} from "./ERC404BondingInstance.sol";
import {PromotionBadges} from "../../promotion/PromotionBadges.sol";
import {FeaturedQueueManager} from "../../master/FeaturedQueueManager.sol";

/**
 * @title ERC404Factory
 * @notice Factory contract for deploying ERC404 token instances with ultraalignment
 * @dev Requires vault to have its hook pre-configured (created via UltraAlignmentHookFactory.createVaultWithHook)
 */
contract ERC404Factory is Ownable, ReentrancyGuard, IFactory {
    IMasterRegistry public masterRegistry;
    address public instanceTemplate;
    uint256 public instanceCreationFee;
    address public v4PoolManager;
    address public weth;

    // Protocol revenue
    address public protocolTreasury;
    uint256 public bondingFeeBps = 100; // 1% default
    uint256 public graduationFeeBps = 200; // 2% default
    uint256 public polBps = 100; // 1% default — protocol-owned liquidity

    // Creator incentives
    address public immutable creator;
    uint256 public immutable creatorFeeBps;
    uint256 public immutable creatorGraduationFeeBps;
    uint256 public accumulatedCreatorFees;
    uint256 public accumulatedProtocolFees;

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

    // Feature matrix
    bytes32[] public features = [
        FeatureUtils.BONDING_CURVE,
        FeatureUtils.LIQUIDITY_POOL,
        FeatureUtils.CHAT,
        FeatureUtils.BALANCE_MINT,
        FeatureUtils.PORTFOLIO
    ];

    event InstanceCreated(
        address indexed instance,
        address indexed creator,
        string name,
        string symbol,
        address indexed vault,
        address hook
    );
    event InstanceCreationFeeUpdated(uint256 newFee);
    event VaultCapabilityWarning(address indexed vault, bytes32 indexed capability);
    event ProtocolTreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event ProtocolFeesWithdrawn(address indexed treasury, uint256 amount);
    event CreatorFeesWithdrawn(address indexed creator, uint256 amount);
    event BondingFeeUpdated(uint256 newBps);
    event GraduationFeeUpdated(uint256 newBps);
    event POLConfigUpdated(uint256 newBps);
    event TierConfigUpdated(CreationTier tier, uint256 fee);
    event InstanceCreatedWithTier(address indexed instance, CreationTier tier, uint256 fee);

    constructor(
        address _masterRegistry,
        address _instanceTemplate,
        address _v4PoolManager,
        address _weth,
        address _creator,
        uint256 _creatorFeeBps,
        uint256 _creatorGraduationFeeBps
    ) {
        _initializeOwner(msg.sender);
        require(_creatorFeeBps <= 10000, "Invalid creator fee bps");
        require(_creatorGraduationFeeBps <= graduationFeeBps, "Creator grad fee exceeds graduation fee");
        creator = _creator;
        creatorFeeBps = _creatorFeeBps;
        creatorGraduationFeeBps = _creatorGraduationFeeBps;
        masterRegistry = IMasterRegistry(_masterRegistry);
        instanceTemplate = _instanceTemplate;
        v4PoolManager = _v4PoolManager;
        weth = _weth;
        instanceCreationFee = 0.01 ether;
    }

    /**
     * @notice Create a new ERC404 bonding instance (backward-compatible, defaults to STANDARD tier)
     */
    function createInstance(
        string memory name,
        string memory symbol,
        string memory metadataURI,
        uint256 maxSupply,
        uint256 liquidityReservePercent,
        ERC404BondingInstance.BondingCurveParams memory curveParams,
        ERC404BondingInstance.TierConfig memory tierConfig,
        address creator,
        address vault,
        address hook,
        string memory styleUri
    ) external payable nonReentrant returns (address instance) {
        return _createInstanceInternal(
            name, symbol, metadataURI, maxSupply, liquidityReservePercent,
            curveParams, tierConfig, creator, vault, hook, styleUri,
            CreationTier.STANDARD
        );
    }

    /**
     * @notice Create a new ERC404 bonding instance with a specific creation tier
     */
    function createInstance(
        string memory name,
        string memory symbol,
        string memory metadataURI,
        uint256 maxSupply,
        uint256 liquidityReservePercent,
        ERC404BondingInstance.BondingCurveParams memory curveParams,
        ERC404BondingInstance.TierConfig memory tierConfig,
        address creator,
        address vault,
        address hook,
        string memory styleUri,
        CreationTier creationTier
    ) external payable nonReentrant returns (address instance) {
        return _createInstanceInternal(
            name, symbol, metadataURI, maxSupply, liquidityReservePercent,
            curveParams, tierConfig, creator, vault, hook, styleUri,
            creationTier
        );
    }

    function _createInstanceInternal(
        string memory name,
        string memory symbol,
        string memory metadataURI,
        uint256 maxSupply,
        uint256 liquidityReservePercent,
        ERC404BondingInstance.BondingCurveParams memory curveParams,
        ERC404BondingInstance.TierConfig memory tierConfig,
        address instanceCreator,
        address vault,
        address hook,
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
        {
            uint256 creatorCut = (fee * creatorFeeBps) / 10000;
            uint256 protocolCut = fee - creatorCut;
            accumulatedCreatorFees += creatorCut;
            accumulatedProtocolFees += protocolCut;
        }

        require(bytes(name).length > 0, "Invalid name");
        require(bytes(symbol).length > 0, "Invalid symbol");
        require(maxSupply > 0, "Invalid supply");
        require(instanceCreator != address(0), "Invalid creator");
        require(v4PoolManager != address(0), "V4 pool manager not set");
        require(weth != address(0), "WETH not set");

        // Check namespace availability before deploying (saves gas on collision)
        require(!masterRegistry.isNameTaken(name), "Name already taken");

        // Vault and hook are required for ultraalignment
        require(vault != address(0), "Vault required for ultraalignment");
        require(vault.code.length > 0, "Vault must be a contract");
        require(hook != address(0), "Hook required for ultraalignment");
        require(hook.code.length > 0, "Hook must be a contract");

        // Soft capability checks — emit warnings, never revert
        try IAlignmentVault(payable(vault)).supportsCapability(keccak256("YIELD_GENERATION")) returns (bool supported) {
            if (!supported) {
                emit VaultCapabilityWarning(vault, keccak256("YIELD_GENERATION"));
            }
        } catch {
            emit VaultCapabilityWarning(vault, keccak256("YIELD_GENERATION"));
        }

        // Deploy new bonding instance WITH hook address (enforced alignment)
        instance = address(new ERC404BondingInstance(
            name,
            symbol,
            maxSupply,
            liquidityReservePercent,
            curveParams,
            tierConfig,
            v4PoolManager,
            hook,
            weth,
            address(this),
            address(masterRegistry),
            vault,
            instanceCreator,
            styleUri,
            protocolTreasury,
            bondingFeeBps,
            graduationFeeBps,
            polBps,
            creator,
            creatorGraduationFeeBps
        ));

        // Register with master registry
        masterRegistry.registerInstance(
            instance,
            address(this),
            instanceCreator,
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

        emit InstanceCreated(instance, instanceCreator, name, symbol, vault, hook);

        if (creationTier != CreationTier.STANDARD) {
            emit InstanceCreatedWithTier(instance, creationTier, fee);
        }
    }

    /**
     * @notice Get factory features
     */
    function getFeatures() external view returns (bytes32[] memory) {
        return features;
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

    function setBondingFeeBps(uint256 _bps) external onlyOwner {
        require(_bps <= 300, "Max 3%");
        bondingFeeBps = _bps;
        emit BondingFeeUpdated(_bps);
    }

    function setGraduationFeeBps(uint256 _bps) external onlyOwner {
        require(_bps <= 500, "Max 5%");
        graduationFeeBps = _bps;
        emit GraduationFeeUpdated(_bps);
    }

    function setPolBps(uint256 _bps) external onlyOwner {
        require(_bps <= 300, "Max 3%");
        polBps = _bps;
        emit POLConfigUpdated(_bps);
    }
}
