// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UUPSUpgradeable} from "solady/utils/UUPSUpgradeable.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";

/**
 * @title FactoryApprovalGovernance
 * @notice Handles factory application submissions and EXEC token holder voting
 * @dev Separate governance module for MasterRegistry (Phase 1+)
 *
 * This contract manages:
 * - Factory application submissions with fee
 * - EXEC token weighted voting
 * - Application finalization and registration in MasterRegistry
 *
 * Upgradeable via UUPS pattern for Phase 2 enhancements:
 * - Multi-token voting weights
 * - Delegation mechanics
 * - Tiered voting power
 */
contract FactoryApprovalGovernance is UUPSUpgradeable, Ownable, ReentrancyGuard {
    // Constants
    uint256 public constant APPLICATION_FEE = 0.1 ether;
    uint256 public constant QUORUM_THRESHOLD = 1000e18; // 1000 EXEC tokens

    // Enums
    enum ApplicationStatus {
        Pending,
        Approved,
        Rejected,
        Withdrawn
    }

    // Structs
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
        uint256 approvalVotes;
        uint256 rejectionVotes;
        string rejectionReason;
    }

    // State variables
    address public masterRegistry;
    address public execToken;
    uint256 public applicationFee;

    // Mappings
    mapping(address => FactoryApplication) public applications;
    mapping(address => mapping(address => bool)) public hasVoted; // factory => voter => voted
    mapping(address => address[]) public voters; // factory => voters[]

    // Events
    event ApplicationSubmitted(
        address indexed factory,
        address indexed applicant,
        string contractType,
        uint256 fee
    );
    event VoteCast(
        address indexed factory,
        address indexed voter,
        bool approve,
        uint256 votingPower
    );
    event ApplicationFinalized(
        address indexed factory,
        ApplicationStatus status
    );
    event FactoryRegisteredInMasterRegistry(
        address indexed factory,
        uint256 factoryId
    );
    event ExecutTokenSet(address indexed newToken);
    event MasterRegistrySet(address indexed newRegistry);

    // Constructor
    constructor() {
        // Don't initialize owner here - let initialize() do it
    }

    /**
     * @notice Initialize the contract
     * @param _execToken Address of EXEC token
     * @param _masterRegistry Address of MasterRegistry
     * @param _owner Owner address
     */
    function initialize(
        address _execToken,
        address _masterRegistry,
        address _owner
    ) public {
        require(_execToken != address(0), "Invalid EXEC token");
        require(_masterRegistry != address(0), "Invalid MasterRegistry");
        require(_owner != address(0), "Invalid owner");
        require(owner() == address(0), "Already initialized");

        _initializeOwner(_owner);
        execToken = _execToken;
        masterRegistry = _masterRegistry;
        applicationFee = APPLICATION_FEE;
    }

    /**
     * @notice Submit factory application
     * @param factoryAddress Address of the factory
     * @param contractType Type of contract (e.g., "ERC404", "ERC1155")
     * @param title Title for the factory
     * @param displayTitle Display title
     * @param metadataURI URI for metadata
     * @param features Array of feature hashes
     */
    function submitApplication(
        address factoryAddress,
        string memory contractType,
        string memory title,
        string memory displayTitle,
        string memory metadataURI,
        bytes32[] memory features
    ) external payable nonReentrant {
        _submitApplicationInternal(factoryAddress, contractType, title, displayTitle, metadataURI, features, msg.sender);
    }

    /**
     * @notice Submit factory application with explicit applicant (called by MasterRegistry)
     */
    function submitApplicationWithApplicant(
        address factoryAddress,
        string memory contractType,
        string memory title,
        string memory displayTitle,
        string memory metadataURI,
        bytes32[] memory features,
        address applicant
    ) external payable nonReentrant {
        require(msg.sender == masterRegistry, "Only MasterRegistry");
        _submitApplicationInternal(factoryAddress, contractType, title, displayTitle, metadataURI, features, applicant);
    }

    function _submitApplicationInternal(
        address factoryAddress,
        string memory contractType,
        string memory title,
        string memory displayTitle,
        string memory metadataURI,
        bytes32[] memory features,
        address applicant
    ) internal {
        require(factoryAddress != address(0), "Invalid factory address");
        require(bytes(contractType).length > 0, "Invalid contract type");
        require(msg.value >= applicationFee, "Insufficient application fee");
        require(
            applications[factoryAddress].applicant == address(0) ||
            applications[factoryAddress].status == ApplicationStatus.Withdrawn ||
            applications[factoryAddress].status == ApplicationStatus.Rejected,
            "Application already exists"
        );

        applications[factoryAddress] = FactoryApplication({
            factoryAddress: factoryAddress,
            applicant: applicant,
            contractType: contractType,
            title: title,
            displayTitle: displayTitle,
            metadataURI: metadataURI,
            features: features,
            status: ApplicationStatus.Pending,
            applicationFee: msg.value,
            createdAt: block.timestamp,
            approvalVotes: 0,
            rejectionVotes: 0,
            rejectionReason: ""
        });

        // Refund excess - send to applicant
        if (msg.value > applicationFee) {
            payable(applicant).transfer(msg.value - applicationFee);
        }

        emit ApplicationSubmitted(factoryAddress, applicant, contractType, msg.value);
    }

    /**
     * @notice Vote on factory application
     * @param factoryAddress Address of the factory
     * @param approve True to approve, false to reject
     */
    function voteOnApplication(address factoryAddress, bool approve) external nonReentrant {
        _voteOnApplicationWithVoter(factoryAddress, msg.sender, approve);
    }

    /**
     * @notice Vote on factory application (with explicit voter address)
     * @param factoryAddress Address of the factory
     * @param voter The actual voter address
     * @param approve True to approve, false to reject
     */
    function voteOnApplicationWithVoter(address factoryAddress, address voter, bool approve) external nonReentrant {
        require(msg.sender == masterRegistry, "Only MasterRegistry can call");
        _voteOnApplicationWithVoter(factoryAddress, voter, approve);
    }

    /**
     * @notice Internal vote implementation
     */
    function _voteOnApplicationWithVoter(address factoryAddress, address voter, bool approve) internal {
        FactoryApplication storage app = applications[factoryAddress];
        require(app.applicant != address(0), "Application not found");
        require(app.status == ApplicationStatus.Pending, "Application not pending");
        require(!hasVoted[factoryAddress][voter], "Already voted");

        // Get voting power from EXEC token balance
        uint256 votingPower = IERC20(execToken).balanceOf(voter);
        require(votingPower > 0, "No voting power");

        hasVoted[factoryAddress][voter] = true;
        voters[factoryAddress].push(voter);

        if (approve) {
            app.approvalVotes += votingPower;
        } else {
            app.rejectionVotes += votingPower;
        }

        emit VoteCast(factoryAddress, voter, approve, votingPower);
    }

    /**
     * @notice Finalize application (called by MasterRegistry)
     * @param factoryAddress Address of the factory
     */
    function finalizeApplication(address factoryAddress) external nonReentrant {
        require(msg.sender == masterRegistry || msg.sender == owner(), "Only MasterRegistry or owner");
        FactoryApplication storage app = applications[factoryAddress];
        require(app.applicant != address(0), "Application not found");
        require(app.status == ApplicationStatus.Pending, "Application not pending");

        bool approved = app.approvalVotes >= QUORUM_THRESHOLD &&
            app.approvalVotes > app.rejectionVotes;

        if (approved) {
            app.status = ApplicationStatus.Approved;

            // Register in MasterRegistry with applicant as creator
            IMasterRegistry(masterRegistry).registerFactoryWithFeaturesAndCreator(
                factoryAddress,
                app.contractType,
                app.title,
                app.displayTitle,
                app.metadataURI,
                app.features,
                app.applicant
            );

            emit ApplicationFinalized(factoryAddress, ApplicationStatus.Approved);
        } else {
            app.status = ApplicationStatus.Rejected;
            app.rejectionReason = "Quorum not met or rejected";
            emit ApplicationFinalized(factoryAddress, ApplicationStatus.Rejected);
            revert("Quorum not met or rejected");
        }
    }

    /**
     * @notice Withdraw application (applicant only)
     * @param factoryAddress Address of the factory
     */
    function withdrawApplication(address factoryAddress) external nonReentrant {
        FactoryApplication storage app = applications[factoryAddress];
        require(app.applicant == msg.sender, "Not applicant");
        require(app.status == ApplicationStatus.Pending, "Application not pending");

        app.status = ApplicationStatus.Withdrawn;

        // Refund fee
        payable(msg.sender).transfer(app.applicationFee);

        emit ApplicationFinalized(factoryAddress, ApplicationStatus.Withdrawn);
    }

    /**
     * @notice Get application details
     */
    function getApplication(address factoryAddress)
        external
        view
        returns (FactoryApplication memory)
    {
        return applications[factoryAddress];
    }

    /**
     * @notice Get application status
     */
    function getApplicationStatus(address factoryAddress)
        external
        view
        returns (ApplicationStatus)
    {
        return applications[factoryAddress].status;
    }

    /**
     * @notice Check if voter has voted
     */
    function hasVoterVoted(address factoryAddress, address voter)
        external
        view
        returns (bool)
    {
        return hasVoted[factoryAddress][voter];
    }

    /**
     * @notice Get number of voters
     */
    function getVoterCount(address factoryAddress) external view returns (uint256) {
        return voters[factoryAddress].length;
    }

    /**
     * @notice Set EXEC token (owner only)
     */
    function setExecToken(address newToken) external onlyOwner {
        require(newToken != address(0), "Invalid token");
        execToken = newToken;
        emit ExecutTokenSet(newToken);
    }

    /**
     * @notice Set MasterRegistry (owner only)
     */
    function setMasterRegistry(address newRegistry) external onlyOwner {
        require(newRegistry != address(0), "Invalid registry");
        masterRegistry = newRegistry;
        emit MasterRegistrySet(newRegistry);
    }

    /**
     * @notice Authorize upgrade (UUPS)
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}

// Minimal interfaces
interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
}

interface IMasterRegistry {
    function registerFactory(
        address factoryAddress,
        string memory contractType,
        string memory title,
        string memory displayTitle,
        string memory metadataURI
    ) external;

    function registerFactoryWithFeatures(
        address factoryAddress,
        string memory contractType,
        string memory title,
        string memory displayTitle,
        string memory metadataURI,
        bytes32[] memory features
    ) external;

    function registerFactoryWithFeaturesAndCreator(
        address factoryAddress,
        string memory contractType,
        string memory title,
        string memory displayTitle,
        string memory metadataURI,
        bytes32[] memory features,
        address creator
    ) external;
}
