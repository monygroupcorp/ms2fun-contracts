// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {GrandCentral} from "../../src/dao/GrandCentral.sol";
import {IGrandCentral} from "../../src/dao/interfaces/IGrandCentral.sol";
import {MockSafe} from "../mocks/MockSafe.sol";

contract GrandCentralTest is Test {
    GrandCentral public dao;
    MockSafe public mockSafe;

    address public founder = makeAddr("founder");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint256 constant INITIAL_SHARES = 1000;
    uint32 constant VOTING_PERIOD = 5 days;
    uint32 constant GRACE_PERIOD = 2 days;
    uint256 constant QUORUM_PERCENT = 0;
    uint256 constant SPONSOR_THRESHOLD = 1;
    uint256 constant MIN_RETENTION = 66;

    function setUp() public {
        mockSafe = new MockSafe();
        dao = new GrandCentral(
            address(mockSafe),
            founder,
            INITIAL_SHARES,
            VOTING_PERIOD,
            GRACE_PERIOD,
            QUORUM_PERCENT,
            SPONSOR_THRESHOLD,
            MIN_RETENTION
        );
        vm.deal(address(mockSafe), 100 ether);
    }

    // ========== Initialization Tests ==========

    function _buildSendETHProposal(address to, uint256 amount)
        internal pure returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        targets = new address[](1);
        targets[0] = to;
        values = new uint256[](1);
        values[0] = amount;
        calldatas = new bytes[](1);
        calldatas[0] = "";
    }

    function _getVotes(uint32 id) internal view returns (uint256 yesVotes, uint256 noVotes) {
        (,,,,,, yesVotes, noVotes,,,,) = dao.proposals(id);
    }

    function _process(uint32 id, address[] memory t, uint256[] memory v, bytes[] memory c) internal {
        dao.processProposal(id, t, v, c);
    }

    // ========== Helper: build a DAO self-call proposal ==========

    function _buildDAOCallProposal(bytes memory data)
        internal view returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        targets = new address[](1);
        targets[0] = address(dao);
        values = new uint256[](1);
        values[0] = 0;
        calldatas = new bytes[](1);
        calldatas[0] = data;
    }

    // ========== Proposal Submission Tests ==========

    function test_SubmitVote_CannotVoteTwice() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _buildSendETHProposal(alice, 1 ether);

        vm.prank(founder);
        uint256 id = dao.submitProposal(t, v, c, 0, "test");

        vm.prank(founder);
        dao.submitVote(uint32(id), true);

        vm.prank(founder);
        vm.expectRevert("voted");
        dao.submitVote(uint32(id), true);
    }

}
