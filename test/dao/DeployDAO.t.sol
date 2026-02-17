// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {GrandCentral} from "../../src/dao/GrandCentral.sol";
import {IGrandCentral} from "../../src/dao/interfaces/IGrandCentral.sol";
import {ShareOffering} from "../../src/dao/conductors/ShareOffering.sol";
import {StipendConductor} from "../../src/dao/conductors/StipendConductor.sol";
import {MockSafe} from "../mocks/MockSafe.sol";

contract DeployDAOTest is Test {
    GrandCentral public dao;
    MockSafe public safe;
    ShareOffering public shareOffering;
    StipendConductor public stipendConductor;

    address public founder = makeAddr("founder");

    uint256 constant INITIAL_SHARES = 1000;
    uint32 constant VOTING_PERIOD = 1 days;
    uint32 constant GRACE_PERIOD = 1 days;
    uint256 constant STIPEND_AMOUNT = 3.15 ether;
    uint256 constant STIPEND_INTERVAL = 30 days;

    // Proposal calldata arrays (reused across tests)
    address[] targets;
    uint256[] values;
    bytes[] calldatas;

    function setUp() public {
        // 1. Deploy Safe
        safe = new MockSafe();
        vm.deal(address(safe), 100 ether);

        // 2. Deploy GrandCentral
        dao = new GrandCentral(
            address(safe),
            founder,
            INITIAL_SHARES,
            VOTING_PERIOD,
            GRACE_PERIOD,
            0,   // quorum
            1,   // sponsor threshold
            66   // min retention
        );

        // 3. Deploy conductors
        shareOffering = new ShareOffering(address(dao));
        stipendConductor = new StipendConductor(
            address(dao), founder, STIPEND_AMOUNT, STIPEND_INTERVAL
        );

        // 4. Enable module (mock)
        safe.enableModule(address(dao));

        // 5. Build proposal calldata for conductor registration
        _buildConductorProposal();
    }

    function _buildConductorProposal() internal {
        address[] memory conductors = new address[](2);
        conductors[0] = address(shareOffering);
        conductors[1] = address(stipendConductor);

        uint256[] memory permissions = new uint256[](2);
        permissions[0] = 2; // manager
        permissions[1] = 2; // manager

        targets.push(address(dao));
        values.push(0);
        calldatas.push(
            abi.encodeWithSelector(
                GrandCentral.setConductors.selector,
                conductors,
                permissions
            )
        );
    }

    function _submitAndVoteProposal() internal returns (uint256) {
        vm.startPrank(founder);
        uint256 proposalId = dao.submitProposal(
            targets, values, calldatas, 0,
            "Register conductors as managers"
        );
        dao.submitVote(uint32(proposalId), true);
        vm.stopPrank();
        return proposalId;
    }

    function _processProposal(uint256 proposalId) internal {
        dao.processProposal(uint32(proposalId), targets, values, calldatas);
    }

    // ========== Deployment Tests ==========

    function test_DAODeployedCorrectly() public view {
        assertEq(dao.safe(), address(safe));
        assertEq(dao.shares(founder), INITIAL_SHARES);
        assertEq(dao.totalShares(), INITIAL_SHARES);
        assertEq(dao.votingPeriod(), VOTING_PERIOD);
        assertEq(dao.gracePeriod(), GRACE_PERIOD);
        assertEq(dao.quorumPercent(), 0);
        assertEq(dao.sponsorThreshold(), 1);
        assertEq(dao.minRetentionPercent(), 66);
    }

    function test_ShareOfferingDeployed() public view {
        assertEq(shareOffering.dao(), address(dao));
        assertEq(shareOffering.safe(), address(safe));
    }

    function test_StipendConductorDeployed() public view {
        assertEq(stipendConductor.dao(), address(dao));
        assertEq(stipendConductor.beneficiary(), founder);
        assertEq(stipendConductor.amount(), STIPEND_AMOUNT);
        assertEq(stipendConductor.interval(), STIPEND_INTERVAL);
    }

    // ========== Proposal Lifecycle Tests ==========

    function test_FounderCanSelfSponsor() public {
        vm.prank(founder);
        uint256 proposalId = dao.submitProposal(
            targets, values, calldatas, 0,
            "Register conductors"
        );
        assertEq(uint256(dao.state(uint32(proposalId))), uint256(IGrandCentral.ProposalState.Voting));
    }

    function test_FounderCanVoteYes() public {
        uint256 proposalId = _submitAndVoteProposal();
        // Verify vote was recorded — yesVotes > 0 implies proposal passes
        vm.warp(block.timestamp + VOTING_PERIOD + GRACE_PERIOD + 1);
        assertEq(uint256(dao.state(uint32(proposalId))), uint256(IGrandCentral.ProposalState.Ready));
    }

    function test_ProposalMovesToGrace() public {
        uint256 proposalId = _submitAndVoteProposal();
        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        assertEq(uint256(dao.state(uint32(proposalId))), uint256(IGrandCentral.ProposalState.Grace));
    }

    function test_ProposalBecomesReady() public {
        uint256 proposalId = _submitAndVoteProposal();
        vm.warp(block.timestamp + VOTING_PERIOD + GRACE_PERIOD + 1);
        assertEq(uint256(dao.state(uint32(proposalId))), uint256(IGrandCentral.ProposalState.Ready));
    }

    // ========== Full Launch Sequence ==========

    function test_FullLaunchSequence() public {
        // Submit + vote
        uint256 proposalId = _submitAndVoteProposal();

        // Warp past vote + grace
        vm.warp(block.timestamp + VOTING_PERIOD + GRACE_PERIOD + 1);

        // Process proposal
        _processProposal(proposalId);

        // Verify conductors are registered as managers
        assertTrue(dao.isManager(address(shareOffering)));
        assertTrue(dao.isManager(address(stipendConductor)));
    }

    function test_StipendExecutableAfterRegistration() public {
        // Full launch
        uint256 proposalId = _submitAndVoteProposal();
        vm.warp(block.timestamp + VOTING_PERIOD + GRACE_PERIOD + 1);
        _processProposal(proposalId);

        // Execute stipend
        uint256 founderBalBefore = founder.balance;
        stipendConductor.execute();
        assertEq(founder.balance, founderBalBefore + STIPEND_AMOUNT);
    }

    function test_StipendRespectsInterval() public {
        // Full launch + first stipend
        uint256 proposalId = _submitAndVoteProposal();
        vm.warp(block.timestamp + VOTING_PERIOD + GRACE_PERIOD + 1);
        _processProposal(proposalId);
        stipendConductor.execute();

        // Second stipend too early
        vm.warp(block.timestamp + STIPEND_INTERVAL - 1);
        vm.expectRevert("too early");
        stipendConductor.execute();

        // Second stipend on time
        vm.warp(block.timestamp + 1);
        stipendConductor.execute();
        assertEq(founder.balance, STIPEND_AMOUNT * 2);
    }

    function test_ShareOfferingFunctionalAfterRegistration() public {
        // Full launch
        uint256 proposalId = _submitAndVoteProposal();
        vm.warp(block.timestamp + VOTING_PERIOD + GRACE_PERIOD + 1);
        _processProposal(proposalId);

        // Create a tranche via DAO proposal
        address[] memory t = new address[](1);
        t[0] = address(shareOffering);
        uint256[] memory v = new uint256[](1);
        v[0] = 0;
        bytes[] memory c = new bytes[](1);
        c[0] = abi.encodeWithSelector(
            ShareOffering.createTranche.selector,
            0.1 ether,  // price per share
            100,        // total shares
            7 days,     // duration
            0,          // min shares
            0,          // max per address
            bytes32(0)  // no whitelist
        );

        vm.prank(founder);
        uint256 trancheProposal = dao.submitProposal(t, v, c, 0, "Create tranche");
        vm.prank(founder);
        dao.submitVote(uint32(trancheProposal), true);
        vm.warp(block.timestamp + VOTING_PERIOD + GRACE_PERIOD + 1);
        dao.processProposal(uint32(trancheProposal), t, v, c);

        // Verify tranche was created
        assertEq(shareOffering.currentTrancheId(), 1);
    }

    // ========== Edge Cases ==========

    function test_ConductorsNotManagerBeforeProposal() public view {
        assertFalse(dao.isManager(address(shareOffering)));
        assertFalse(dao.isManager(address(stipendConductor)));
    }

    function test_StipendFailsBeforeRegistration() public {
        vm.expectRevert("stipend transfer failed");
        stipendConductor.execute();
    }

    function test_ProcessTooEarly_Reverts() public {
        uint256 proposalId = _submitAndVoteProposal();

        // Still in voting
        vm.expectRevert("!ready");
        _processProposal(proposalId);

        // In grace
        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        vm.expectRevert("!ready");
        _processProposal(proposalId);
    }

    function test_ProposalPassesWithMinRetention() public {
        // Full launch — no ragequit so 100% retention, well above 66%
        uint256 proposalId = _submitAndVoteProposal();
        vm.warp(block.timestamp + VOTING_PERIOD + GRACE_PERIOD + 1);
        _processProposal(proposalId);

        bool[4] memory status = dao.getProposalStatus(uint32(proposalId));
        assertTrue(status[1]); // processed
        assertTrue(status[2]); // passed
        assertFalse(status[3]); // no action failure
    }

    function test_NonFounderCannotSelfSponsor() public {
        address nobody = makeAddr("nobody");
        vm.prank(nobody);
        uint256 proposalId = dao.submitProposal(
            targets, values, calldatas, 0, "rogue proposal"
        );
        // Should be submitted but not sponsored (no shares)
        assertEq(uint256(dao.state(uint32(proposalId))), uint256(IGrandCentral.ProposalState.Submitted));
    }

    function test_AnyoneCanProcessReadyProposal() public {
        uint256 proposalId = _submitAndVoteProposal();
        vm.warp(block.timestamp + VOTING_PERIOD + GRACE_PERIOD + 1);

        // Process from random address
        address anyone = makeAddr("anyone");
        vm.prank(anyone);
        _processProposal(proposalId);

        assertTrue(dao.isManager(address(shareOffering)));
    }
}
