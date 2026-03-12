// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {GrandCentral} from "../../src/dao/GrandCentral.sol";
import {OTCShareEscrow} from "../../src/dao/OTCShareEscrow.sol";
import {MockSafe} from "../mocks/MockSafe.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract OTCShareEscrowTest is Test {
    GrandCentral public dao;
    MockSafe public mockSafe;
    OTCShareEscrow public escrow;
    MockERC20 public usdc;

    address public founder = makeAddr("founder");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint256 constant INITIAL_SHARES = 1000;

    function setUp() public {
        mockSafe = new MockSafe();
        dao = new GrandCentral(address(mockSafe), founder, INITIAL_SHARES, 5 days, 2 days, 0, 1, 66);
        escrow = new OTCShareEscrow(address(dao));
        usdc = new MockERC20("USD Coin", "USDC");

        // Register escrow as manager conductor
        address[] memory addrs = new address[](1);
        addrs[0] = address(escrow);
        uint256[] memory perms = new uint256[](1);
        perms[0] = 2; // manager
        vm.prank(address(dao));
        dao.setConductors(addrs, perms);
    }

    // ============ Constructor ============

    function test_Constructor_SetsImmutables() public view {
        assertEq(escrow.dao(), address(dao));
        assertEq(escrow.safe(), address(mockSafe));
    }

    function test_Constructor_RevertsOnZeroAddress() public {
        vm.expectRevert(OTCShareEscrow.InvalidAddress.selector);
        new OTCShareEscrow(address(0));
    }

    // ============ createOffer (ETH) ============

    function test_CreateOffer_ETH() public {
        uint40 expiration = uint40(block.timestamp + 14 days);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        escrow.createOffer{value: 1 ether}(address(0), 0, 50, expiration);

        (uint256 amount, uint256 sharesReq, uint40 exp) = escrow.offers(alice, address(0));
        assertEq(amount, 1 ether);
        assertEq(sharesReq, 50);
        assertEq(exp, expiration);
        assertEq(address(escrow).balance, 1 ether);
    }

    function test_CreateOffer_ETH_EmitsEvent() public {
        uint40 expiration = uint40(block.timestamp + 14 days);
        vm.expectEmit(true, true, false, true);
        emit OTCShareEscrow.OfferCreated(alice, address(0), 1 ether, 50, expiration);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        escrow.createOffer{value: 1 ether}(address(0), 0, 50, expiration);
    }

    function test_CreateOffer_RevertZeroShares() public {
        uint40 expiration = uint40(block.timestamp + 14 days);
        vm.deal(alice, 1 ether);
        vm.expectRevert(OTCShareEscrow.InvalidAmount.selector);
        vm.prank(alice);
        escrow.createOffer{value: 1 ether}(address(0), 0, 0, expiration);
    }

    function test_CreateOffer_RevertZeroValue() public {
        uint40 expiration = uint40(block.timestamp + 14 days);
        vm.prank(alice);
        vm.expectRevert(OTCShareEscrow.InvalidAmount.selector);
        escrow.createOffer(address(0), 0, 50, expiration);
    }

    function test_CreateOffer_RevertExpirationTooSoon() public {
        uint40 expiration = uint40(block.timestamp + 1 days);
        vm.deal(alice, 1 ether);
        vm.expectRevert(OTCShareEscrow.InvalidExpiration.selector);
        vm.prank(alice);
        escrow.createOffer{value: 1 ether}(address(0), 0, 50, expiration);
    }

    function test_CreateOffer_RevertDuplicate() public {
        uint40 expiration = uint40(block.timestamp + 14 days);
        vm.deal(alice, 2 ether);
        vm.startPrank(alice);
        escrow.createOffer{value: 1 ether}(address(0), 0, 50, expiration);
        vm.expectRevert(OTCShareEscrow.OfferExists.selector);
        escrow.createOffer{value: 1 ether}(address(0), 0, 50, expiration);
        vm.stopPrank();
    }

    // ============ createOffer (ERC20) ============

    function test_CreateOffer_ERC20() public {
        uint40 expiration = uint40(block.timestamp + 14 days);
        usdc.mint(alice, 50_000e18);
        vm.startPrank(alice);
        usdc.approve(address(escrow), 50_000e18);
        escrow.createOffer(address(usdc), 50_000e18, 100, expiration);
        vm.stopPrank();

        (uint256 amount, uint256 sharesReq, uint40 exp) = escrow.offers(alice, address(usdc));
        assertEq(amount, 50_000e18);
        assertEq(sharesReq, 100);
        assertEq(exp, expiration);
        assertEq(usdc.balanceOf(address(escrow)), 50_000e18);
    }

    function test_CreateOffer_ERC20_RevertZeroAmount() public {
        uint40 expiration = uint40(block.timestamp + 14 days);
        vm.prank(alice);
        vm.expectRevert(OTCShareEscrow.InvalidAmount.selector);
        escrow.createOffer(address(usdc), 0, 100, expiration);
    }

    function test_CreateOffer_ERC20_RevertETHSent() public {
        uint40 expiration = uint40(block.timestamp + 14 days);
        usdc.mint(alice, 50_000e18);
        vm.deal(alice, 1 ether);
        vm.startPrank(alice);
        usdc.approve(address(escrow), 50_000e18);
        vm.expectRevert(OTCShareEscrow.InvalidAmount.selector);
        escrow.createOffer{value: 1 ether}(address(usdc), 50_000e18, 100, expiration);
        vm.stopPrank();
    }

    // ============ cancelOffer ============

    function test_CancelOffer_ETH() public {
        uint40 expiration = uint40(block.timestamp + 14 days);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        escrow.createOffer{value: 1 ether}(address(0), 0, 50, expiration);

        uint256 balBefore = alice.balance;
        vm.prank(alice);
        escrow.cancelOffer(address(0));

        (uint256 amount,,) = escrow.offers(alice, address(0));
        assertEq(amount, 0);
        assertEq(alice.balance, balBefore + 1 ether);
    }

    function test_CancelOffer_ERC20() public {
        uint40 expiration = uint40(block.timestamp + 14 days);
        usdc.mint(alice, 50_000e18);
        vm.startPrank(alice);
        usdc.approve(address(escrow), 50_000e18);
        escrow.createOffer(address(usdc), 50_000e18, 100, expiration);
        escrow.cancelOffer(address(usdc));
        vm.stopPrank();

        (uint256 amount,,) = escrow.offers(alice, address(usdc));
        assertEq(amount, 0);
        assertEq(usdc.balanceOf(alice), 50_000e18);
    }

    function test_CancelOffer_AfterExpiration() public {
        uint40 expiration = uint40(block.timestamp + 14 days);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        escrow.createOffer{value: 1 ether}(address(0), 0, 50, expiration);

        vm.warp(expiration + 1);
        vm.prank(alice);
        escrow.cancelOffer(address(0));

        assertEq(alice.balance, 1 ether);
    }

    function test_CancelOffer_EmitsEvent() public {
        uint40 expiration = uint40(block.timestamp + 14 days);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        escrow.createOffer{value: 1 ether}(address(0), 0, 50, expiration);

        vm.expectEmit(true, true, false, true);
        emit OTCShareEscrow.OfferCancelled(alice, address(0), 1 ether);
        vm.prank(alice);
        escrow.cancelOffer(address(0));
    }

    function test_CancelOffer_RevertNoOffer() public {
        vm.expectRevert(OTCShareEscrow.NoOffer.selector);
        vm.prank(alice);
        escrow.cancelOffer(address(0));
    }

    // ============ claimOffer ============

    function test_ClaimOffer_ETH() public {
        uint40 expiration = uint40(block.timestamp + 14 days);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        escrow.createOffer{value: 1 ether}(address(0), 0, 50, expiration);

        uint256 safeBefore = address(mockSafe).balance;
        uint256 aliceSharesBefore = dao.shares(alice);

        // DAO Safe claims
        vm.prank(address(mockSafe));
        escrow.claimOffer(alice, address(0));

        assertEq(address(mockSafe).balance, safeBefore + 1 ether);
        assertEq(dao.shares(alice), aliceSharesBefore + 50);
        (uint256 amount,,) = escrow.offers(alice, address(0));
        assertEq(amount, 0);
    }

    function test_ClaimOffer_ERC20() public {
        uint40 expiration = uint40(block.timestamp + 14 days);
        usdc.mint(alice, 50_000e18);
        vm.startPrank(alice);
        usdc.approve(address(escrow), 50_000e18);
        escrow.createOffer(address(usdc), 50_000e18, 100, expiration);
        vm.stopPrank();

        vm.prank(address(mockSafe));
        escrow.claimOffer(alice, address(usdc));

        assertEq(usdc.balanceOf(address(mockSafe)), 50_000e18);
        assertEq(dao.shares(alice), 100);
    }

    function test_ClaimOffer_EmitsEvent() public {
        uint40 expiration = uint40(block.timestamp + 14 days);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        escrow.createOffer{value: 1 ether}(address(0), 0, 50, expiration);

        vm.expectEmit(true, true, false, true);
        emit OTCShareEscrow.OfferClaimed(alice, address(0), 1 ether, 50);
        vm.prank(address(mockSafe));
        escrow.claimOffer(alice, address(0));
    }

    function test_ClaimOffer_RevertNotSafe() public {
        uint40 expiration = uint40(block.timestamp + 14 days);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        escrow.createOffer{value: 1 ether}(address(0), 0, 50, expiration);

        vm.expectRevert(OTCShareEscrow.Unauthorized.selector);
        vm.prank(alice);
        escrow.claimOffer(alice, address(0));
    }

    function test_ClaimOffer_RevertNoOffer() public {
        vm.expectRevert(OTCShareEscrow.NoOffer.selector);
        vm.prank(address(mockSafe));
        escrow.claimOffer(alice, address(0));
    }

    function test_ClaimOffer_RevertExpired() public {
        uint40 expiration = uint40(block.timestamp + 14 days);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        escrow.createOffer{value: 1 ether}(address(0), 0, 50, expiration);

        vm.warp(expiration + 1);
        vm.expectRevert(OTCShareEscrow.OfferExpired.selector);
        vm.prank(address(mockSafe));
        escrow.claimOffer(alice, address(0));
    }

    // ============ Views ============

    function test_GetActiveOffers_Empty() public view {
        OTCShareEscrow.ActiveOfferView[] memory active = escrow.getActiveOffers();
        assertEq(active.length, 0);
    }

    function test_GetActiveOffers_FiltersExpiredAndCancelled() public {
        uint40 exp1 = uint40(block.timestamp + 14 days);
        uint40 exp2 = uint40(block.timestamp + 8 days);

        // Alice offers ETH
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        escrow.createOffer{value: 1 ether}(address(0), 0, 50, exp1);

        // Bob offers USDC
        usdc.mint(bob, 10_000e18);
        vm.startPrank(bob);
        usdc.approve(address(escrow), 10_000e18);
        escrow.createOffer(address(usdc), 10_000e18, 20, exp2);
        vm.stopPrank();

        // Both active
        OTCShareEscrow.ActiveOfferView[] memory active = escrow.getActiveOffers();
        assertEq(active.length, 2);

        // Cancel alice's offer
        vm.prank(alice);
        escrow.cancelOffer(address(0));

        active = escrow.getActiveOffers();
        assertEq(active.length, 1);
        assertEq(active[0].proposer, bob);

        // Expire bob's offer
        vm.warp(exp2 + 1);
        active = escrow.getActiveOffers();
        assertEq(active.length, 0);
    }

    function test_GetOffer() public {
        uint40 expiration = uint40(block.timestamp + 14 days);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        escrow.createOffer{value: 1 ether}(address(0), 0, 50, expiration);

        OTCShareEscrow.Offer memory offer = escrow.getOffer(alice, address(0));
        assertEq(offer.amount, 1 ether);
        assertEq(offer.sharesRequested, 50);
        assertEq(offer.expiration, expiration);
    }

    function test_OfferRefCount() public {
        uint40 expiration = uint40(block.timestamp + 14 days);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        escrow.createOffer{value: 1 ether}(address(0), 0, 50, expiration);

        assertEq(escrow.offerRefCount(), 1);
    }
}
