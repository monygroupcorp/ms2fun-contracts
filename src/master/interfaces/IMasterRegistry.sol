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

    struct PositionDemand {
        uint256 lastRentalPrice;
        uint256 lastRentalTime;
        uint256 totalRentalsAllTime;
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

    function getInstanceInfo(address instance) external view returns (InstanceInfo memory);

    // Note: Competitive Rental Queue Functions moved to FeaturedQueueManager

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

    // Global Messaging
    function getGlobalMessageRegistry() external view returns (address);

    // Factory Authorization
    function isInstanceFromApprovedFactory(address instance) external view returns (bool);
}

