// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {GrandCentral} from "../../src/dao/GrandCentral.sol";
import {IGrandCentral} from "../../src/dao/interfaces/IGrandCentral.sol";
import {MockSafe} from "../mocks/MockSafe.sol";

contract GrandCentralVotingTest is Test {
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


    function _createAndPassProposal(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas
    ) internal returns (uint32 id) {
        vm.prank(founder);
        id = uint32(dao.submitProposal(targets, values, calldatas, 0, "test"));

        vm.prank(founder);
        dao.submitVote(id, true);

        vm.warp(block.timestamp + VOTING_PERIOD + GRACE_PERIOD + 1);
    }

    // ========== Process Tests ==========


    function test_SubmitProposal_NonMemberNotSponsored() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _buildSendETHProposal(alice, 1 ether);

        vm.prank(alice);
        uint256 id = dao.submitProposal(t, v, c, 0, "Send 1 ETH to alice");

        assertEq(id, 1);
        assertEq(uint8(dao.state(uint32(id))), uint8(IGrandCentral.ProposalState.Submitted));
    }


    function test_SponsorProposal() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _buildSendETHProposal(alice, 1 ether);

        vm.prank(alice);
        uint256 id = dao.submitProposal(t, v, c, 0, "test");

        vm.prank(founder);
        dao.sponsorProposal(uint32(id));

        assertEq(uint8(dao.state(uint32(id))), uint8(IGrandCentral.ProposalState.Voting));
    }

    // ========== Voting Tests ==========


    function test_SubmitVote_YesVote() public {
        uint256 id;
        { (address[] memory t, uint256[] memory v, bytes[] memory c) = _buildSendETHProposal(alice, 1 ether);
        vm.prank(founder);
        id = dao.submitProposal(t, v, c, 0, "test"); }

        vm.expectEmit(true, true, true, true);
        emit IGrandCentral.VoteCast(founder, INITIAL_SHARES, id, true);

        vm.prank(founder);
        dao.submitVote(uint32(id), true);
    }


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


    function test_StateTransitions_VotingToGraceToReady() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _buildSendETHProposal(alice, 1 ether);

        vm.prank(founder);
        uint256 id = dao.submitProposal(t, v, c, 0, "test");

        vm.prank(founder);
        dao.submitVote(uint32(id), true);

        assertEq(uint8(dao.state(uint32(id))), uint8(IGrandCentral.ProposalState.Voting));
        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        assertEq(uint8(dao.state(uint32(id))), uint8(IGrandCentral.ProposalState.Grace));
        vm.warp(block.timestamp + GRACE_PERIOD + 1);
        assertEq(uint8(dao.state(uint32(id))), uint8(IGrandCentral.ProposalState.Ready));
    }


    function test_Defeated_WhenNoVotesWin() public {
        { address[] memory to = new address[](1);
        to[0] = alice;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100;
        vm.prank(address(dao));
        dao.mintShares(to, amounts); }

        (address[] memory t, uint256[] memory v, bytes[] memory c) = _buildSendETHProposal(bob, 1 ether);

        vm.prank(founder);
        uint256 id = dao.submitProposal(t, v, c, 0, "test");

        vm.prank(founder);
        dao.submitVote(uint32(id), false);

        vm.prank(alice);
        dao.submitVote(uint32(id), true);

        vm.warp(block.timestamp + VOTING_PERIOD + GRACE_PERIOD + 2);
        assertEq(uint8(dao.state(uint32(id))), uint8(IGrandCentral.ProposalState.Defeated));
    }

    // ========== Helper: full proposal lifecycle to Ready ==========


    function test_ProcessProposal_ExecutesETHSendViaSafe() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _buildSendETHProposal(alice, 1 ether);
        uint32 id = _createAndPassProposal(t, v, c);

        _process(id, t, v, c);

        assertEq(alice.balance, 1 ether);
        assertEq(uint8(dao.state(id)), uint8(IGrandCentral.ProposalState.Processed));
        // Verify it went through safe
        assertEq(mockSafe.executionCount(), 1);
    }


    function test_ProcessProposal_ExecutesDAOSelfCall() public {
        bytes memory mintCall;
        { address[] memory to = new address[](1);
        to[0] = alice;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 50;
        mintCall = abi.encodeCall(dao.mintShares, (to, amounts)); }

        (address[] memory t, uint256[] memory v, bytes[] memory c) = _buildDAOCallProposal(mintCall);
        uint32 id = _createAndPassProposal(t, v, c);

        _process(id, t, v, c);

        assertEq(dao.shares(alice), 50);
        assertEq(uint8(dao.state(id)), uint8(IGrandCentral.ProposalState.Processed));
    }


    function test_ProcessProposal_RevertIfNotReady() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _buildSendETHProposal(alice, 1 ether);

        vm.prank(founder);
        uint256 id = dao.submitProposal(t, v, c, 0, "test");

        vm.expectRevert("!ready");
        _process(uint32(id), t, v, c);
    }


    function test_ProcessProposal_RevertIfWrongCalldata() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _buildSendETHProposal(alice, 1 ether);
        uint32 id = _createAndPassProposal(t, v, c);

        v[0] = 5 ether;
        vm.expectRevert("incorrect calldata");
        _process(id, t, v, c);
    }

    // ========== Cancel Tests ==========


    function test_CancelProposal() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _buildSendETHProposal(alice, 1 ether);

        vm.prank(founder);
        uint256 id = dao.submitProposal(t, v, c, 0, "test");

        vm.prank(founder);
        dao.cancelProposal(uint32(id));

        assertEq(uint8(dao.state(uint32(id))), uint8(IGrandCentral.ProposalState.Cancelled));
    }


    function test_CancelProposal_RevertIfNotVoting() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _buildSendETHProposal(alice, 1 ether);

        vm.prank(founder);
        uint256 id = dao.submitProposal(t, v, c, 0, "test");

        vm.prank(founder);
        dao.submitVote(uint32(id), true);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        vm.prank(founder);
        vm.expectRevert("!voting");
        dao.cancelProposal(uint32(id));
    }

    // ========== Ragequit Pool Tests ==========


    function test_FundRagequitPool() public {
        vm.prank(address(dao));
        dao.fundRagequitPool(20 ether);

        assertEq(dao.ragequitPool(), 20 ether);
        assertEq(dao.generalFunds(), 80 ether);
    }


    function test_FundRagequitPool_RevertIfInsufficientFunds() public {
        // Safe only has 100 ether
        vm.prank(address(dao));
        vm.expectRevert("insufficient general funds");
        dao.fundRagequitPool(200 ether);
    }


    function test_Ragequit_SharesOnly() public {
        vm.prank(address(dao));
        dao.fundRagequitPool(20 ether);

        // Mint shares to alice
        address[] memory to = new address[](1);
        to[0] = alice;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100;
        vm.prank(address(dao));
        dao.mintShares(to, amounts);

        // Alice ragequits 100 shares -> 100/1100 * 20 ETH
        uint256 expectedPayout = (uint256(100) * 20 ether) / 1100;

        vm.prank(alice);
        dao.ragequit(100, 0);

        assertEq(alice.balance, expectedPayout);
        assertEq(dao.shares(alice), 0);
        assertEq(dao.totalShares(), 1000);
        assertEq(dao.ragequitPool(), 20 ether - expectedPayout);
    }


    function test_Ragequit_LootOnly() public {
        vm.prank(address(dao));
        dao.fundRagequitPool(20 ether);

        // Mint loot to alice
        address[] memory to = new address[](1);
        to[0] = alice;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100;
        vm.prank(address(dao));
        dao.mintLoot(to, amounts);

        // Total weight: 1000 shares + 100 loot = 1100
        uint256 expectedPayout = (uint256(100) * 20 ether) / 1100;

        vm.prank(alice);
        dao.ragequit(0, 100);

        assertEq(alice.balance, expectedPayout);
        assertEq(dao.loot(alice), 0);
        assertEq(dao.totalLoot(), 0);
    }


    function test_Ragequit_SharesAndLoot() public {
        vm.prank(address(dao));
        dao.fundRagequitPool(20 ether);

        // Mint shares + loot to alice
        address[] memory to = new address[](1);
        to[0] = alice;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100;
        vm.prank(address(dao));
        dao.mintShares(to, amounts);
        amounts[0] = 50;
        vm.prank(address(dao));
        dao.mintLoot(to, amounts);

        // Total weight: 1100 shares + 50 loot = 1150
        // Burn 100 shares + 50 loot = 150 weight
        uint256 expectedPayout = (uint256(150) * 20 ether) / 1150;

        vm.prank(alice);
        dao.ragequit(100, 50);

        assertEq(alice.balance, expectedPayout);
        assertEq(dao.shares(alice), 0);
        assertEq(dao.loot(alice), 0);
    }


    function test_Ragequit_EmptyPoolReturnsNothing() public {
        assertEq(dao.ragequitPool(), 0);

        vm.prank(founder);
        dao.ragequit(100, 0);

        assertEq(founder.balance, 0);
        assertEq(dao.shares(founder), INITIAL_SHARES - 100);
    }


    function test_Ragequit_RevertIfZeroBurn() public {
        vm.prank(alice);
        vm.expectRevert("zero burn");
        dao.ragequit(0, 0);
    }


}
