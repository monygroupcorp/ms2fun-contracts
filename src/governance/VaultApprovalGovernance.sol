// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UUPSUpgradeable} from "solady/utils/UUPSUpgradeable.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";

/**
 * @title VaultApprovalGovernance
 * @notice Deposit-based voting system with sequential challenge rounds for vault approvals
 * @dev High-volume governance system mirroring FactoryApprovalGovernance mechanics:
 *      - Deposit-based voting (no balanceOf exploitation)
 *      - Sequential challenge rounds (unlimited)
 *      - Cumulative challenge deposits (escalating capital requirements)
 *      - All tokens returned after resolution (no slashing)
 *      - Designed to maximize EXEC token volume and transfer tax collection
 *
 * Voting Flow:
 * 1. Initial Vote (7 days): EXEC tokens deposited to yay/nay
 * 2. Challenge Window (7 days): Anyone can challenge with deposit ≥ cumulative yay
 * 3. Challenge Vote (7 days): New vote round starts immediately
 * 4. Repeat challenges sequentially until:
 *    - Nay wins → Rejected
 *    - Yay wins → 3-day lame duck → Registration
 *
 * Vault-Specific Considerations:
 * - vaultType field for classification (e.g., "UniswapV4LP", "AaveYield")
 * - Must implement IAlignmentVault interface
 * - Risk profile assessment via governance
 * - Audit requirements for production vaults
 */
contract VaultApprovalGovernance is UUPSUpgradeable, Ownable, ReentrancyGuard {
    // ============ Constants ============

    uint256 public constant APPLICATION_FEE = 0.1 ether;
    uint256 public constant MIN_QUORUM = 500_000_000; // 500 EXEC NFTs (EXEC has 6 decimals)
    uint256 public constant MIN_DEPOSIT = 1_000_000; // 1 EXEC NFT minimum per vote

    uint256 public constant INITIAL_VOTING_PERIOD = 7 days;
    uint256 public constant CHALLENGE_WINDOW = 7 days;
    uint256 public constant CHALLENGE_VOTING_PERIOD = 7 days;
    uint256 public constant LAME_DUCK_PERIOD = 3 days;

    // ============ Enums ============

    enum ApplicationPhase {
        InitialVoting,      // 7-day initial vote
        ChallengeWindow,    // 7-day window to challenge (if yay won)
        ChallengeVoting,    // 7-day challenge vote
        LameDuck,           // 3-day final window before registration
        Approved,           // Ready for registration (permissionless)
        Rejected            // Failed vote or challenge
    }

    // ============ Structs ============

    struct VoteRound {
        uint256 roundIndex;
        uint256 yayDeposits;
        uint256 nayDeposits;
        uint256 startTime;
        uint256 endTime;
        address challenger;       // address(0) for initial round
        uint256 challengeDeposit; // EXEC deposited to initiate challenge
        bool resolved;
        bool yayWon;
    }

    struct VoteDeposit {
        uint256 amount;
        bool supportsApproval; // true = yay, false = nay
        bool withdrawn;
    }

    struct GovernanceMessage {
        address sender;
        uint128 packedData; // timestamp:32 | roundIndex:32 | actionType:8 | reserved:56
        string message;
    }

    enum MessageActionType {
        Application,    // Application submission
        Vote,          // Vote deposit
        Challenge      // Challenge initiation
    }

    struct VaultApplication {
        address vaultAddress;
        address applicant;
        string vaultType;        // Vault implementation type (e.g., "UniswapV4LP", "AaveYield")
        string title;
        string displayTitle;
        string metadataURI;
        bytes32[] features;      // Features (e.g., ["full-range-lp", "auto-compound"])
        ApplicationPhase phase;
        uint256 phaseDeadline;
        uint256 applicationFee;
        uint256 createdAt;
        uint256 cumulativeYayRequired; // Sum of all yay votes (for next challenge deposit)
        VoteRound[] rounds;
    }

    // ============ State Variables ============

    address public masterRegistry;
    address public execToken;
    uint256 public applicationFee;
    bool private _initialized;

    // Mappings
    mapping(address => VaultApplication) public applications;

    // vault => voter => roundIndex => deposit
    mapping(address => mapping(address => mapping(uint256 => VoteDeposit))) public deposits;

    // Message system
    mapping(uint256 => GovernanceMessage) public governanceMessages;
    uint256 public totalMessages;

    // ============ Events ============

    event ApplicationSubmitted(
        address indexed vault,
        address indexed applicant,
        string vaultType,
        uint256 fee,
        uint256 votingDeadline
    );

    event VoteDeposited(
        address indexed vault,
        uint256 indexed roundIndex,
        address indexed voter,
        bool approve,
        uint256 amount
    );

    event VoteDepositAdded(
        address indexed vault,
        uint256 indexed roundIndex,
        address indexed voter,
        uint256 additionalAmount,
        uint256 newTotal
    );

    event ChallengeInitiated(
        address indexed vault,
        uint256 indexed roundIndex,
        address indexed challenger,
        uint256 challengeDeposit,
        uint256 requiredDeposit,
        uint256 votingDeadline
    );

    event RoundFinalized(
        address indexed vault,
        uint256 indexed roundIndex,
        bool yayWon,
        uint256 yayVotes,
        uint256 nayVotes
    );

    event ApplicationApproved(
        address indexed vault,
        uint256 totalRounds,
        uint256 lameDuckDeadline
    );

    event ApplicationRejected(
        address indexed vault,
        uint256 indexed roundIndex,
        string reason
    );

    event ApplicationRegistered(
        address indexed vault,
        address indexed registrant
    );

    event DepositWithdrawn(
        address indexed vault,
        address indexed voter,
        uint256 totalAmount
    );

    event ExecutTokenSet(address indexed newToken);
    event MasterRegistrySet(address indexed newRegistry);

    event MessagePosted(
        uint256 indexed messageId,
        address indexed vault,
        address indexed sender,
        MessageActionType actionType,
        uint256 roundIndex
    );

    // ============ Constructor & Initialization ============

    constructor() {
        // Don't initialize owner here - let initialize() do it
    }

    function initialize(
        address _execToken,
        address _masterRegistry,
        address _owner
    ) public {
        require(!_initialized, "Already initialized");
        require(_execToken != address(0), "Invalid EXEC token");
        require(_masterRegistry != address(0), "Invalid MasterRegistry");
        require(_owner != address(0), "Invalid owner");

        _initialized = true;
        _initializeOwner(_owner);
        execToken = _execToken;
        masterRegistry = _masterRegistry;
        applicationFee = APPLICATION_FEE;
    }

    // ============ Application Submission ============

    function submitApplication(
        address vaultAddress,
        string memory vaultType,
        string memory title,
        string memory displayTitle,
        string memory metadataURI,
        bytes32[] memory features,
        string calldata message
    ) external payable nonReentrant {
        _submitApplicationInternal(
            vaultAddress,
            vaultType,
            title,
            displayTitle,
            metadataURI,
            features,
            msg.sender,
            message
        );
    }

    function submitApplicationWithApplicant(
        address vaultAddress,
        string memory vaultType,
        string memory title,
        string memory displayTitle,
        string memory metadataURI,
        bytes32[] memory features,
        address applicant
    ) external payable nonReentrant {
        require(msg.sender == masterRegistry, "Only MasterRegistry");
        _submitApplicationInternal(
            vaultAddress,
            vaultType,
            title,
            displayTitle,
            metadataURI,
            features,
            applicant,
            ""
        );
    }

    function _submitApplicationInternal(
        address vaultAddress,
        string memory vaultType,
        string memory title,
        string memory displayTitle,
        string memory metadataURI,
        bytes32[] memory features,
        address applicant,
        string memory message
    ) internal {
        require(vaultAddress != address(0), "Invalid vault address");
        require(bytes(vaultType).length > 0, "Invalid vault type");
        require(msg.value >= applicationFee, "Insufficient application fee");

        VaultApplication storage app = applications[vaultAddress];
        require(
            app.applicant == address(0) ||
            app.phase == ApplicationPhase.Approved ||
            app.phase == ApplicationPhase.Rejected,
            "Application already exists"
        );

        // Clear old application data if resubmitting
        if (app.applicant != address(0)) {
            delete applications[vaultAddress];
        }

        // Create new application
        app.vaultAddress = vaultAddress;
        app.applicant = applicant;
        app.vaultType = vaultType;
        app.title = title;
        app.displayTitle = displayTitle;
        app.metadataURI = metadataURI;
        app.features = features;
        app.phase = ApplicationPhase.InitialVoting;
        app.phaseDeadline = block.timestamp + INITIAL_VOTING_PERIOD;
        app.applicationFee = msg.value;
        app.createdAt = block.timestamp;
        app.cumulativeYayRequired = 0;

        // Create initial voting round
        app.rounds.push(VoteRound({
            roundIndex: 0,
            yayDeposits: 0,
            nayDeposits: 0,
            startTime: block.timestamp,
            endTime: block.timestamp + INITIAL_VOTING_PERIOD,
            challenger: address(0),
            challengeDeposit: 0,
            resolved: false,
            yayWon: false
        }));

        // Store message if provided
        if (bytes(message).length > 0) {
            governanceMessages[totalMessages] = GovernanceMessage({
                sender: applicant,
                packedData: _packMessageData(uint32(block.timestamp), 0, MessageActionType.Application),
                message: message
            });

            emit MessagePosted(
                totalMessages,
                vaultAddress,
                applicant,
                MessageActionType.Application,
                0
            );

            totalMessages++;
        }

        // Refund excess
        if (msg.value > applicationFee) {
            uint256 refundAmount = msg.value - applicationFee;
            /// @dev Use .call{value:}() instead of .transfer() to support contract applicants.
            /// .transfer() only forwards 2300 gas which fails for contracts (e.g., multi-sigs).
            (bool success, ) = payable(applicant).call{value: refundAmount}("");
            require(success, "Refund transfer failed");
        }

        emit ApplicationSubmitted(
            vaultAddress,
            applicant,
            vaultType,
            msg.value,
            app.phaseDeadline
        );
    }

    // ============ Voting Functions ============

    /**
     * @notice Deposit EXEC tokens to vote on application
     * @param vaultAddress Vault being voted on
     * @param approve true = yay, false = nay
     * @param amount Amount of EXEC to deposit (must be >= MIN_DEPOSIT)
     * @param message Optional message (empty string for no message)
     */
    function voteWithDeposit(
        address vaultAddress,
        bool approve,
        uint256 amount,
        string calldata message
    ) external nonReentrant {
        VaultApplication storage app = applications[vaultAddress];
        require(app.applicant != address(0), "Application not found");
        require(
            app.phase == ApplicationPhase.InitialVoting ||
            app.phase == ApplicationPhase.ChallengeVoting,
            "Not in voting phase"
        );
        require(block.timestamp <= app.phaseDeadline, "Voting period ended");
        require(amount >= MIN_DEPOSIT, "Below minimum deposit");

        uint256 currentRound = app.rounds.length - 1;
        VoteDeposit storage existingDeposit = deposits[vaultAddress][msg.sender][currentRound];

        // If voter already has a deposit in this round, they can only add to same side
        if (existingDeposit.amount > 0) {
            require(
                existingDeposit.supportsApproval == approve,
                "Cannot vote for opposite side"
            );

            // Transfer additional EXEC
            require(
                IERC20(execToken).transferFrom(msg.sender, address(this), amount),
                "Transfer failed"
            );

            existingDeposit.amount += amount;

            // Update round totals
            if (approve) {
                app.rounds[currentRound].yayDeposits += amount;
            } else {
                app.rounds[currentRound].nayDeposits += amount;
            }

            emit VoteDepositAdded(
                vaultAddress,
                currentRound,
                msg.sender,
                amount,
                existingDeposit.amount
            );
        } else {
            // New deposit for this voter in this round
            require(
                IERC20(execToken).transferFrom(msg.sender, address(this), amount),
                "Transfer failed"
            );

            deposits[vaultAddress][msg.sender][currentRound] = VoteDeposit({
                amount: amount,
                supportsApproval: approve,
                withdrawn: false
            });

            // Update round totals
            if (approve) {
                app.rounds[currentRound].yayDeposits += amount;
            } else {
                app.rounds[currentRound].nayDeposits += amount;
            }

            emit VoteDeposited(vaultAddress, currentRound, msg.sender, approve, amount);
        }

        // Store message if provided (only on new deposits or additions)
        if (bytes(message).length > 0) {
            governanceMessages[totalMessages] = GovernanceMessage({
                sender: msg.sender,
                packedData: _packMessageData(uint32(block.timestamp), uint32(currentRound), MessageActionType.Vote),
                message: message
            });

            emit MessagePosted(
                totalMessages,
                vaultAddress,
                msg.sender,
                MessageActionType.Vote,
                currentRound
            );

            totalMessages++;
        }
    }

    // ============ Round Finalization ============

    /**
     * @notice Finalize a completed voting round
     * @param vaultAddress Vault to finalize
     */
    function finalizeRound(address vaultAddress) external nonReentrant {
        VaultApplication storage app = applications[vaultAddress];
        require(app.applicant != address(0), "Application not found");
        require(
            app.phase == ApplicationPhase.InitialVoting ||
            app.phase == ApplicationPhase.ChallengeVoting,
            "Not in voting phase"
        );
        require(block.timestamp > app.phaseDeadline, "Voting period not ended");

        uint256 currentRound = app.rounds.length - 1;
        VoteRound storage round = app.rounds[currentRound];
        require(!round.resolved, "Round already finalized");

        uint256 totalVotes = round.yayDeposits + round.nayDeposits;
        require(totalVotes >= MIN_QUORUM, "Quorum not met");

        bool yayWon = round.yayDeposits > round.nayDeposits;
        round.resolved = true;
        round.yayWon = yayWon;

        emit RoundFinalized(vaultAddress, currentRound, yayWon, round.yayDeposits, round.nayDeposits);

        if (yayWon) {
            // Yay won - add to cumulative requirement and enter challenge window
            app.cumulativeYayRequired += round.yayDeposits;
            app.phase = ApplicationPhase.ChallengeWindow;
            app.phaseDeadline = block.timestamp + CHALLENGE_WINDOW;
        } else {
            // Nay won - application rejected
            app.phase = ApplicationPhase.Rejected;
            app.phaseDeadline = 0;

            emit ApplicationRejected(
                vaultAddress,
                currentRound,
                "Majority voted against approval"
            );
        }
    }

    // ============ Challenge System ============

    /**
     * @notice Initiate a challenge against an approved vote
     * @param vaultAddress Vault to challenge
     * @param challengeDeposit EXEC tokens to deposit (must be >= cumulativeYayRequired)
     * @param message Optional message explaining the challenge (empty string for no message)
     */
    function initiateChallenge(
        address vaultAddress,
        uint256 challengeDeposit,
        string calldata message
    ) external nonReentrant {
        VaultApplication storage app = applications[vaultAddress];
        require(app.applicant != address(0), "Application not found");
        require(
            app.phase == ApplicationPhase.ChallengeWindow ||
            app.phase == ApplicationPhase.LameDuck,
            "Not in challenge period"
        );
        require(block.timestamp <= app.phaseDeadline, "Challenge period ended");
        require(
            challengeDeposit >= app.cumulativeYayRequired,
            "Insufficient challenge deposit"
        );

        // Transfer challenge deposit
        require(
            IERC20(execToken).transferFrom(msg.sender, address(this), challengeDeposit),
            "Transfer failed"
        );

        // Create new challenge round
        uint256 newRoundIndex = app.rounds.length;
        app.rounds.push(VoteRound({
            roundIndex: newRoundIndex,
            yayDeposits: 0,
            nayDeposits: 0,
            startTime: block.timestamp,
            endTime: block.timestamp + CHALLENGE_VOTING_PERIOD,
            challenger: msg.sender,
            challengeDeposit: challengeDeposit,
            resolved: false,
            yayWon: false
        }));

        // Challenger's deposit is stored separately so they can withdraw it
        deposits[vaultAddress][msg.sender][newRoundIndex] = VoteDeposit({
            amount: challengeDeposit,
            supportsApproval: false, // Challenger is betting on nay
            withdrawn: false
        });

        // Update application phase
        app.phase = ApplicationPhase.ChallengeVoting;
        app.phaseDeadline = block.timestamp + CHALLENGE_VOTING_PERIOD;

        // Store message if provided
        if (bytes(message).length > 0) {
            governanceMessages[totalMessages] = GovernanceMessage({
                sender: msg.sender,
                packedData: _packMessageData(uint32(block.timestamp), uint32(newRoundIndex), MessageActionType.Challenge),
                message: message
            });

            emit MessagePosted(
                totalMessages,
                vaultAddress,
                msg.sender,
                MessageActionType.Challenge,
                newRoundIndex
            );

            totalMessages++;
        }

        emit ChallengeInitiated(
            vaultAddress,
            newRoundIndex,
            msg.sender,
            challengeDeposit,
            app.cumulativeYayRequired,
            app.phaseDeadline
        );
    }

    // ============ Registration ============

    /**
     * @notice Complete lame duck period and register vault (permissionless)
     * @param vaultAddress Vault to register
     */
    function registerVault(address vaultAddress) external nonReentrant {
        VaultApplication storage app = applications[vaultAddress];
        require(app.applicant != address(0), "Application not found");
        require(app.phase == ApplicationPhase.LameDuck, "Not in lame duck period");
        require(block.timestamp > app.phaseDeadline, "Lame duck period not ended");

        // Mark as approved
        app.phase = ApplicationPhase.Approved;
        app.phaseDeadline = 0;

        // Register in MasterRegistry
        IMasterRegistry(masterRegistry).registerApprovedVault(
            app.vaultAddress,
            app.vaultType,
            app.title,
            app.displayTitle,
            app.metadataURI,
            app.features,
            app.applicant  // Pass original applicant as creator
        );

        emit ApplicationRegistered(vaultAddress, msg.sender);
    }

    /**
     * @notice Move from challenge window to lame duck if no challenges
     * @param vaultAddress Vault to transition
     */
    function enterLameDuck(address vaultAddress) external nonReentrant {
        VaultApplication storage app = applications[vaultAddress];
        require(app.applicant != address(0), "Application not found");
        require(app.phase == ApplicationPhase.ChallengeWindow, "Not in challenge window");
        require(block.timestamp > app.phaseDeadline, "Challenge window not ended");

        app.phase = ApplicationPhase.LameDuck;
        app.phaseDeadline = block.timestamp + LAME_DUCK_PERIOD;

        emit ApplicationApproved(vaultAddress, app.rounds.length, app.phaseDeadline);
    }

    // ============ Withdrawal ============

    /**
     * @notice Withdraw all deposited EXEC tokens after application is resolved
     * @param vaultAddress Vault to withdraw from
     */
    function withdrawDeposits(address vaultAddress) external nonReentrant {
        VaultApplication storage app = applications[vaultAddress];
        require(app.applicant != address(0), "Application not found");
        require(
            app.phase == ApplicationPhase.Approved ||
            app.phase == ApplicationPhase.Rejected,
            "Application not resolved"
        );

        uint256 totalWithdrawal = 0;

        // Iterate through all rounds and collect deposits
        for (uint256 i = 0; i < app.rounds.length; i++) {
            VoteDeposit storage deposit = deposits[vaultAddress][msg.sender][i];

            if (deposit.amount > 0 && !deposit.withdrawn) {
                totalWithdrawal += deposit.amount;
                deposit.withdrawn = true;
            }
        }

        require(totalWithdrawal > 0, "No deposits to withdraw");

        // Transfer all EXEC back to voter
        require(
            IERC20(execToken).transfer(msg.sender, totalWithdrawal),
            "Transfer failed"
        );

        emit DepositWithdrawn(vaultAddress, msg.sender, totalWithdrawal);
    }

    // ============ View Functions ============

    function getApplication(address vaultAddress)
        external
        view
        returns (
            address applicant,
            string memory vaultType,
            string memory title,
            ApplicationPhase phase,
            uint256 phaseDeadline,
            uint256 cumulativeYayRequired,
            uint256 roundCount
        )
    {
        VaultApplication storage app = applications[vaultAddress];
        return (
            app.applicant,
            app.vaultType,
            app.title,
            app.phase,
            app.phaseDeadline,
            app.cumulativeYayRequired,
            app.rounds.length
        );
    }

    function getRound(address vaultAddress, uint256 roundIndex)
        external
        view
        returns (VoteRound memory)
    {
        return applications[vaultAddress].rounds[roundIndex];
    }

    function getVoterDeposit(
        address vaultAddress,
        address voter,
        uint256 roundIndex
    ) external view returns (VoteDeposit memory) {
        return deposits[vaultAddress][voter][roundIndex];
    }

    function getCurrentRound(address vaultAddress) external view returns (uint256) {
        VaultApplication storage app = applications[vaultAddress];
        require(app.rounds.length > 0, "No rounds");
        return app.rounds.length - 1;
    }

    /**
     * @notice Get a governance message by ID
     * @param messageId Message ID
     */
    function getMessage(uint256 messageId) external view returns (
        address sender,
        uint32 timestamp,
        uint32 roundIndex,
        MessageActionType actionType,
        string memory message
    ) {
        require(messageId < totalMessages, "Message does not exist");
        GovernanceMessage memory govMsg = governanceMessages[messageId];
        (timestamp, roundIndex, actionType) = _unpackMessageData(govMsg.packedData);
        return (govMsg.sender, timestamp, roundIndex, actionType, govMsg.message);
    }

    /**
     * @notice Get range of governance messages
     * @param start Start index (inclusive)
     * @param end End index (exclusive)
     */
    function getMessagesRange(uint256 start, uint256 end) external view returns (
        address[] memory senders,
        uint32[] memory timestamps,
        uint32[] memory roundIndices,
        MessageActionType[] memory actionTypes,
        string[] memory messages
    ) {
        require(end > start, "Invalid range");
        require(end <= totalMessages, "End out of bounds");

        uint256 size = end - start;
        senders = new address[](size);
        timestamps = new uint32[](size);
        roundIndices = new uint32[](size);
        actionTypes = new MessageActionType[](size);
        messages = new string[](size);

        for (uint256 i = 0; i < size; i++) {
            GovernanceMessage memory govMsg = governanceMessages[start + i];
            senders[i] = govMsg.sender;
            (timestamps[i], roundIndices[i], actionTypes[i]) = _unpackMessageData(govMsg.packedData);
            messages[i] = govMsg.message;
        }
    }

    // ============ Admin Functions ============

    function setExecToken(address newToken) external onlyOwner {
        require(newToken != address(0), "Invalid token");
        execToken = newToken;
        emit ExecutTokenSet(newToken);
    }

    function setMasterRegistry(address newRegistry) external onlyOwner {
        require(newRegistry != address(0), "Invalid registry");
        masterRegistry = newRegistry;
        emit MasterRegistrySet(newRegistry);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // ============ Internal Helper Functions ============

    /**
     * @notice Pack message data into uint128
     * @param timestamp Block timestamp (32 bits)
     * @param roundIndex Round index (32 bits)
     * @param actionType Message action type (8 bits)
     */
    function _packMessageData(
        uint32 timestamp,
        uint32 roundIndex,
        MessageActionType actionType
    ) internal pure returns (uint128) {
        return uint128(timestamp) | (uint128(roundIndex) << 32) | (uint128(uint8(actionType)) << 64);
    }

    /**
     * @notice Unpack message data from uint128
     * @param packedData Packed data
     * @return timestamp Block timestamp
     * @return roundIndex Round index
     * @return actionType Message action type
     */
    function _unpackMessageData(uint128 packedData) internal pure returns (
        uint32 timestamp,
        uint32 roundIndex,
        MessageActionType actionType
    ) {
        timestamp = uint32(packedData);
        roundIndex = uint32(packedData >> 32);
        actionType = MessageActionType(uint8(packedData >> 64));
    }
}

// ============ Interfaces ============

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IMasterRegistry {
    function registerApprovedVault(
        address vaultAddress,
        string memory vaultType,
        string memory title,
        string memory displayTitle,
        string memory metadataURI,
        bytes32[] memory features,
        address creator
    ) external;
}
