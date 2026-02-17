// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {GrandCentral} from "../../src/dao/GrandCentral.sol";
import {ShareOffering} from "../../src/dao/conductors/ShareOffering.sol";
import {MockSafe} from "../mocks/MockSafe.sol";

contract ShareOfferingTest is Test {
    GrandCentral public dao;
    MockSafe public mockSafe;
    ShareOffering public offering;

    address public founder = makeAddr("founder");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");

    uint256 constant INITIAL_SHARES = 1000;
    uint256 constant PRICE = 0.1 ether;
    uint256 constant TOTAL_SHARES = 20;
    uint256 constant DURATION = 7 days;

    function setUp() public {
        mockSafe = new MockSafe();
        dao = new GrandCentral(address(mockSafe), founder, INITIAL_SHARES, 5 days, 2 days, 0, 1, 66);

        offering = new ShareOffering(address(dao));

        // Register offering as manager conductor
        address[] memory addrs = new address[](1);
        addrs[0] = address(offering);
        uint256[] memory perms = new uint256[](1);
        perms[0] = 2; // manager
        vm.prank(address(dao));
        dao.setConductors(addrs, perms);
    }

    // ============ Constructor ============

    function test_Constructor_SetsImmutables() public view {
        assertEq(offering.dao(), address(dao));
        assertEq(offering.safe(), address(mockSafe));
    }

    function test_Constructor_RevertsOnZeroAddress() public {
        vm.expectRevert(bytes("invalid dao"));
        new ShareOffering(address(0));
    }

    // ============ createTranche ============

    function test_CreateTranche_Success() public {
        vm.prank(address(dao));
        uint256 id = offering.createTranche(PRICE, TOTAL_SHARES, DURATION, 0, 0, bytes32(0));

        assertEq(id, 1);
        assertEq(offering.currentTrancheId(), 1);

        ShareOffering.Tranche memory t = offering.getTranche(id);
        assertEq(t.pricePerShare, PRICE);
        assertEq(t.totalShares, TOTAL_SHARES);
        assertEq(t.committedShares, 0);
        assertEq(t.totalETHCommitted, 0);
        assertEq(t.startTime, uint40(block.timestamp));
        assertEq(t.endTime, uint40(block.timestamp + DURATION));
        assertEq(t.finalizeDeadline, uint40(block.timestamp + DURATION + 7 days));
        assertEq(t.minShares, 0);
        assertEq(t.maxSharesPerAddress, 0);
        assertEq(uint8(t.status), uint8(ShareOffering.TrancheStatus.Active));
        assertEq(t.whitelistRoot, bytes32(0));
    }

    function test_CreateTranche_RevertNotDAO() public {
        vm.prank(alice);
        vm.expectRevert(bytes("!dao"));
        offering.createTranche(PRICE, TOTAL_SHARES, DURATION, 0, 0, bytes32(0));
    }

    function test_CreateTranche_RevertIfActiveExists() public {
        vm.prank(address(dao));
        offering.createTranche(PRICE, TOTAL_SHARES, DURATION, 0, 0, bytes32(0));

        vm.prank(address(dao));
        vm.expectRevert(bytes("active tranche exists"));
        offering.createTranche(PRICE, TOTAL_SHARES, DURATION, 0, 0, bytes32(0));
    }

    function test_CreateTranche_AfterFinalized() public {
        _createAndFinalizeEmptyTranche();

        vm.prank(address(dao));
        uint256 id = offering.createTranche(PRICE, TOTAL_SHARES, DURATION, 0, 0, bytes32(0));
        assertEq(id, 2);
    }

    function test_CreateTranche_AfterCancelled() public {
        vm.prank(address(dao));
        offering.createTranche(PRICE, TOTAL_SHARES, DURATION, 0, 0, bytes32(0));
        vm.prank(address(dao));
        offering.cancel(1);

        vm.prank(address(dao));
        uint256 id = offering.createTranche(PRICE, TOTAL_SHARES, DURATION, 0, 0, bytes32(0));
        assertEq(id, 2);
    }

    function test_CreateTranche_RevertZeroPrice() public {
        vm.prank(address(dao));
        vm.expectRevert(bytes("zero price"));
        offering.createTranche(0, TOTAL_SHARES, DURATION, 0, 0, bytes32(0));
    }

    function test_CreateTranche_RevertZeroShares() public {
        vm.prank(address(dao));
        vm.expectRevert(bytes("zero shares"));
        offering.createTranche(PRICE, 0, DURATION, 0, 0, bytes32(0));
    }

    function test_CreateTranche_RevertZeroDuration() public {
        vm.prank(address(dao));
        vm.expectRevert(bytes("zero duration"));
        offering.createTranche(PRICE, TOTAL_SHARES, 0, 0, 0, bytes32(0));
    }

    function test_CreateTranche_RevertMinGtTotal() public {
        vm.prank(address(dao));
        vm.expectRevert(bytes("min > total"));
        offering.createTranche(PRICE, TOTAL_SHARES, DURATION, TOTAL_SHARES + 1, 0, bytes32(0));
    }

    function test_CreateTranche_RevertCapLtMin() public {
        vm.prank(address(dao));
        vm.expectRevert(bytes("cap < min"));
        offering.createTranche(PRICE, TOTAL_SHARES, DURATION, 5, 4, bytes32(0));
    }

    function test_CreateTranche_WithMinAndCap() public {
        vm.prank(address(dao));
        uint256 id = offering.createTranche(PRICE, TOTAL_SHARES, DURATION, 2, 10, bytes32(0));
        ShareOffering.Tranche memory t = offering.getTranche(id);
        assertEq(t.minShares, 2);
        assertEq(t.maxSharesPerAddress, 10);
    }

    // ============ commit ============

    function test_Commit_Success() public {
        _createDefaultTranche();

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        offering.commit{value: 5 * PRICE}(1, 5, new bytes32[](0));

        (uint256 shares, uint256 ethValue) = offering.getCommitment(1, alice);
        assertEq(shares, 5);
        assertEq(ethValue, 5 * PRICE);

        ShareOffering.Tranche memory t = offering.getTranche(1);
        assertEq(t.committedShares, 5);
        assertEq(t.totalETHCommitted, 5 * PRICE);
    }

    function test_Commit_MultipleBuyers() public {
        _createDefaultTranche();

        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);

        vm.prank(alice);
        offering.commit{value: 5 * PRICE}(1, 5, new bytes32[](0));

        vm.prank(bob);
        offering.commit{value: 10 * PRICE}(1, 10, new bytes32[](0));

        ShareOffering.Tranche memory t = offering.getTranche(1);
        assertEq(t.committedShares, 15);
        assertEq(t.totalETHCommitted, 15 * PRICE);
    }

    function test_Commit_ExactSupplyFill() public {
        _createDefaultTranche();

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        offering.commit{value: TOTAL_SHARES * PRICE}(1, TOTAL_SHARES, new bytes32[](0));

        ShareOffering.Tranche memory t = offering.getTranche(1);
        assertEq(t.committedShares, TOTAL_SHARES);
    }

    function test_Commit_TopUpSameAddress() public {
        _createDefaultTranche();

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        offering.commit{value: 3 * PRICE}(1, 3, new bytes32[](0));

        vm.prank(alice);
        offering.commit{value: 2 * PRICE}(1, 2, new bytes32[](0));

        (uint256 shares,) = offering.getCommitment(1, alice);
        assertEq(shares, 5);
    }

    function test_Commit_RevertOutsideWindow_Before() public {
        // Create tranche in the future by manipulating time
        _createDefaultTranche();

        // Warp past end
        vm.warp(block.timestamp + DURATION + 1);

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(bytes("outside window"));
        offering.commit{value: PRICE}(1, 1, new bytes32[](0));
    }

    function test_Commit_RevertWrongETH() public {
        _createDefaultTranche();

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(bytes("wrong ETH amount"));
        offering.commit{value: PRICE + 1}(1, 1, new bytes32[](0));
    }

    function test_Commit_RevertExceedsSupply() public {
        _createDefaultTranche();

        vm.deal(alice, 100 ether);
        vm.prank(alice);
        vm.expectRevert(bytes("exceeds supply"));
        offering.commit{value: (TOTAL_SHARES + 1) * PRICE}(1, TOTAL_SHARES + 1, new bytes32[](0));
    }

    function test_Commit_RevertBelowMinimum() public {
        vm.prank(address(dao));
        offering.createTranche(PRICE, TOTAL_SHARES, DURATION, 5, 0, bytes32(0));

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(bytes("below minimum"));
        offering.commit{value: 4 * PRICE}(1, 4, new bytes32[](0));
    }

    function test_Commit_MinimumOnlyOnFirstCommit() public {
        vm.prank(address(dao));
        offering.createTranche(PRICE, TOTAL_SHARES, DURATION, 5, 0, bytes32(0));

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        offering.commit{value: 5 * PRICE}(1, 5, new bytes32[](0));

        // Top-up below minimum is OK
        vm.prank(alice);
        offering.commit{value: 1 * PRICE}(1, 1, new bytes32[](0));

        (uint256 shares,) = offering.getCommitment(1, alice);
        assertEq(shares, 6);
    }

    function test_Commit_RevertExceedsCap() public {
        vm.prank(address(dao));
        offering.createTranche(PRICE, TOTAL_SHARES, DURATION, 0, 5, bytes32(0));

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(bytes("exceeds cap"));
        offering.commit{value: 6 * PRICE}(1, 6, new bytes32[](0));
    }

    function test_Commit_ExceedsCapWithTopUp() public {
        vm.prank(address(dao));
        offering.createTranche(PRICE, TOTAL_SHARES, DURATION, 0, 5, bytes32(0));

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        offering.commit{value: 3 * PRICE}(1, 3, new bytes32[](0));

        vm.prank(alice);
        vm.expectRevert(bytes("exceeds cap"));
        offering.commit{value: 3 * PRICE}(1, 3, new bytes32[](0));
    }

    function test_Commit_RevertZeroShares() public {
        _createDefaultTranche();

        vm.prank(alice);
        vm.expectRevert(bytes("zero shares"));
        offering.commit{value: 0}(1, 0, new bytes32[](0));
    }

    function test_Commit_RevertNotActive() public {
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(bytes("not active"));
        offering.commit{value: PRICE}(1, 1, new bytes32[](0));
    }

    // ============ Whitelist ============

    function test_Commit_WhitelistValid() public {
        (bytes32 root, bytes32[] memory aliceProof,) = _buildMerkleTree();

        vm.prank(address(dao));
        offering.createTranche(PRICE, TOTAL_SHARES, DURATION, 0, 0, root);

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        offering.commit{value: PRICE}(1, 1, aliceProof);

        (uint256 shares,) = offering.getCommitment(1, alice);
        assertEq(shares, 1);
    }

    function test_Commit_WhitelistInvalid() public {
        (bytes32 root,,) = _buildMerkleTree();

        vm.prank(address(dao));
        offering.createTranche(PRICE, TOTAL_SHARES, DURATION, 0, 0, root);

        vm.deal(charlie, 10 ether);
        vm.prank(charlie);
        vm.expectRevert(bytes("not whitelisted"));
        offering.commit{value: PRICE}(1, 1, new bytes32[](0));
    }

    function test_Commit_OpenWhenNoWhitelist() public {
        _createDefaultTranche();

        vm.deal(charlie, 10 ether);
        vm.prank(charlie);
        offering.commit{value: PRICE}(1, 1, new bytes32[](0));

        (uint256 shares,) = offering.getCommitment(1, charlie);
        assertEq(shares, 1);
    }

    // ============ finalize ============

    function test_Finalize_Success() public {
        _createDefaultTranche();

        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);

        vm.prank(alice);
        offering.commit{value: 5 * PRICE}(1, 5, new bytes32[](0));
        vm.prank(bob);
        offering.commit{value: 10 * PRICE}(1, 10, new bytes32[](0));

        vm.warp(block.timestamp + DURATION + 1);

        address[] memory buyers = new address[](2);
        buyers[0] = alice;
        buyers[1] = bob;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 5;
        amounts[1] = 10;

        uint256 safeBefore = address(mockSafe).balance;

        vm.prank(address(dao));
        offering.finalize(1, buyers, amounts);

        // ETH forwarded to Safe
        assertEq(address(mockSafe).balance, safeBefore + 15 * PRICE);

        // Shares minted
        assertEq(dao.shares(alice), 5);
        assertEq(dao.shares(bob), 10);

        // Status finalized
        assertEq(uint8(offering.status(1)), uint8(ShareOffering.TrancheStatus.Finalized));
    }

    function test_Finalize_RevertNotDAO() public {
        _createDefaultTranche();
        vm.warp(block.timestamp + DURATION + 1);

        vm.prank(alice);
        vm.expectRevert(bytes("!dao"));
        offering.finalize(1, new address[](0), new uint256[](0));
    }

    function test_Finalize_RevertWindowNotClosed() public {
        _createDefaultTranche();

        vm.prank(address(dao));
        vm.expectRevert(bytes("window not closed"));
        offering.finalize(1, new address[](0), new uint256[](0));
    }

    function test_Finalize_RevertPastDeadline() public {
        _createDefaultTranche();
        vm.warp(block.timestamp + DURATION + 7 days + 1);

        vm.prank(address(dao));
        vm.expectRevert(bytes("past deadline"));
        offering.finalize(1, new address[](0), new uint256[](0));
    }

    function test_Finalize_RevertArrayMismatch() public {
        _createDefaultTranche();
        vm.warp(block.timestamp + DURATION + 1);

        address[] memory buyers = new address[](1);
        buyers[0] = alice;

        vm.prank(address(dao));
        vm.expectRevert(bytes("!array parity"));
        offering.finalize(1, buyers, new uint256[](0));
    }

    function test_Finalize_RevertCommitmentMismatch() public {
        _createDefaultTranche();

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        offering.commit{value: 5 * PRICE}(1, 5, new bytes32[](0));

        vm.warp(block.timestamp + DURATION + 1);

        address[] memory buyers = new address[](1);
        buyers[0] = alice;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 3; // wrong amount

        vm.prank(address(dao));
        vm.expectRevert(bytes("commitment mismatch"));
        offering.finalize(1, buyers, amounts);
    }

    function test_Finalize_RevertIncompleteBuyers() public {
        _createDefaultTranche();

        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);

        vm.prank(alice);
        offering.commit{value: 5 * PRICE}(1, 5, new bytes32[](0));
        vm.prank(bob);
        offering.commit{value: 5 * PRICE}(1, 5, new bytes32[](0));

        vm.warp(block.timestamp + DURATION + 1);

        // Only include alice, not bob
        address[] memory buyers = new address[](1);
        buyers[0] = alice;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 5;

        vm.prank(address(dao));
        vm.expectRevert(bytes("incomplete buyers"));
        offering.finalize(1, buyers, amounts);
    }

    // ============ cancel ============

    function test_Cancel_Success() public {
        _createDefaultTranche();

        vm.prank(address(dao));
        offering.cancel(1);

        assertEq(uint8(offering.status(1)), uint8(ShareOffering.TrancheStatus.Cancelled));
    }

    function test_Cancel_RevertNotDAO() public {
        _createDefaultTranche();

        vm.prank(alice);
        vm.expectRevert(bytes("!dao"));
        offering.cancel(1);
    }

    function test_Cancel_RevertNotActive() public {
        vm.prank(address(dao));
        vm.expectRevert(bytes("not active"));
        offering.cancel(1);
    }

    function test_Cancel_DuringWindow() public {
        _createDefaultTranche();

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        offering.commit{value: 5 * PRICE}(1, 5, new bytes32[](0));

        vm.prank(address(dao));
        offering.cancel(1);

        assertEq(uint8(offering.status(1)), uint8(ShareOffering.TrancheStatus.Cancelled));
    }

    function test_Cancel_AfterWindow() public {
        _createDefaultTranche();
        vm.warp(block.timestamp + DURATION + 1);

        vm.prank(address(dao));
        offering.cancel(1);

        assertEq(uint8(offering.status(1)), uint8(ShareOffering.TrancheStatus.Cancelled));
    }

    // ============ refund ============

    function test_Refund_AfterCancel() public {
        _createDefaultTranche();

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        offering.commit{value: 5 * PRICE}(1, 5, new bytes32[](0));

        uint256 aliceBefore = alice.balance;

        vm.prank(address(dao));
        offering.cancel(1);

        vm.prank(alice);
        offering.refund(1);

        assertEq(alice.balance, aliceBefore + 5 * PRICE);
        (uint256 shares,) = offering.getCommitment(1, alice);
        assertEq(shares, 0);
    }

    function test_Refund_AfterExpiry() public {
        _createDefaultTranche();

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        offering.commit{value: 5 * PRICE}(1, 5, new bytes32[](0));

        uint256 aliceBefore = alice.balance;

        // Warp past finalize deadline
        vm.warp(block.timestamp + DURATION + 7 days + 1);

        vm.prank(alice);
        offering.refund(1);

        assertEq(alice.balance, aliceBefore + 5 * PRICE);
    }

    function test_Refund_RevertIfFinalized() public {
        _createDefaultTranche();

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        offering.commit{value: 5 * PRICE}(1, 5, new bytes32[](0));

        vm.warp(block.timestamp + DURATION + 1);

        address[] memory buyers = new address[](1);
        buyers[0] = alice;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 5;

        vm.prank(address(dao));
        offering.finalize(1, buyers, amounts);

        vm.prank(alice);
        vm.expectRevert(bytes("not refundable"));
        offering.refund(1);
    }

    function test_Refund_RevertIfActive() public {
        _createDefaultTranche();

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        offering.commit{value: 5 * PRICE}(1, 5, new bytes32[](0));

        vm.prank(alice);
        vm.expectRevert(bytes("not refundable"));
        offering.refund(1);
    }

    function test_Refund_RevertNoCommitment() public {
        _createDefaultTranche();

        vm.prank(address(dao));
        offering.cancel(1);

        vm.prank(alice);
        vm.expectRevert(bytes("no commitment"));
        offering.refund(1);
    }

    function test_Refund_NoDoubleRefund() public {
        _createDefaultTranche();

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        offering.commit{value: 5 * PRICE}(1, 5, new bytes32[](0));

        vm.prank(address(dao));
        offering.cancel(1);

        vm.prank(alice);
        offering.refund(1);

        vm.prank(alice);
        vm.expectRevert(bytes("no commitment"));
        offering.refund(1);
    }

    function test_Refund_MultipleBuyersIndependent() public {
        _createDefaultTranche();

        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);

        vm.prank(alice);
        offering.commit{value: 5 * PRICE}(1, 5, new bytes32[](0));
        vm.prank(bob);
        offering.commit{value: 3 * PRICE}(1, 3, new bytes32[](0));

        vm.prank(address(dao));
        offering.cancel(1);

        uint256 aliceBefore = alice.balance;
        uint256 bobBefore = bob.balance;

        vm.prank(alice);
        offering.refund(1);
        assertEq(alice.balance, aliceBefore + 5 * PRICE);

        // Bob hasn't refunded yet
        (uint256 bobShares,) = offering.getCommitment(1, bob);
        assertEq(bobShares, 3);

        vm.prank(bob);
        offering.refund(1);
        assertEq(bob.balance, bobBefore + 3 * PRICE);
    }

    // ============ status view ============

    function test_Status_Inactive() public view {
        assertEq(uint8(offering.status(999)), uint8(ShareOffering.TrancheStatus.Inactive));
    }

    function test_Status_Active() public {
        _createDefaultTranche();
        assertEq(uint8(offering.status(1)), uint8(ShareOffering.TrancheStatus.Active));
    }

    function test_Status_Finalized() public {
        _createAndFinalizeEmptyTranche();
        assertEq(uint8(offering.status(1)), uint8(ShareOffering.TrancheStatus.Finalized));
    }

    function test_Status_Cancelled() public {
        _createDefaultTranche();
        vm.prank(address(dao));
        offering.cancel(1);
        assertEq(uint8(offering.status(1)), uint8(ShareOffering.TrancheStatus.Cancelled));
    }

    function test_Status_ActivePastDeadline() public {
        _createDefaultTranche();
        vm.warp(block.timestamp + DURATION + 7 days + 1);
        // Still Active in storage, but refundable
        assertEq(uint8(offering.status(1)), uint8(ShareOffering.TrancheStatus.Active));
    }

    // ============ Integration ============

    function test_Integration_FullLifecycleHappyPath() public {
        // Create tranche
        vm.prank(address(dao));
        offering.createTranche(0.2 ether, 10, 3 days, 2, 5, bytes32(0));

        // Buyers commit
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);

        vm.prank(alice);
        offering.commit{value: 5 * 0.2 ether}(1, 5, new bytes32[](0));

        vm.prank(bob);
        offering.commit{value: 3 * 0.2 ether}(1, 3, new bytes32[](0));

        // Window closes
        vm.warp(block.timestamp + 3 days + 1);

        // Finalize
        address[] memory buyers = new address[](2);
        buyers[0] = alice;
        buyers[1] = bob;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 5;
        amounts[1] = 3;

        vm.prank(address(dao));
        offering.finalize(1, buyers, amounts);

        // Verify
        assertEq(dao.shares(alice), 5);
        assertEq(dao.shares(bob), 3);
        assertEq(uint8(offering.status(1)), uint8(ShareOffering.TrancheStatus.Finalized));
    }

    function test_Integration_CancelAndRefund() public {
        vm.prank(address(dao));
        offering.createTranche(PRICE, TOTAL_SHARES, DURATION, 0, 0, bytes32(0));

        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);

        vm.prank(alice);
        offering.commit{value: 5 * PRICE}(1, 5, new bytes32[](0));
        vm.prank(bob);
        offering.commit{value: 3 * PRICE}(1, 3, new bytes32[](0));

        uint256 aliceBefore = alice.balance;
        uint256 bobBefore = bob.balance;

        vm.prank(address(dao));
        offering.cancel(1);

        vm.prank(alice);
        offering.refund(1);
        vm.prank(bob);
        offering.refund(1);

        assertEq(alice.balance, aliceBefore + 5 * PRICE);
        assertEq(bob.balance, bobBefore + 3 * PRICE);
        assertEq(address(offering).balance, 0);
    }

    function test_Integration_ExpiryAndRefund() public {
        vm.prank(address(dao));
        offering.createTranche(PRICE, TOTAL_SHARES, DURATION, 0, 0, bytes32(0));

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        offering.commit{value: 5 * PRICE}(1, 5, new bytes32[](0));

        uint256 aliceBefore = alice.balance;

        // Warp past finalize deadline without anyone finalizing
        vm.warp(block.timestamp + DURATION + 7 days + 1);

        vm.prank(alice);
        offering.refund(1);

        assertEq(alice.balance, aliceBefore + 5 * PRICE);
        assertEq(address(offering).balance, 0);
    }

    function test_Integration_SequentialTranchesRisingPrice() public {
        // Tranche 1
        vm.prank(address(dao));
        offering.createTranche(0.1 ether, 10, DURATION, 0, 0, bytes32(0));

        vm.deal(alice, 100 ether);
        vm.prank(alice);
        offering.commit{value: 10 * 0.1 ether}(1, 10, new bytes32[](0));

        vm.warp(block.timestamp + DURATION + 1);

        address[] memory buyers = new address[](1);
        buyers[0] = alice;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10;

        vm.prank(address(dao));
        offering.finalize(1, buyers, amounts);

        assertEq(dao.shares(alice), 10);

        // Tranche 2 at higher price
        vm.prank(address(dao));
        offering.createTranche(0.2 ether, 10, DURATION, 0, 0, bytes32(0));

        vm.prank(alice);
        offering.commit{value: 5 * 0.2 ether}(2, 5, new bytes32[](0));

        vm.warp(block.timestamp + DURATION + 1);

        buyers[0] = alice;
        amounts[0] = 5;

        vm.prank(address(dao));
        offering.finalize(2, buyers, amounts);

        assertEq(dao.shares(alice), 15);
    }

    // ============ Helpers ============

    function _createDefaultTranche() internal {
        vm.prank(address(dao));
        offering.createTranche(PRICE, TOTAL_SHARES, DURATION, 0, 0, bytes32(0));
    }

    function _createAndFinalizeEmptyTranche() internal {
        vm.prank(address(dao));
        offering.createTranche(PRICE, TOTAL_SHARES, DURATION, 0, 0, bytes32(0));
        vm.warp(block.timestamp + DURATION + 1);
        vm.prank(address(dao));
        offering.finalize(1, new address[](0), new uint256[](0));
    }

    function _buildMerkleTree() internal view returns (bytes32 root, bytes32[] memory aliceProof, bytes32[] memory bobProof) {
        bytes32 leafAlice = keccak256(abi.encodePacked(alice));
        bytes32 leafBob = keccak256(abi.encodePacked(bob));

        // Sort leaves for consistent tree
        bytes32 left;
        bytes32 right;
        if (uint256(leafAlice) < uint256(leafBob)) {
            left = leafAlice;
            right = leafBob;
        } else {
            left = leafBob;
            right = leafAlice;
        }

        root = keccak256(abi.encodePacked(left, right));

        aliceProof = new bytes32[](1);
        aliceProof[0] = leafBob;

        bobProof = new bytes32[](1);
        bobProof[0] = leafAlice;
    }
}
