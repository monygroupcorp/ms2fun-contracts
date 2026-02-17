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

    function test_InitialSharesAssigned() public view {
        assertEq(dao.shares(founder), INITIAL_SHARES);
        assertEq(dao.totalShares(), INITIAL_SHARES);
    }

    function test_GovernanceConfigSet() public view {
        assertEq(dao.votingPeriod(), VOTING_PERIOD);
        assertEq(dao.gracePeriod(), GRACE_PERIOD);
        assertEq(dao.quorumPercent(), QUORUM_PERCENT);
        assertEq(dao.sponsorThreshold(), SPONSOR_THRESHOLD);
        assertEq(dao.minRetentionPercent(), MIN_RETENTION);
    }

    function test_SafeAddressSet() public view {
        assertEq(dao.safe(), address(mockSafe));
    }

    function test_NonMemberHasZeroShares() public view {
        assertEq(dao.shares(alice), 0);
    }

    // ========== Share Minting via DAO ==========

    function test_MintShares_ViaDAO() public {
        address[] memory to = new address[](1);
        to[0] = alice;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100;

        vm.prank(address(dao));
        dao.mintShares(to, amounts);

        assertEq(dao.shares(alice), 100);
        assertEq(dao.totalShares(), INITIAL_SHARES + 100);
    }

    function test_MintShares_RevertIfNotAuthorized() public {
        address[] memory to = new address[](1);
        to[0] = alice;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100;

        vm.prank(alice);
        vm.expectRevert("!dao & !manager");
        dao.mintShares(to, amounts);
    }

    function test_BurnShares_ViaDAO() public {
        address[] memory from = new address[](1);
        from[0] = founder;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 200;

        vm.prank(address(dao));
        dao.burnShares(from, amounts);

        assertEq(dao.shares(founder), INITIAL_SHARES - 200);
        assertEq(dao.totalShares(), INITIAL_SHARES - 200);
    }

    // ========== Loot Tests ==========

    function test_MintLoot_ViaDAO() public {
        address[] memory to = new address[](1);
        to[0] = alice;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 500;

        vm.prank(address(dao));
        dao.mintLoot(to, amounts);

        assertEq(dao.loot(alice), 500);
        assertEq(dao.totalLoot(), 500);
    }

    function test_MintLoot_RevertIfNotAuthorized() public {
        address[] memory to = new address[](1);
        to[0] = alice;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 500;

        vm.prank(alice);
        vm.expectRevert("!dao & !manager");
        dao.mintLoot(to, amounts);
    }

    function test_BurnLoot_ViaDAO() public {
        // First mint loot
        address[] memory to = new address[](1);
        to[0] = alice;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 500;
        vm.prank(address(dao));
        dao.mintLoot(to, amounts);

        // Burn some
        address[] memory from = new address[](1);
        from[0] = alice;
        uint256[] memory burnAmounts = new uint256[](1);
        burnAmounts[0] = 200;
        vm.prank(address(dao));
        dao.burnLoot(from, burnAmounts);

        assertEq(dao.loot(alice), 300);
        assertEq(dao.totalLoot(), 300);
    }

    function test_BurnLoot_RevertIfInsufficient() public {
        address[] memory from = new address[](1);
        from[0] = alice;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1;

        vm.prank(address(dao));
        vm.expectRevert("insufficient loot");
        dao.burnLoot(from, amounts);
    }

    function test_LootCheckpoints() public {
        uint256 beforeMintTime = 1000;
        uint256 mintTime = 1000 + 1 days;

        vm.warp(mintTime);
        address[] memory to = new address[](1);
        to[0] = alice;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 500;
        vm.prank(address(dao));
        dao.mintLoot(to, amounts);

        assertEq(dao.getLootAt(alice, beforeMintTime), 0);
        assertEq(dao.getLootAt(alice, mintTime), 500);
        assertEq(dao.getTotalLootAt(beforeMintTime), 0);
        assertEq(dao.getTotalLootAt(mintTime), 500);
    }

    function test_LootHolder_CannotVote() public {
        // Give alice only loot (no shares)
        address[] memory to = new address[](1);
        to[0] = alice;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 500;
        vm.prank(address(dao));
        dao.mintLoot(to, amounts);

        // Founder submits proposal
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _buildSendETHProposal(bob, 1 ether);
        vm.prank(founder);
        uint256 id = dao.submitProposal(t, v, c, 0, "test");

        // Alice (loot-only) tries to vote — should fail
        vm.prank(alice);
        vm.expectRevert("!member");
        dao.submitVote(uint32(id), true);
    }

    function test_LootHolder_CannotSponsor() public {
        // Give alice only loot (no shares)
        address[] memory to = new address[](1);
        to[0] = alice;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 500;
        vm.prank(address(dao));
        dao.mintLoot(to, amounts);

        // Non-member submits unsponsored proposal
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _buildSendETHProposal(bob, 1 ether);
        vm.prank(bob);
        uint256 id = dao.submitProposal(t, v, c, 0, "test");

        // Alice tries to sponsor — should fail (loot doesn't count)
        vm.prank(alice);
        vm.expectRevert("!sponsor");
        dao.sponsorProposal(uint32(id));
    }

    function test_MintLoot_SettlesClaims() public {
        // Give alice shares and fund claims
        address[] memory to = new address[](1);
        to[0] = alice;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100;
        vm.prank(address(dao));
        dao.mintShares(to, amounts);

        // Fund claims pool: total weight = 1100 shares, 11 ether → 0.01 per unit
        vm.prank(address(dao));
        dao.fundClaimsPool(11 ether);

        uint256 pendingBefore = dao.pendingClaim(alice);
        assertEq(pendingBefore, 1 ether); // 100/1100 * 11

        // Minting loot should settle alice's pending claim
        uint256[] memory lootAmounts = new uint256[](1);
        lootAmounts[0] = 200;
        vm.prank(address(dao));
        dao.mintLoot(to, lootAmounts);

        // After settlement, pending should be 0
        assertEq(dao.pendingClaim(alice), 0);
        assertEq(alice.balance, 1 ether);
    }

    // ========== Checkpoint Tests ==========

    function test_GetSharesAt_ReturnsCurrentBalance() public view {
        assertEq(dao.getSharesAt(founder, block.timestamp), INITIAL_SHARES);
    }

    function test_GetSharesAt_ReturnsZeroBeforeMint() public view {
        assertEq(dao.getSharesAt(founder, 0), 0);
    }

    function test_GetSharesAt_HistoricalBalance() public {
        uint256 beforeMintTime = 1000;
        uint256 mintTime = 1000 + 1 days;

        vm.warp(mintTime);
        address[] memory to = new address[](1);
        to[0] = alice;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100;
        vm.prank(address(dao));
        dao.mintShares(to, amounts);

        assertEq(dao.getSharesAt(alice, beforeMintTime), 0);
        assertEq(dao.getSharesAt(alice, mintTime), 100);
        assertEq(dao.getTotalSharesAt(beforeMintTime), INITIAL_SHARES);
        assertEq(dao.getTotalSharesAt(mintTime), INITIAL_SHARES + 100);
    }

    // ========== Helper: build a simple ETH-send proposal ==========

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

    function test_SubmitProposal_AutoSponsors() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _buildSendETHProposal(alice, 1 ether);

        vm.prank(founder);
        uint256 id = dao.submitProposal(t, v, c, 0, "Send 1 ETH to alice");

        assertEq(id, 1);
        assertEq(uint8(dao.state(uint32(id))), uint8(IGrandCentral.ProposalState.Voting));
    }

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
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _buildSendETHProposal(alice, 1 ether);

        vm.prank(founder);
        uint256 id = dao.submitProposal(t, v, c, 0, "test");

        vm.prank(founder);
        dao.submitVote(uint32(id), true);

        (,,,,,,uint256 yesVotes, uint256 noVotes,,,,) = dao.proposals(uint32(id));
        assertEq(yesVotes, INITIAL_SHARES);
        assertEq(noVotes, 0);
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
        address[] memory to = new address[](1);
        to[0] = alice;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100;
        vm.prank(address(dao));
        dao.mintShares(to, amounts);

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

    function test_ProcessProposal_ExecutesETHSendViaSafe() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _buildSendETHProposal(alice, 1 ether);
        uint32 id = _createAndPassProposal(t, v, c);

        dao.processProposal(id, t, v, c);

        assertEq(alice.balance, 1 ether);
        assertEq(uint8(dao.state(id)), uint8(IGrandCentral.ProposalState.Processed));
        // Verify it went through safe
        assertEq(mockSafe.executionCount(), 1);
    }

    function test_ProcessProposal_ExecutesDAOSelfCall() public {
        address[] memory to = new address[](1);
        to[0] = alice;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 50;
        bytes memory mintCall = abi.encodeCall(dao.mintShares, (to, amounts));

        (address[] memory t, uint256[] memory v, bytes[] memory c) = _buildDAOCallProposal(mintCall);
        uint32 id = _createAndPassProposal(t, v, c);

        dao.processProposal(id, t, v, c);

        assertEq(dao.shares(alice), 50);
        assertEq(uint8(dao.state(id)), uint8(IGrandCentral.ProposalState.Processed));
    }

    function test_ProcessProposal_RevertIfNotReady() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _buildSendETHProposal(alice, 1 ether);

        vm.prank(founder);
        uint256 id = dao.submitProposal(t, v, c, 0, "test");

        vm.expectRevert("!ready");
        dao.processProposal(uint32(id), t, v, c);
    }

    function test_ProcessProposal_RevertIfWrongCalldata() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _buildSendETHProposal(alice, 1 ether);
        uint32 id = _createAndPassProposal(t, v, c);

        v[0] = 5 ether;
        vm.expectRevert("incorrect calldata");
        dao.processProposal(id, t, v, c);
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

    function test_Ragequit_RevertIfInsufficientShares() public {
        vm.prank(alice);
        vm.expectRevert("insufficient shares");
        dao.ragequit(1, 0);
    }

    function test_Ragequit_RevertIfInsufficientLoot() public {
        vm.prank(alice);
        vm.expectRevert("insufficient loot");
        dao.ragequit(0, 1);
    }

    function test_Ragequit_RoutedThroughSafe() public {
        vm.prank(address(dao));
        dao.fundRagequitPool(20 ether);

        vm.prank(founder);
        dao.ragequit(100, 0);

        // Should have recorded an execution in the mock safe
        assertGt(mockSafe.executionCount(), 0);
    }

    // ========== Claims Pool Tests ==========

    function test_FundClaimsPool() public {
        vm.prank(address(dao));
        dao.fundClaimsPool(5 ether);

        assertEq(dao.claimsPoolBalance(), 5 ether);
        assertEq(dao.generalFunds(), 95 ether);
    }

    function test_FundClaimsPool_UsesSharesPlusLoot() public {
        // Mint loot to alice
        address[] memory to = new address[](1);
        to[0] = alice;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100;
        vm.prank(address(dao));
        dao.mintLoot(to, amounts);

        // Total weight = 1000 shares + 100 loot = 1100
        vm.prank(address(dao));
        dao.fundClaimsPool(11 ether);

        // Alice (100 loot) should have pending: 100/1100 * 11 = 1 ETH
        assertEq(dao.pendingClaim(alice), 1 ether);
        // Founder (1000 shares) should have pending: 1000/1100 * 11 = 10 ETH
        assertEq(dao.pendingClaim(founder), 10 ether);
    }

    function test_Claim_ProportionalDistribution() public {
        // Mint 100 shares to alice (total shares 1100)
        address[] memory to = new address[](1);
        to[0] = alice;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100;
        vm.prank(address(dao));
        dao.mintShares(to, amounts);

        vm.prank(address(dao));
        dao.fundClaimsPool(11 ether);

        uint256 pending = dao.pendingClaim(alice);
        assertEq(pending, 1 ether);

        vm.prank(alice);
        dao.claim();

        assertEq(alice.balance, 1 ether);
        assertEq(dao.pendingClaim(alice), 0);
    }

    function test_Claim_LootHolderGetsClaims() public {
        // Give alice loot only
        address[] memory to = new address[](1);
        to[0] = alice;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100;
        vm.prank(address(dao));
        dao.mintLoot(to, amounts);

        // Total weight = 1100
        vm.prank(address(dao));
        dao.fundClaimsPool(11 ether);

        // Alice with 100 loot should get 1 ETH
        assertEq(dao.pendingClaim(alice), 1 ether);

        vm.prank(alice);
        dao.claim();
        assertEq(alice.balance, 1 ether);
    }

    function test_Claim_MultipleFundings() public {
        address[] memory to = new address[](1);
        to[0] = alice;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100;
        vm.prank(address(dao));
        dao.mintShares(to, amounts);

        vm.prank(address(dao));
        dao.fundClaimsPool(11 ether);

        vm.prank(alice);
        dao.claim();
        assertEq(alice.balance, 1 ether);

        vm.prank(address(dao));
        dao.fundClaimsPool(5.5 ether);

        vm.prank(alice);
        dao.claim();
        assertEq(alice.balance, 1.5 ether);
    }

    function test_Claim_NoPendingReverts() public {
        vm.prank(alice);
        vm.expectRevert("nothing to claim");
        dao.claim();
    }

    function test_Claim_RoutedThroughSafe() public {
        address[] memory to = new address[](1);
        to[0] = alice;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100;
        vm.prank(address(dao));
        dao.mintShares(to, amounts);

        vm.prank(address(dao));
        dao.fundClaimsPool(11 ether);

        vm.prank(alice);
        dao.claim();

        assertGt(mockSafe.executionCount(), 0);
    }

    function test_RagequitAndClaimIndependent() public {
        // Mint shares to alice
        address[] memory to = new address[](1);
        to[0] = alice;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100;
        vm.prank(address(dao));
        dao.mintShares(to, amounts);

        // Fund both pools
        vm.prank(address(dao));
        dao.fundRagequitPool(20 ether);
        vm.prank(address(dao));
        dao.fundClaimsPool(11 ether);

        // Alice claims
        vm.prank(alice);
        dao.claim();
        uint256 claimAmount = alice.balance;
        assertEq(claimAmount, 1 ether);

        // Alice ragequits
        vm.prank(alice);
        dao.ragequit(100, 0);
        uint256 ragequitAmount = alice.balance - claimAmount;
        uint256 expectedRagequit = (uint256(100) * 20 ether) / 1100;
        assertEq(ragequitAmount, expectedRagequit);
    }

    // ========== Conductor Tests ==========

    function test_SetConductors() public {
        address[] memory addrs = new address[](1);
        addrs[0] = alice;
        uint256[] memory perms = new uint256[](1);
        perms[0] = 2; // manager

        vm.prank(address(dao));
        dao.setConductors(addrs, perms);

        assertTrue(dao.isManager(alice));
        assertFalse(dao.isAdmin(alice));
        assertFalse(dao.isGovernor(alice));
        assertEq(dao.conductors(alice), 2);
    }

    function test_SetConductors_RevertIfNotDAO() public {
        address[] memory addrs = new address[](1);
        addrs[0] = alice;
        uint256[] memory perms = new uint256[](1);
        perms[0] = 7;

        vm.prank(founder);
        vm.expectRevert(bytes("!dao"));
        dao.setConductors(addrs, perms);
    }

    function test_SetConductors_EmitsEvent() public {
        address[] memory addrs = new address[](1);
        addrs[0] = alice;
        uint256[] memory perms = new uint256[](1);
        perms[0] = 2;

        vm.expectEmit(true, false, false, true);
        emit IGrandCentral.ConductorSet(alice, 2);

        vm.prank(address(dao));
        dao.setConductors(addrs, perms);
    }

    function test_ManagerConductor_CanMintShares() public {
        address[] memory addrs = new address[](1);
        addrs[0] = alice;
        uint256[] memory perms = new uint256[](1);
        perms[0] = 2;
        vm.prank(address(dao));
        dao.setConductors(addrs, perms);

        address[] memory to = new address[](1);
        to[0] = bob;
        uint256[] memory amountsArr = new uint256[](1);
        amountsArr[0] = 50;
        vm.prank(alice);
        dao.mintShares(to, amountsArr);

        assertEq(dao.shares(bob), 50);
    }

    function test_SetGovernanceConfig() public {
        vm.prank(address(dao));
        dao.setGovernanceConfig(3 days, 1 days, 10, 5, 50);

        assertEq(dao.votingPeriod(), 3 days);
        assertEq(dao.gracePeriod(), 1 days);
        assertEq(dao.quorumPercent(), 10);
        assertEq(dao.sponsorThreshold(), 5);
        assertEq(dao.minRetentionPercent(), 50);
    }

    function test_GovernorConductor_CanSetConfig() public {
        address[] memory addrs = new address[](1);
        addrs[0] = alice;
        uint256[] memory perms = new uint256[](1);
        perms[0] = 4; // governor
        vm.prank(address(dao));
        dao.setConductors(addrs, perms);

        vm.prank(alice);
        dao.setGovernanceConfig(3 days, 1 days, 10, 5, 50);

        assertEq(dao.votingPeriod(), 3 days);
    }

    function test_PermissionBitmask_Combined() public {
        address[] memory addrs = new address[](1);
        addrs[0] = alice;
        uint256[] memory perms = new uint256[](1);
        perms[0] = 7;

        vm.prank(address(dao));
        dao.setConductors(addrs, perms);

        assertTrue(dao.isAdmin(alice));
        assertTrue(dao.isManager(alice));
        assertTrue(dao.isGovernor(alice));
    }

    function test_RevokeConductor() public {
        address[] memory addrs = new address[](1);
        addrs[0] = alice;
        uint256[] memory perms = new uint256[](1);
        perms[0] = 7;
        vm.prank(address(dao));
        dao.setConductors(addrs, perms);

        perms[0] = 0;
        vm.prank(address(dao));
        dao.setConductors(addrs, perms);

        assertFalse(dao.isAdmin(alice));
        assertFalse(dao.isManager(alice));
        assertFalse(dao.isGovernor(alice));
    }
}
