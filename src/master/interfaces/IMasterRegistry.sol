// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IMasterRegistry
 * @notice Interface for the Master Registry contract
 */
interface IMasterRegistry {
    // Application System
    enum ApplicationStatus {
        Pending,
        Approved,
        Rejected,
        Withdrawn
    }

    struct FactoryApplication {
        address factoryAddress;
        address applicant;
        string contractType;
        string title;
        string displayTitle;
        string metadataURI;
        bytes32[] features;
        ApplicationStatus status;
        uint256 applicationFee;
        uint256 createdAt;
        uint256 totalVotes;
        uint256 approvalVotes;
        uint256 rejectionVotes;
        string rejectionReason;
        bool verified;
        string verificationURI;
    }

    struct FactoryInfo {
        address factoryAddress;
        uint256 factoryId;
        string contractType;
        string title;
        string displayTitle;
        string metadataURI;
        bytes32[] features;
        address creator;
        bool active;
        uint256 registeredAt;
    }

    struct FeaturedPromotion {
        address instance;
        address purchaser;
        uint256 tierIndex;
        uint256 pricePaid;
        uint256 purchasedAt;
        uint256 expiresAt;
    }

    struct TierPricingInfo {
        uint256 currentPrice;
        uint256 utilizationRate;
        uint256 demandFactor;
        uint256 lastPurchaseTime;
        uint256 totalPurchases;
    }

    struct VaultInfo {
        address vault;
        address creator;
        string name;
        string metadataURI;
        bool active;
        uint256 registeredAt;
        uint256 instanceCount; // Number of instances using this vault
    }

    // HookInfo removed - vaults now manage their own canonical hooks

    // Events
    event FactoryApplicationSubmitted(
        address indexed factoryAddress,
        address indexed applicant,
        string contractType,
        uint256 applicationFee
    );

    event VoteCast(
        address indexed factoryAddress,
        address indexed voter,
        bool approve,
        uint256 votingPower
    );

    event ApplicationFinalized(
        address indexed factoryAddress,
        ApplicationStatus status,
        uint256 factoryId
    );

    event FactoryRegistered(
        address indexed factoryAddress,
        uint256 indexed factoryId,
        string contractType
    );

    event InstanceRegistered(
        address indexed instance,
        address indexed factory,
        address indexed creator,
        string name
    );

    event FeaturedPromotionPurchased(
        address indexed instance,
        address indexed purchaser,
        uint256 indexed tierIndex,
        uint256 pricePaid
    );

    event VaultRegistered(
        address indexed vault,
        address indexed creator,
        string name,
        uint256 registrationFee
    );

    event VaultDeactivated(address indexed vault);

    // Functions
    function applyForFactory(
        address factoryAddress,
        string memory contractType,
        string memory title,
        string memory displayTitle,
        string memory metadataURI,
        bytes32[] memory features
    ) external payable;

    function voteOnApplication(
        address factoryAddress,
        bool approve
    ) external;

    function finalizeApplication(
        address factoryAddress
    ) external;

    function registerInstance(
        address instance,
        address factory,
        address creator,
        string memory name,
        string memory metadataURI,
        address vault
    ) external;

    function getFactoryApplication(
        address factoryAddress
    ) external view returns (FactoryApplication memory);

    function getFactoryInfo(
        uint256 factoryId
    ) external view returns (FactoryInfo memory);

    function getFactoryInfoByAddress(
        address factoryAddress
    ) external view returns (FactoryInfo memory);

    function getTotalFactories() external view returns (uint256);

    function getCurrentPrice(uint256 tierIndex) external view returns (uint256);

    function purchaseFeaturedPromotion(
        address instance,
        uint256 tierIndex
    ) external payable;

    function getTierPricingInfo(
        uint256 tierIndex
    ) external view returns (TierPricingInfo memory);

    // Vault Registry Functions
    function registerVault(
        address vault,
        string memory name,
        string memory metadataURI
    ) external payable;

    function getVaultInfo(address vault) external view returns (VaultInfo memory);

    function getVaultList() external view returns (address[] memory);

    function isVaultRegistered(address vault) external view returns (bool);

    function deactivateVault(address vault) external;

    // Fee Configuration
    function vaultRegistrationFee() external view returns (uint256);
}

