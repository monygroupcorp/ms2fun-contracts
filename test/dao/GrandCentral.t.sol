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
        vm.expectRevert(GrandCentral.Unauthorized.selector);
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
        vm.expectRevert(GrandCentral.Unauthorized.selector);
        dao.mintLoot(to, amounts);
    }


    function test_BurnLoot_ViaDAO() public {
        // First mint loot
        { address[] memory to = new address[](1);
        to[0] = alice;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 500;
        vm.prank(address(dao));
        dao.mintLoot(to, amounts); }

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
        vm.expectRevert(GrandCentral.InsufficientLoot.selector);
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
        { address[] memory to = new address[](1);
        to[0] = alice;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 500;
        vm.prank(address(dao));
        dao.mintLoot(to, amounts); }

        // Founder submits proposal
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _buildSendETHProposal(bob, 1 ether);
        vm.prank(founder);
        uint256 id = dao.submitProposal(t, v, c, 0, "test");

        // Alice (loot-only) tries to vote — should fail
        vm.prank(alice);
        vm.expectRevert(GrandCentral.NotMember.selector);
        dao.submitVote(uint32(id), true);
    }


    function test_LootHolder_CannotSponsor() public {
        // Give alice only loot (no shares)
        { address[] memory to = new address[](1);
        to[0] = alice;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 500;
        vm.prank(address(dao));
        dao.mintLoot(to, amounts); }

        // Non-member submits unsponsored proposal
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _buildSendETHProposal(bob, 1 ether);
        vm.prank(bob);
        uint256 id = dao.submitProposal(t, v, c, 0, "test");

        // Alice tries to sponsor — should fail (loot doesn't count)
        vm.prank(alice);
        vm.expectRevert(GrandCentral.InsufficientSponsorShares.selector);
        dao.sponsorProposal(uint32(id));
    }


    function test_MintLoot_SettlesClaims() public {
        // Give alice shares and fund claims
        { address[] memory to = new address[](1);
        to[0] = alice;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100;
        vm.prank(address(dao));
        dao.mintShares(to, amounts); }

        // Fund claims pool: total weight = 1100 shares, 11 ether → 0.01 per unit
        vm.prank(address(dao));
        dao.fundClaimsPool(11 ether);

        uint256 pendingBefore = dao.pendingClaim(alice);
        assertEq(pendingBefore, 1 ether); // 100/1100 * 11

        // Minting loot should settle alice's pending claim
        address[] memory to2 = new address[](1);
        to2[0] = alice;
        uint256[] memory lootAmounts = new uint256[](1);
        lootAmounts[0] = 200;
        vm.prank(address(dao));
        dao.mintLoot(to2, lootAmounts);

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


    function test_SubmitProposal_AutoSponsors() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _buildSendETHProposal(alice, 1 ether);

        vm.prank(founder);
        uint256 id = dao.submitProposal(t, v, c, 0, "Send 1 ETH to alice");

        assertEq(id, 1);
        assertEq(uint8(dao.state(uint32(id))), uint8(IGrandCentral.ProposalState.Voting));
    }


}
