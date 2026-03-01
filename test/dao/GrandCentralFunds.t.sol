// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {GrandCentral} from "../../src/dao/GrandCentral.sol";
import {IGrandCentral} from "../../src/dao/interfaces/IGrandCentral.sol";
import {MockSafe} from "../mocks/MockSafe.sol";

contract GrandCentralFundsTest is Test {
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
        { address[] memory addrs = new address[](1);
        addrs[0] = alice;
        uint256[] memory perms = new uint256[](1);
        perms[0] = 2;
        vm.prank(address(dao));
        dao.setConductors(addrs, perms); }

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
