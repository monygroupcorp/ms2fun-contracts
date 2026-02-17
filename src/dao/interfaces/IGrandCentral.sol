// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IGrandCentral {
    // ============ Enums ============

    enum ProposalState {
        Unborn,     // 0 - does not exist
        Submitted,  // 1 - awaiting sponsor
        Voting,     // 2 - active voting
        Cancelled,  // 3 - terminal
        Grace,      // 4 - grace period (ragequit window)
        Ready,      // 5 - can be processed
        Processed,  // 6 - terminal (executed)
        Defeated    // 7 - terminal (failed vote)
    }

    // ============ Structs ============

    struct Proposal {
        uint32 id;
        uint32 prevProposalId;
        uint32 votingStarts;
        uint32 votingEnds;
        uint32 graceEnds;
        uint32 expiration;
        uint256 yesVotes;
        uint256 noVotes;
        uint256 maxTotalSharesAtYesVote;
        bool[4] status; // [cancelled, processed, passed, actionFailed]
        address sponsor;
        bytes32 proposalDataHash;
        string details;
    }

    // ============ Events ============

    // Governance
    event ProposalSubmitted(
        uint256 indexed proposalId,
        bytes32 indexed proposalDataHash,
        address[] targets,
        uint256[] values,
        bytes[] calldatas,
        uint32 expiration,
        bool selfSponsor,
        string details
    );
    event ProposalSponsored(address indexed sponsor, uint256 indexed proposalId, uint256 votingStarts);
    event VoteCast(address indexed voter, uint256 balance, uint256 indexed proposalId, bool indexed approved);
    event ProposalProcessed(uint256 indexed proposalId, bool passed, bool actionFailed);
    event ProposalCancelled(uint256 indexed proposalId);

    // Shares
    event SharesMinted(address indexed to, uint256 amount);
    event SharesBurned(address indexed from, uint256 amount);

    // Loot
    event LootMinted(address indexed to, uint256 amount);
    event LootBurned(address indexed from, uint256 amount);

    // Treasury pools
    event RagequitPoolFunded(uint256 amount, uint256 newTotal);
    event Ragequit(address indexed member, uint256 sharesBurned, uint256 lootBurned, uint256 ethReceived);
    event ClaimsPoolFunded(uint256 amount, uint256 newRewardPerShare);
    event ClaimWithdrawn(address indexed member, uint256 amount);

    // Conductors
    event ConductorSet(address indexed conductor, uint256 permission);
    event GovernanceConfigSet(
        uint32 voting, uint32 grace, uint256 quorum,
        uint256 sponsor, uint256 minRetention
    );

    // Lock events (audit fix: irreversible state changes need events)
    event AdminLocked();
    event ManagerLocked();
    event GovernorLocked();

    // Stipend event (audit fix: fund disbursement needs audit trail)
    event StipendExecuted(address indexed beneficiary, uint256 amount, address indexed executor);

    // ============ Functions ============

    // Safe
    function safe() external view returns (address);

    // Shares
    function shares(address member) external view returns (uint256);
    function totalShares() external view returns (uint256);
    function getSharesAt(address member, uint256 timestamp) external view returns (uint256);
    function getTotalSharesAt(uint256 timestamp) external view returns (uint256);

    // Loot
    function loot(address member) external view returns (uint256);
    function totalLoot() external view returns (uint256);
    function getLootAt(address member, uint256 timestamp) external view returns (uint256);
    function getTotalLootAt(uint256 timestamp) external view returns (uint256);
    function mintLoot(address[] calldata to, uint256[] calldata amount) external;
    function burnLoot(address[] calldata from, uint256[] calldata amount) external;

    // Proposals
    function submitProposal(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        uint32 expiration,
        string calldata details
    ) external returns (uint256);
    function sponsorProposal(uint32 id) external;
    function submitVote(uint32 id, bool approved) external;
    function processProposal(
        uint32 id,
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas
    ) external;
    function cancelProposal(uint32 id) external;
    function state(uint32 id) external view returns (ProposalState);
    function getProposalStatus(uint32 id) external view returns (bool[4] memory);

    // Treasury pools
    function ragequitPool() external view returns (uint256);
    function claimsPoolBalance() external view returns (uint256);
    function generalFunds() external view returns (uint256);
    function fundRagequitPool(uint256 amount) external;
    function fundClaimsPool(uint256 amount) external;
    function ragequit(uint256 sharesToBurn, uint256 lootToBurn) external;
    function claim() external;
    function pendingClaim(address member) external view returns (uint256);

    // Conductors
    function conductors(address conductor) external view returns (uint256);
    function isAdmin(address conductor) external view returns (bool);
    function isManager(address conductor) external view returns (bool);
    function isGovernor(address conductor) external view returns (bool);
    function setConductors(address[] calldata _conductors, uint256[] calldata _permissions) external;
    function mintShares(address[] calldata to, uint256[] calldata amount) external;
    function burnShares(address[] calldata from, uint256[] calldata amount) external;
    function setGovernanceConfig(
        uint32 voting, uint32 grace, uint256 quorum,
        uint256 sponsor, uint256 minRetention
    ) external;

    // Stipend
    function executeStipend(address beneficiary, uint256 amount) external;

    // Lock functions
    function lockAdmin() external;
    function lockManager() external;
    function lockGovernor() external;

    // Governance params
    function votingPeriod() external view returns (uint32);
    function gracePeriod() external view returns (uint32);
    function quorumPercent() external view returns (uint256);
    function sponsorThreshold() external view returns (uint256);
    function minRetentionPercent() external view returns (uint256);
    function proposalCount() external view returns (uint32);
}
