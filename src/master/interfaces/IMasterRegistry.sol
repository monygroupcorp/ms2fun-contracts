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

    struct RentalSlot {
        address instance;
        address renter;
        uint256 rentPaid;
        uint256 rentedAt;
        uint256 expiresAt;
        uint256 originalPosition;
        bool active;
    }

    struct VaultInfo {
        address vault;
        address creator;
        string name;
        string metadataURI;
        bool active;
        uint256 registeredAt;
        uint256 targetId;
    }

    struct AlignmentTarget {
        uint256 id;
        string title;
        string description;
        string metadataURI;
        uint256 approvedAt;
        bool active;
    }

    struct AlignmentAsset {
        address token;
        string symbol;
        string info;
        string metadataURI;
    }

    struct InstanceInfo {
        address instance;
        address factory;
        address creator;
        address vault;
        string name;
        string metadataURI;
        bytes32 nameHash;
        uint256 registeredAt;
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

    event PositionRented(
        address indexed instance,
        address indexed renter,
        uint256 position,
        uint256 cost,
        uint256 duration,
        uint256 expiresAt
    );

    event PositionShifted(address indexed instance, uint256 oldPosition, uint256 newPosition);

    event PositionBumped(
        address indexed instance,
        uint256 fromPosition,
        uint256 toPosition,
        uint256 cost,
        uint256 additionalDuration
    );

    event PositionRenewed(
        address indexed instance,
        uint256 position,
        uint256 additionalDuration,
        uint256 cost,
        uint256 newExpiresAt
    );

    event PositionAutoRenewed(address indexed instance, uint256 position, uint256 cost, uint256 newExpiresAt);

    event RentalExpired(address indexed instance, uint256 position, uint256 expiredAt);

    event AutoRenewalDeposited(address indexed instance, address indexed depositor, uint256 amount);

    event RenewalDepositWithdrawn(address indexed instance, address indexed recipient, uint256 amount);

    event CleanupRewardPaid(address indexed caller, uint256 cleanedCount, uint256 renewedCount, uint256 reward);

    event VaultRegistered(
        address indexed vault,
        address indexed creator,
        string name,
        uint256 indexed targetId
    );

    event VaultDeactivated(address indexed vault);

    event AlignmentTargetRegistered(uint256 indexed targetId, string title);
    event AlignmentTargetDeactivated(uint256 indexed targetId);
    event AlignmentTargetUpdated(uint256 indexed targetId);
    event AmbassadorAdded(uint256 indexed targetId, address indexed ambassador);
    event AmbassadorRemoved(uint256 indexed targetId, address indexed ambassador);

    // Functions
    // applyForFactory removed in owner-only rework

    function registerInstance(
        address instance,
        address factory,
        address creator,
        string memory name,
        string memory metadataURI,
        address vault
    ) external;

    // getFactoryApplication removed in owner-only rework

    function getFactoryInfo(
        uint256 factoryId
    ) external view returns (FactoryInfo memory);

    function getFactoryInfoByAddress(
        address factoryAddress
    ) external view returns (FactoryInfo memory);

    function getTotalFactories() external view returns (uint256);

    function getInstanceInfo(address instance) external view returns (InstanceInfo memory);

    // Note: Competitive Rental Queue Functions moved to FeaturedQueueManager

    // Vault Registry Functions
    function registerVault(
        address vault,
        string memory name,
        string memory metadataURI,
        uint256 targetId
    ) external;

    function getVaultInfo(address vault) external view returns (VaultInfo memory);

    function isVaultRegistered(address vault) external view returns (bool);

    function deactivateVault(address vault) external;

    // Alignment Target Functions
    function registerAlignmentTarget(
        string memory title,
        string memory description,
        string memory metadataURI,
        AlignmentAsset[] memory assets
    ) external returns (uint256);

    function getAlignmentTarget(uint256 targetId) external view returns (AlignmentTarget memory);

    function getAlignmentTargetAssets(uint256 targetId) external view returns (AlignmentAsset[] memory);

    function isAlignmentTargetActive(uint256 targetId) external view returns (bool);

    function isApprovedAlignmentToken(uint256 targetId, address token) external view returns (bool);

    function deactivateAlignmentTarget(uint256 targetId) external;

    function updateAlignmentTarget(
        uint256 targetId,
        string memory description,
        string memory metadataURI
    ) external;

    function addAmbassador(uint256 targetId, address ambassador) external;
    function removeAmbassador(uint256 targetId, address ambassador) external;
    function getAmbassadors(uint256 targetId) external view returns (address[] memory);
    function isAmbassador(uint256 targetId, address account) external view returns (bool);

    // Fee Configuration
    function vaultRegistrationFee() external view returns (uint256);

    // Global Messaging
    function getGlobalMessageRegistry() external view returns (address);

    // Factory Authorization
    function isInstanceFromApprovedFactory(address instance) external view returns (bool);

    // Namespace Protection
    function isNameTaken(string memory name) external view returns (bool);

}

