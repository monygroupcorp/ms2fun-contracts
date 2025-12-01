// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "solady/auth/Ownable.sol";
import {IGovernance} from "../master/interfaces/IGovernance.sol";

/**
 * @title EXECGovernance
 * @notice EXEC token holder voting system
 */
contract EXECGovernance is IGovernance, Ownable {
    address public execToken;
    uint256 public proposalCount;
    uint256 public votingPeriod = 3 days;
    uint256 public quorumThreshold = 1000e18; // Minimum EXEC tokens for quorum

    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    mapping(uint256 => mapping(address => uint256)) public votes;

    constructor(address _execToken) {
        _initializeOwner(msg.sender);
        execToken = _execToken;
    }

    /**
     * @notice Create a new proposal
     */
    function createProposal(
        string memory description,
        address target,
        bytes memory callData
    ) external returns (uint256) {
        uint256 votingPower = IERC20(execToken).balanceOf(msg.sender);
        require(votingPower >= quorumThreshold / 10, "Insufficient voting power to propose");

        uint256 proposalId = proposalCount++;
        
        proposals[proposalId] = Proposal({
            proposalId: proposalId,
            proposer: msg.sender,
            description: description,
            callData: callData,
            target: target,
            startTime: block.timestamp,
            endTime: block.timestamp + votingPeriod,
            forVotes: 0,
            againstVotes: 0,
            executed: false,
            canceled: false
        });

        emit ProposalCreated(proposalId, msg.sender, description);
        return proposalId;
    }

    /**
     * @notice Cast a vote on a proposal
     */
    function castVote(
        uint256 proposalId,
        bool support
    ) external {
        Proposal storage proposal = proposals[proposalId];
        require(proposal.proposalId != 0, "Proposal not found");
        require(block.timestamp >= proposal.startTime, "Voting not started");
        require(block.timestamp <= proposal.endTime, "Voting ended");
        require(!proposal.executed && !proposal.canceled, "Proposal not active");
        require(!hasVoted[proposalId][msg.sender], "Already voted");

        uint256 votingPower = IERC20(execToken).balanceOf(msg.sender);
        require(votingPower > 0, "No voting power");

        hasVoted[proposalId][msg.sender] = true;
        votes[proposalId][msg.sender] = votingPower;

        if (support) {
            proposal.forVotes += votingPower;
        } else {
            proposal.againstVotes += votingPower;
        }

        emit VoteCast(proposalId, msg.sender, support, votingPower);
    }

    /**
     * @notice Execute a proposal
     */
    function executeProposal(uint256 proposalId) external {
        Proposal storage proposal = proposals[proposalId];
        require(proposal.proposalId != 0, "Proposal not found");
        require(block.timestamp > proposal.endTime, "Voting not ended");
        require(!proposal.executed, "Already executed");
        require(!proposal.canceled, "Proposal canceled");
        require(
            proposal.forVotes >= quorumThreshold &&
            proposal.forVotes > proposal.againstVotes,
            "Proposal not passed"
        );

        proposal.executed = true;

        (bool success, ) = proposal.target.call(proposal.callData);
        require(success, "Proposal execution failed");

        emit ProposalExecuted(proposalId);
    }

    /**
     * @notice Get proposal details
     */
    function getProposal(
        uint256 proposalId
    ) external view returns (Proposal memory) {
        return proposals[proposalId];
    }

    /**
     * @notice Get voting power for an account
     */
    function getVotingPower(address account) external view returns (uint256) {
        return IERC20(execToken).balanceOf(account);
    }

    /**
     * @notice Set quorum threshold (owner only)
     */
    function setQuorumThreshold(uint256 _threshold) external onlyOwner {
        quorumThreshold = _threshold;
    }

    /**
     * @notice Set voting period (owner only)
     */
    function setVotingPeriod(uint256 _period) external onlyOwner {
        votingPeriod = _period;
    }
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
}

