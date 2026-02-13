// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PromotionBadges} from "../../src/promotion/PromotionBadges.sol";

contract PromotionBadgesTest is Test {
    PromotionBadges public badges;

    address public owner = address(0x1);
    address public buyer = address(0x2);
    address public factory = address(0x3);
    address public nonOwner = address(0x5);
    address public treasury = address(0xBEEF);

    address public instance1 = address(0x100);
    address public instance2 = address(0x200);
    address public instance3 = address(0x300);

    function setUp() public {
        vm.startPrank(owner);
        badges = new PromotionBadges(treasury);
        vm.stopPrank();
    }

    // ========================
    // Purchase Badge Tests
    // ========================

    function test_purchaseBadge_highlight() public {
        vm.deal(buyer, 1 ether);
        vm.startPrank(buyer);

        uint256 duration = 7 days;
        uint256 expectedCost = (0.001 ether * duration) / 1 days; // 0.007 ether

        badges.purchaseBadge{value: expectedCost}(
            instance1,
            PromotionBadges.BadgeType.HIGHLIGHT,
            duration
        );

        (PromotionBadges.BadgeType badgeType, uint256 expiresAt) = badges.getActiveBadge(instance1);
        assertEq(uint256(badgeType), uint256(PromotionBadges.BadgeType.HIGHLIGHT));
        assertEq(expiresAt, block.timestamp + duration);

        vm.stopPrank();
    }

    function test_purchaseBadge_trending() public {
        vm.deal(buyer, 1 ether);
        vm.startPrank(buyer);

        uint256 duration = 14 days;
        uint256 expectedCost = (0.002 ether * duration) / 1 days; // 0.028 ether

        badges.purchaseBadge{value: expectedCost}(
            instance1,
            PromotionBadges.BadgeType.TRENDING,
            duration
        );

        (PromotionBadges.BadgeType badgeType,) = badges.getActiveBadge(instance1);
        assertEq(uint256(badgeType), uint256(PromotionBadges.BadgeType.TRENDING));

        vm.stopPrank();
    }

    function test_purchaseBadge_verified() public {
        vm.deal(buyer, 1 ether);
        vm.startPrank(buyer);

        uint256 duration = 30 days;
        uint256 expectedCost = (0.005 ether * duration) / 1 days; // 0.15 ether

        badges.purchaseBadge{value: expectedCost}(
            instance1,
            PromotionBadges.BadgeType.VERIFIED,
            duration
        );

        (PromotionBadges.BadgeType badgeType,) = badges.getActiveBadge(instance1);
        assertEq(uint256(badgeType), uint256(PromotionBadges.BadgeType.VERIFIED));

        vm.stopPrank();
    }

    function test_purchaseBadge_spotlight() public {
        vm.deal(buyer, 1 ether);
        vm.startPrank(buyer);

        uint256 duration = 7 days;
        uint256 expectedCost = (0.01 ether * duration) / 1 days; // 0.07 ether

        badges.purchaseBadge{value: expectedCost}(
            instance1,
            PromotionBadges.BadgeType.SPOTLIGHT,
            duration
        );

        (PromotionBadges.BadgeType badgeType,) = badges.getActiveBadge(instance1);
        assertEq(uint256(badgeType), uint256(PromotionBadges.BadgeType.SPOTLIGHT));

        vm.stopPrank();
    }

    function test_purchaseBadge_correctCostStored() public {
        vm.deal(buyer, 1 ether);
        vm.startPrank(buyer);

        uint256 duration = 10 days;
        uint256 expectedCost = (0.001 ether * duration) / 1 days; // 0.01 ether

        badges.purchaseBadge{value: expectedCost}(
            instance1,
            PromotionBadges.BadgeType.HIGHLIGHT,
            duration
        );

        (, , uint256 paidAmount) = badges.instanceBadges(instance1);
        assertEq(paidAmount, expectedCost);

        vm.stopPrank();
    }

    function test_purchaseBadge_excessRefund() public {
        vm.deal(buyer, 1 ether);
        vm.startPrank(buyer);

        uint256 duration = 7 days;
        uint256 expectedCost = (0.001 ether * duration) / 1 days;
        uint256 sent = 0.5 ether;
        uint256 balanceBefore = buyer.balance;

        badges.purchaseBadge{value: sent}(
            instance1,
            PromotionBadges.BadgeType.HIGHLIGHT,
            duration
        );

        assertEq(buyer.balance, balanceBefore - expectedCost, "Excess should be refunded");

        vm.stopPrank();
    }

    function test_purchaseBadge_insufficientPayment() public {
        vm.deal(buyer, 1 ether);
        vm.startPrank(buyer);

        vm.expectRevert("Insufficient payment");
        badges.purchaseBadge{value: 0.001 ether}(
            instance1,
            PromotionBadges.BadgeType.SPOTLIGHT, // 0.01 ETH/day
            7 days // costs 0.07 ETH
        );

        vm.stopPrank();
    }

    function test_purchaseBadge_invalidBadgeNone() public {
        vm.deal(buyer, 1 ether);
        vm.startPrank(buyer);

        vm.expectRevert("Invalid badge");
        badges.purchaseBadge{value: 0.01 ether}(
            instance1,
            PromotionBadges.BadgeType.NONE,
            7 days
        );

        vm.stopPrank();
    }

    function test_purchaseBadge_durationTooShort() public {
        vm.deal(buyer, 1 ether);
        vm.startPrank(buyer);

        vm.expectRevert("Invalid duration");
        badges.purchaseBadge{value: 0.01 ether}(
            instance1,
            PromotionBadges.BadgeType.HIGHLIGHT,
            12 hours // less than 1 day min
        );

        vm.stopPrank();
    }

    function test_purchaseBadge_durationTooLong() public {
        vm.deal(buyer, 100 ether);
        vm.startPrank(buyer);

        vm.expectRevert("Invalid duration");
        badges.purchaseBadge{value: 100 ether}(
            instance1,
            PromotionBadges.BadgeType.HIGHLIGHT,
            91 days // exceeds 90 day max
        );

        vm.stopPrank();
    }

    // ========================
    // Query Tests
    // ========================

    function test_getActiveBadge_active() public {
        vm.deal(buyer, 1 ether);
        vm.startPrank(buyer);

        uint256 duration = 7 days;
        uint256 cost = (0.001 ether * duration) / 1 days;
        badges.purchaseBadge{value: cost}(instance1, PromotionBadges.BadgeType.HIGHLIGHT, duration);

        (PromotionBadges.BadgeType badgeType, uint256 expiresAt) = badges.getActiveBadge(instance1);
        assertEq(uint256(badgeType), uint256(PromotionBadges.BadgeType.HIGHLIGHT));
        assertGt(expiresAt, block.timestamp);

        vm.stopPrank();
    }

    function test_getActiveBadge_expired() public {
        vm.deal(buyer, 1 ether);
        vm.startPrank(buyer);

        uint256 duration = 1 days;
        uint256 cost = (0.001 ether * duration) / 1 days;
        badges.purchaseBadge{value: cost}(instance1, PromotionBadges.BadgeType.HIGHLIGHT, duration);

        vm.stopPrank();

        // Warp past expiry
        vm.warp(block.timestamp + 2 days);

        (PromotionBadges.BadgeType badgeType, uint256 expiresAt) = badges.getActiveBadge(instance1);
        assertEq(uint256(badgeType), uint256(PromotionBadges.BadgeType.NONE));
        assertEq(expiresAt, 0);
    }

    function test_getActiveBadge_noBadge() public {
        (PromotionBadges.BadgeType badgeType, uint256 expiresAt) = badges.getActiveBadge(instance1);
        assertEq(uint256(badgeType), uint256(PromotionBadges.BadgeType.NONE));
        assertEq(expiresAt, 0);
    }

    // ========================
    // Extension Tests
    // ========================

    function test_purchaseBadge_extendSameType() public {
        vm.deal(buyer, 1 ether);
        vm.startPrank(buyer);

        uint256 duration1 = 7 days;
        uint256 cost1 = (0.001 ether * duration1) / 1 days;
        badges.purchaseBadge{value: cost1}(instance1, PromotionBadges.BadgeType.HIGHLIGHT, duration1);

        (, uint256 expiresAt1) = badges.getActiveBadge(instance1);

        // Extend with another 7 days
        uint256 duration2 = 7 days;
        uint256 cost2 = (0.001 ether * duration2) / 1 days;
        badges.purchaseBadge{value: cost2}(instance1, PromotionBadges.BadgeType.HIGHLIGHT, duration2);

        (, uint256 expiresAt2) = badges.getActiveBadge(instance1);
        assertEq(expiresAt2, expiresAt1 + duration2, "Expiry should be extended");

        // Verify accumulated paid amount
        (, , uint256 paidAmount) = badges.instanceBadges(instance1);
        assertEq(paidAmount, cost1 + cost2);

        vm.stopPrank();
    }

    function test_purchaseBadge_differentTypeWhileActive() public {
        vm.deal(buyer, 1 ether);
        vm.startPrank(buyer);

        uint256 duration = 7 days;
        uint256 cost = (0.001 ether * duration) / 1 days;
        badges.purchaseBadge{value: cost}(instance1, PromotionBadges.BadgeType.HIGHLIGHT, duration);

        vm.expectRevert("Different badge active");
        badges.purchaseBadge{value: 0.1 ether}(
            instance1,
            PromotionBadges.BadgeType.TRENDING,
            7 days
        );

        vm.stopPrank();
    }

    function test_purchaseBadge_differentTypeAfterExpiry() public {
        vm.deal(buyer, 1 ether);
        vm.startPrank(buyer);

        uint256 duration = 1 days;
        uint256 cost1 = (0.001 ether * duration) / 1 days;
        badges.purchaseBadge{value: cost1}(instance1, PromotionBadges.BadgeType.HIGHLIGHT, duration);

        // Warp past expiry
        vm.warp(block.timestamp + 2 days);

        // Should succeed with different type
        uint256 cost2 = (0.002 ether * 7 days) / 1 days;
        badges.purchaseBadge{value: cost2}(
            instance1,
            PromotionBadges.BadgeType.TRENDING,
            7 days
        );

        (PromotionBadges.BadgeType badgeType,) = badges.getActiveBadge(instance1);
        assertEq(uint256(badgeType), uint256(PromotionBadges.BadgeType.TRENDING));

        vm.stopPrank();
    }

    // ========================
    // Batch Query Tests
    // ========================

    function test_getActiveBadges_batch() public {
        vm.deal(buyer, 10 ether);
        vm.startPrank(buyer);

        // Badge instance1 (active)
        uint256 cost1 = (0.001 ether * 7 days) / 1 days;
        badges.purchaseBadge{value: cost1}(instance1, PromotionBadges.BadgeType.HIGHLIGHT, 7 days);

        // Badge instance2 (will be expired)
        uint256 cost2 = (0.002 ether * 1 days) / 1 days;
        badges.purchaseBadge{value: cost2}(instance2, PromotionBadges.BadgeType.TRENDING, 1 days);

        // Badge instance3 (active)
        uint256 cost3 = (0.005 ether * 30 days) / 1 days;
        badges.purchaseBadge{value: cost3}(instance3, PromotionBadges.BadgeType.VERIFIED, 30 days);

        vm.stopPrank();

        // Warp so instance2 expires but others still active
        vm.warp(block.timestamp + 2 days);

        address[] memory instances = new address[](3);
        instances[0] = instance1;
        instances[1] = instance2;
        instances[2] = instance3;

        (PromotionBadges.BadgeType[] memory types, uint256[] memory expirations) = badges.getActiveBadges(instances);

        // instance1: HIGHLIGHT, still active
        assertEq(uint256(types[0]), uint256(PromotionBadges.BadgeType.HIGHLIGHT));
        assertGt(expirations[0], 0);

        // instance2: expired, should return NONE
        assertEq(uint256(types[1]), uint256(PromotionBadges.BadgeType.NONE));
        assertEq(expirations[1], 0);

        // instance3: VERIFIED, still active
        assertEq(uint256(types[2]), uint256(PromotionBadges.BadgeType.VERIFIED));
        assertGt(expirations[2], 0);
    }

    // ========================
    // Withdrawal Tests
    // ========================

    function test_withdrawProtocolFees() public {
        vm.deal(buyer, 1 ether);
        vm.startPrank(buyer);

        uint256 cost = (0.001 ether * 7 days) / 1 days;
        badges.purchaseBadge{value: cost}(instance1, PromotionBadges.BadgeType.HIGHLIGHT, 7 days);

        vm.stopPrank();

        uint256 treasuryBefore = treasury.balance;

        vm.startPrank(owner);
        badges.withdrawProtocolFees();
        vm.stopPrank();

        assertEq(address(badges).balance, 0);
        assertEq(treasury.balance, treasuryBefore + cost);
    }

    function test_withdrawProtocolFees_noTreasury() public {
        // Deploy badges with zero treasury
        vm.startPrank(owner);
        PromotionBadges badgesNoTreasury = new PromotionBadges(address(0));

        vm.expectRevert("Treasury not set");
        badgesNoTreasury.withdrawProtocolFees();
        vm.stopPrank();
    }

    function test_withdrawProtocolFees_noBalance() public {
        vm.startPrank(owner);

        vm.expectRevert("No fees");
        badges.withdrawProtocolFees();

        vm.stopPrank();
    }

    function test_withdrawProtocolFees_nonOwner() public {
        vm.startPrank(nonOwner);

        vm.expectRevert();
        badges.withdrawProtocolFees();

        vm.stopPrank();
    }

    // ========================
    // Price Update Tests
    // ========================

    function test_setBadgePrice_owner() public {
        vm.startPrank(owner);

        badges.setBadgePrice(PromotionBadges.BadgeType.HIGHLIGHT, 0.005 ether);
        assertEq(badges.badgePricePerDay(PromotionBadges.BadgeType.HIGHLIGHT), 0.005 ether);

        vm.stopPrank();
    }

    function test_setBadgePrice_nonOwner() public {
        vm.startPrank(nonOwner);

        vm.expectRevert();
        badges.setBadgePrice(PromotionBadges.BadgeType.HIGHLIGHT, 0.005 ether);

        vm.stopPrank();
    }

    function test_setBadgePrice_invalidBadgeNone() public {
        vm.startPrank(owner);

        vm.expectRevert("Invalid badge");
        badges.setBadgePrice(PromotionBadges.BadgeType.NONE, 0.005 ether);

        vm.stopPrank();
    }

    // ========================
    // Privileged Assignment Tests
    // ========================

    function test_assignBadgeFor_authorized() public {
        vm.startPrank(owner);
        badges.setAuthorizedFactory(factory, true);
        vm.stopPrank();

        vm.startPrank(factory);
        badges.assignBadgeFor(instance1, PromotionBadges.BadgeType.HIGHLIGHT, 14 days);
        vm.stopPrank();

        (PromotionBadges.BadgeType badgeType, uint256 expiresAt) = badges.getActiveBadge(instance1);
        assertEq(uint256(badgeType), uint256(PromotionBadges.BadgeType.HIGHLIGHT));
        assertEq(expiresAt, block.timestamp + 14 days);

        // Verify paidAmount is 0 (privileged assignment)
        (, , uint256 paidAmount) = badges.instanceBadges(instance1);
        assertEq(paidAmount, 0);
    }

    function test_assignBadgeFor_unauthorized() public {
        vm.startPrank(factory);

        vm.expectRevert("Not authorized");
        badges.assignBadgeFor(instance1, PromotionBadges.BadgeType.HIGHLIGHT, 14 days);

        vm.stopPrank();
    }

    function test_assignBadgeFor_invalidBadge() public {
        vm.startPrank(owner);
        badges.setAuthorizedFactory(factory, true);
        vm.stopPrank();

        vm.startPrank(factory);

        vm.expectRevert("Invalid badge");
        badges.assignBadgeFor(instance1, PromotionBadges.BadgeType.NONE, 14 days);

        vm.stopPrank();
    }

    // ========================
    // Duration Bounds Tests
    // ========================

    function test_setDurationBounds() public {
        vm.startPrank(owner);

        badges.setDurationBounds(12 hours, 180 days);
        assertEq(badges.minBadgeDuration(), 12 hours);
        assertEq(badges.maxBadgeDuration(), 180 days);

        vm.stopPrank();
    }

    function test_setDurationBounds_nonOwner() public {
        vm.startPrank(nonOwner);

        vm.expectRevert();
        badges.setDurationBounds(12 hours, 180 days);

        vm.stopPrank();
    }

    function test_setDurationBounds_invalidBounds() public {
        vm.startPrank(owner);

        vm.expectRevert("Invalid bounds");
        badges.setDurationBounds(0, 90 days); // min must be > 0

        vm.expectRevert("Invalid bounds");
        badges.setDurationBounds(30 days, 7 days); // max must be > min

        vm.stopPrank();
    }

    // ========================
    // Factory Authorization Tests
    // ========================

    function test_setAuthorizedFactory() public {
        vm.startPrank(owner);

        badges.setAuthorizedFactory(factory, true);
        assertTrue(badges.authorizedFactories(factory));

        badges.setAuthorizedFactory(factory, false);
        assertFalse(badges.authorizedFactories(factory));

        vm.stopPrank();
    }

    function test_setAuthorizedFactory_nonOwner() public {
        vm.startPrank(nonOwner);

        vm.expectRevert();
        badges.setAuthorizedFactory(factory, true);

        vm.stopPrank();
    }

    // ========================
    // Treasury Update Tests
    // ========================

    function test_setProtocolTreasury() public {
        vm.startPrank(owner);

        address newTreasury = address(0xDEAD);
        badges.setProtocolTreasury(newTreasury);
        assertEq(badges.protocolTreasury(), newTreasury);

        vm.stopPrank();
    }

    function test_setProtocolTreasury_revertZeroAddress() public {
        vm.startPrank(owner);

        vm.expectRevert("Invalid treasury");
        badges.setProtocolTreasury(address(0));

        vm.stopPrank();
    }

    function test_setProtocolTreasury_nonOwner() public {
        vm.startPrank(nonOwner);

        vm.expectRevert();
        badges.setProtocolTreasury(address(0xDEAD));

        vm.stopPrank();
    }

    // ========================
    // Default Pricing Tests
    // ========================

    function test_defaultPricing() public {
        assertEq(badges.badgePricePerDay(PromotionBadges.BadgeType.HIGHLIGHT), 0.001 ether);
        assertEq(badges.badgePricePerDay(PromotionBadges.BadgeType.TRENDING), 0.002 ether);
        assertEq(badges.badgePricePerDay(PromotionBadges.BadgeType.VERIFIED), 0.005 ether);
        assertEq(badges.badgePricePerDay(PromotionBadges.BadgeType.SPOTLIGHT), 0.01 ether);
    }

    // ========================
    // Event Tests
    // ========================

    function test_purchaseBadge_emitsEvent() public {
        vm.deal(buyer, 1 ether);
        vm.startPrank(buyer);

        uint256 duration = 7 days;
        uint256 cost = (0.001 ether * duration) / 1 days;

        vm.expectEmit(true, true, false, true);
        emit PromotionBadges.BadgePurchased(instance1, buyer, PromotionBadges.BadgeType.HIGHLIGHT, duration, cost);

        badges.purchaseBadge{value: cost}(instance1, PromotionBadges.BadgeType.HIGHLIGHT, duration);

        vm.stopPrank();
    }

    function test_assignBadgeFor_emitsEvent() public {
        vm.startPrank(owner);
        badges.setAuthorizedFactory(factory, true);
        vm.stopPrank();

        vm.startPrank(factory);

        vm.expectEmit(true, true, false, true);
        emit PromotionBadges.BadgeAssigned(instance1, factory, PromotionBadges.BadgeType.HIGHLIGHT, 14 days);

        badges.assignBadgeFor(instance1, PromotionBadges.BadgeType.HIGHLIGHT, 14 days);

        vm.stopPrank();
    }
}
