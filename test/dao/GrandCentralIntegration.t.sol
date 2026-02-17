// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {GrandCentral} from "../../src/dao/GrandCentral.sol";
import {IGrandCentral} from "../../src/dao/interfaces/IGrandCentral.sol";
import {StipendConductor} from "../../src/dao/conductors/StipendConductor.sol";
import {MockSafe} from "../mocks/MockSafe.sol";

contract GrandCentralIntegrationTest is Test {
    GrandCentral public dao;
    MockSafe public mockSafe;
    StipendConductor public stipend;

    address public founder = makeAddr("founder");
    address public buyer = makeAddr("buyer");
    address public auditor = makeAddr("auditor");

    uint256 constant INITIAL_SHARES = 1000;

    function setUp() public {
        mockSafe = new MockSafe();
        dao = new GrandCentral(address(mockSafe), founder, INITIAL_SHARES, 5 days, 2 days, 0, 1, 66);
        vm.deal(address(mockSafe), 100 ether);
    }

    // ========== Full Lifecycle: Tribute Proposal ==========

    function test_TributeProposal_MintSharesToBuyer() public {
        // Buyer tributes 10 ETH directly to Safe
        vm.deal(buyer, 10 ether);
        vm.prank(buyer);
        (bool sent,) = address(mockSafe).call{value: 10 ether}("");
        assertTrue(sent);

        // Founder submits proposal to mint shares to buyer
        address[] memory targets = new address[](1);
        targets[0] = address(dao);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);

        address[] memory to = new address[](1);
        to[0] = buyer;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 50;
        calldatas[0] = abi.encodeCall(dao.mintShares, (to, amounts));

        vm.prank(founder);
        uint256 id = dao.submitProposal(targets, values, calldatas, 0, "Tribute: 10 ETH for 50 shares");

        vm.prank(founder);
        dao.submitVote(uint32(id), true);

        vm.warp(block.timestamp + 5 days + 2 days + 1);
        dao.processProposal(uint32(id), targets, values, calldatas);

        assertEq(dao.shares(buyer), 50);
        assertEq(dao.totalShares(), INITIAL_SHARES + 50);
    }

    // ========== Ragequit During Grace Period ==========

    function test_RagequitDuringGrace() public {
        // Mint shares to buyer
        address[] memory to = new address[](1);
        to[0] = buyer;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100;
        vm.prank(address(dao));
        dao.mintShares(to, amounts);

        vm.prank(address(dao));
        dao.fundRagequitPool(20 ether);

        // Founder submits a controversial proposal
        address[] memory targets = new address[](1);
        targets[0] = makeAddr("random");
        uint256[] memory values = new uint256[](1);
        values[0] = 50 ether;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = "";

        vm.prank(founder);
        uint256 id = dao.submitProposal(targets, values, calldatas, 0, "drain treasury");

        vm.prank(founder);
        dao.submitVote(uint32(id), true);

        vm.warp(block.timestamp + 5 days + 1);
        assertEq(uint8(dao.state(uint32(id))), uint8(IGrandCentral.ProposalState.Grace));

        // Buyer ragequits during grace
        vm.prank(buyer);
        dao.ragequit(100, 0);

        assertEq(dao.shares(buyer), 0);
        uint256 expectedPayout = (uint256(100) * 20 ether) / 1100;
        assertGt(buyer.balance, 0);
        assertEq(buyer.balance, expectedPayout);
    }

    // ========== Multi-Action: Fund Pools + Mint ==========

    function test_MultiAction_FundPoolsAndMint() public {
        address[] memory targets = new address[](3);
        uint256[] memory values = new uint256[](3);
        bytes[] memory calldatas = new bytes[](3);

        // Action 1: Fund ragequit pool (DAO self-call)
        targets[0] = address(dao);
        calldatas[0] = abi.encodeCall(dao.fundRagequitPool, (10 ether));

        // Action 2: Fund claims pool (DAO self-call)
        targets[1] = address(dao);
        calldatas[1] = abi.encodeCall(dao.fundClaimsPool, (5 ether));

        // Action 3: Mint shares to auditor (DAO self-call)
        address[] memory to = new address[](1);
        to[0] = auditor;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10;
        targets[2] = address(dao);
        calldatas[2] = abi.encodeCall(dao.mintShares, (to, amounts));

        vm.prank(founder);
        uint256 id = dao.submitProposal(targets, values, calldatas, 0, "fund pools + audit bounty");

        vm.prank(founder);
        dao.submitVote(uint32(id), true);

        vm.warp(block.timestamp + 5 days + 2 days + 1);
        dao.processProposal(uint32(id), targets, values, calldatas);

        assertEq(dao.ragequitPool(), 10 ether);
        assertEq(dao.claimsPoolBalance(), 5 ether);
        assertEq(dao.shares(auditor), 10);
    }

    // ========== Founder Majority Passes Unilaterally ==========

    function test_FounderMajority_PassesUnilaterally() public {
        address[] memory to = new address[](1);
        to[0] = buyer;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100;
        vm.prank(address(dao));
        dao.mintShares(to, amounts);

        address[] memory targets = new address[](1);
        targets[0] = makeAddr("ops");
        uint256[] memory values = new uint256[](1);
        values[0] = 5 ether;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = "";

        vm.prank(founder);
        uint256 id = dao.submitProposal(targets, values, calldatas, 0, "ops");

        vm.prank(founder);
        dao.submitVote(uint32(id), true);
        vm.prank(buyer);
        dao.submitVote(uint32(id), false);

        vm.warp(block.timestamp + 5 days + 2 days + 1);
        dao.processProposal(uint32(id), targets, values, calldatas);

        bool[4] memory status = dao.getProposalStatus(uint32(id));
        assertTrue(status[2]); // passed
    }

    // ========== StipendConductor Integration ==========

    function test_StipendConductor_FullFlow() public {
        stipend = new StipendConductor(address(dao), founder, 6 ether, 30 days);

        // Register stipend as manager via proposal
        address[] memory targets = new address[](1);
        targets[0] = address(dao);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);

        address[] memory addrs = new address[](1);
        addrs[0] = address(stipend);
        uint256[] memory perms = new uint256[](1);
        perms[0] = 2;
        calldatas[0] = abi.encodeCall(dao.setConductors, (addrs, perms));

        vm.prank(founder);
        uint256 id = dao.submitProposal(targets, values, calldatas, 0, "register stipend");
        vm.prank(founder);
        dao.submitVote(uint32(id), true);
        vm.warp(block.timestamp + 5 days + 2 days + 1);
        dao.processProposal(uint32(id), targets, values, calldatas);

        // Now execute stipend
        stipend.execute();
        assertEq(founder.balance, 6 ether);

        vm.expectRevert("too early");
        stipend.execute();

        vm.warp(block.timestamp + 30 days + 1);
        stipend.execute();
        assertEq(founder.balance, 12 ether);
    }

    // ========== Claims Pool Lifecycle ==========

    function test_ClaimsPool_FullLifecycle() public {
        // Mint shares to buyer (100) and auditor (10)
        address[] memory to = new address[](2);
        to[0] = buyer;
        to[1] = auditor;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100;
        amounts[1] = 10;
        vm.prank(address(dao));
        dao.mintShares(to, amounts);

        // Total: 1000 + 100 + 10 = 1110

        vm.prank(address(dao));
        dao.fundClaimsPool(11.1 ether);

        vm.prank(founder);
        dao.claim();
        assertEq(founder.balance, 10 ether);

        vm.prank(buyer);
        dao.claim();
        assertEq(buyer.balance, 1 ether);

        vm.prank(auditor);
        dao.claim();
        assertEq(auditor.balance, 0.1 ether);
    }

    // ========== Loot Integration: OTC Drip Buyer ==========

    function test_LootDripBuyer_GetsDividendsButCannotVote() public {
        // Mint loot to buyer (OTC drip buyer)
        address[] memory to = new address[](1);
        to[0] = buyer;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 200;
        vm.prank(address(dao));
        dao.mintLoot(to, amounts);

        // Total weight: 1000 shares + 200 loot = 1200
        vm.prank(address(dao));
        dao.fundClaimsPool(12 ether);

        // Buyer claims: 200/1200 * 12 = 2 ETH
        assertEq(dao.pendingClaim(buyer), 2 ether);
        vm.prank(buyer);
        dao.claim();
        assertEq(buyer.balance, 2 ether);

        // Buyer cannot vote
        address[] memory targets = new address[](1);
        targets[0] = makeAddr("ops");
        uint256[] memory values = new uint256[](1);
        values[0] = 1 ether;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = "";

        vm.prank(founder);
        uint256 id = dao.submitProposal(targets, values, calldatas, 0, "ops");

        vm.prank(buyer);
        vm.expectRevert("!member");
        dao.submitVote(uint32(id), true);
    }

    // ========== Ragequit with Loot ==========

    function test_RagequitWithLoot_DuringGrace() public {
        // Mint loot to buyer
        address[] memory to = new address[](1);
        to[0] = buyer;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 200;
        vm.prank(address(dao));
        dao.mintLoot(to, amounts);

        vm.prank(address(dao));
        dao.fundRagequitPool(24 ether);

        // Founder submits controversial proposal
        address[] memory targets = new address[](1);
        targets[0] = makeAddr("random");
        uint256[] memory values = new uint256[](1);
        values[0] = 50 ether;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = "";

        vm.prank(founder);
        uint256 id = dao.submitProposal(targets, values, calldatas, 0, "drain treasury");
        vm.prank(founder);
        dao.submitVote(uint32(id), true);

        vm.warp(block.timestamp + 5 days + 1);
        assertEq(uint8(dao.state(uint32(id))), uint8(IGrandCentral.ProposalState.Grace));

        // Buyer ragequits loot during grace
        // Total weight: 1000 shares + 200 loot = 1200
        uint256 expectedPayout = (uint256(200) * 24 ether) / 1200;

        vm.prank(buyer);
        dao.ragequit(0, 200);

        assertEq(dao.loot(buyer), 0);
        assertEq(buyer.balance, expectedPayout);
    }

    // ========== All Treasury Ops Route Through Safe ==========

    function test_AllTreasuryOpsRouteThroughSafe() public {
        // Mint shares and loot
        address[] memory to = new address[](1);
        to[0] = buyer;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100;
        vm.prank(address(dao));
        dao.mintShares(to, amounts);
        vm.prank(address(dao));
        dao.mintLoot(to, amounts);

        uint256 execsBefore = mockSafe.executionCount();

        // Fund and claim
        vm.prank(address(dao));
        dao.fundClaimsPool(11 ether);

        vm.prank(buyer);
        dao.claim();

        // Ragequit
        vm.prank(address(dao));
        dao.fundRagequitPool(10 ether);

        vm.prank(buyer);
        dao.ragequit(50, 50);

        // All ops should have gone through safe
        assertGt(mockSafe.executionCount(), execsBefore);
    }
}
