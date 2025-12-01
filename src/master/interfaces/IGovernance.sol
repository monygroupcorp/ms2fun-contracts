// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IGovernance
 * @notice Interface for EXEC token holder governance
 */
interface IGovernance {
    struct Proposal {
        uint256 proposalId;
        address proposer;
        string description;
        bytes callData;
        address target;
        uint256 startTime;
        uint256 endTime;
        uint256 forVotes;
        uint256 againstVotes;
        bool executed;
        bool canceled;
    }

    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        string description
    );

    event VoteCast(
        uint256 indexed proposalId,
        address indexed voter,
        bool support,
        uint256 votes
    );

    event ProposalExecuted(uint256 indexed proposalId);

    function createProposal(
        string memory description,
        address target,
        bytes memory callData
    ) external returns (uint256);

    function castVote(
        uint256 proposalId,
        bool support
    ) external;

    function executeProposal(uint256 proposalId) external;

    function getProposal(
        uint256 proposalId
    ) external view returns (Proposal memory);

    function getVotingPower(address account) external view returns (uint256);
}

