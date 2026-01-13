// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {MasterRegistryV1} from "../../src/master/MasterRegistryV1.sol";
import {FeaturedQueueManager} from "../../src/master/FeaturedQueueManager.sol";
import {IMasterRegistry} from "../../src/master/interfaces/IMasterRegistry.sol";
import {MockEXECToken} from "../mocks/MockEXECToken.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title MasterRegistryQueueTest
 * @notice Comprehensive test suite for MasterRegistryV1 queue system
 * @dev Tests all queue operations: rent, bump, renew, cleanup
 */
contract MasterRegistryQueueTest is Test {
    MasterRegistryV1 public implementation;
    MasterRegistryV1 public registry;
    ERC1967Proxy public proxy;
    FeaturedQueueManager public queueManager;
    MockEXECToken public execToken;

    address public owner = address(0x1);
    address public factory = address(0x2);
    address public alice = address(0x3);
    address public bob = address(0x4);
    address public charlie = address(0x5);
    address public dave = address(0x6);

    // Test instances
    address public instance1 = address(0x101);
    address public instance2 = address(0x102);
    address public instance3 = address(0x103);
    address public instance4 = address(0x104);
    address public instance5 = address(0x105);

    // Events
    event PositionRented(
        address indexed instance,
        address indexed renter,
        uint256 indexed position,
        uint256 rentPaid,
        uint256 duration,
        uint256 expiresAt
    );

    event PositionBumped(
        address indexed instance,
        uint256 fromPosition,
        uint256 toPosition,
        uint256 bumpCost,
        uint256 additionalDuration
    );

    event PositionRenewed(
        address indexed instance,
        uint256 indexed position,
        uint256 additionalDuration,
        uint256 renewalCost,
        uint256 newExpiration
    );

    event PositionShifted(
        address indexed instance,
        uint256 fromPosition,
        uint256 toPosition
    );

    event RentalExpired(
        address indexed instance,
        uint256 indexed position,
        uint256 expiresAt
    );

    event CleanupRewardPaid(
        address indexed cleaner,
        uint256 cleanedCount,
        uint256 renewedCount,
        uint256 reward
    );

    // Receive function to accept cleanup rewards
    receive() external payable {}

    function setUp() public {
        vm.startPrank(owner);

        // Deploy EXEC token
        execToken = new MockEXECToken(100000e18);

        // Deploy implementation
        implementation = new MasterRegistryV1();

        // Deploy proxy
        bytes memory initData = abi.encodeWithSelector(
            MasterRegistryV1.initialize.selector,
            address(execToken),
            owner
        );
        proxy = new ERC1967Proxy(address(implementation), initData);
        registry = MasterRegistryV1(address(proxy));

        // Deploy and setup FeaturedQueueManager
        queueManager = new FeaturedQueueManager();
        queueManager.initialize(address(proxy), owner);
        registry.setFeaturedQueueManager(address(queueManager));

        // Register factory (name must be alphanumeric, hyphens, underscores only)
        registry.registerFactory(
            factory,
            "TestToken",
            "Test-Token-Factory",
            "TestToken",
            "https://test.uri"
        );

        vm.stopPrank();

        // Register test instances
        vm.startPrank(factory);
        registry.registerInstance(instance1, factory, alice, "Instance1", "https://uri1", address(0));
        registry.registerInstance(instance2, factory, bob, "Instance2", "https://uri2", address(0));
        registry.registerInstance(instance3, factory, charlie, "Instance3", "https://uri3", address(0));
        registry.registerInstance(instance4, factory, dave, "Instance4", "https://uri4", address(0));
        registry.registerInstance(instance5, factory, alice, "Instance5", "https://uri5", address(0));
        vm.stopPrank();

        // Fund test accounts
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(charlie, 100 ether);
        vm.deal(dave, 100 ether);

        // Fund registry for cleanup rewards
        vm.deal(address(registry), 10 ether);
    }

    // ========== Rental Price Tests ==========

    function test_getPositionRentalPrice_basePriceEmptyQueue() public view {
        uint256 price = queueManager.getPositionRentalPrice(1);
        assertEq(price, 0.001 ether, "Base price should be 0.001 ether for empty queue");
    }

    function test_getPositionRentalPrice_utilizationIncreasesPrice() public {
        // Rent 50 positions (50% utilization)
        for (uint256 i = 1; i <= 50; i++) {
            address testInstance = address(uint160(0x1000 + i));

            // Register instance
            vm.prank(factory);
            registry.registerInstance(testInstance, factory, alice, _validName(i), "https://uri", address(0));

            // Rent position
            vm.prank(alice);
            uint256 cost = queueManager.calculateRentalCost(i, 7 days);
            queueManager.rentFeaturedPosition{value: cost}(testInstance, i, 7 days);
        }

        // Price should be higher for position 51 due to 50% utilization
        uint256 price51 = queueManager.getPositionRentalPrice(51);
        assertTrue(price51 > 0.001 ether, "Price should increase with utilization");
    }

    // Helper to generate valid names (alphanumeric only)
    function _validName(uint256 i) internal pure returns (string memory) {
        return string(abi.encodePacked("Test-", _uint2str(i)));
    }

    function _uint2str(uint256 _i) internal pure returns (string memory) {
        if (_i == 0) return "0";

        uint256 j = _i;
        uint256 len;
        while (j != 0) {
            len++;
            j /= 10;
        }

        bytes memory bstr = new bytes(len);
        uint256 k = len;
        while (_i != 0) {
            k = k - 1;
            uint8 temp = (48 + uint8(_i - _i / 10 * 10));
            bytes1 b1 = bytes1(temp);
            bstr[k] = b1;
            _i /= 10;
        }
        return string(bstr);
    }

    function test_calculateRentalCost_validDuration() public view {
        uint256 cost7days = queueManager.calculateRentalCost(1, 7 days);
        uint256 cost14days = queueManager.calculateRentalCost(1, 14 days);
        uint256 cost30days = queueManager.calculateRentalCost(1, 30 days);

        // 14 days should be ~2x 7 days (with discount)
        assertTrue(cost14days < cost7days * 2, "14 days should have 5% discount");
        assertTrue(cost14days > cost7days, "14 days should cost more than 7 days");

        // 30 days should have 10% discount
        assertTrue(cost30days < cost7days * 4, "30 days should have 10% discount");
    }

    function test_calculateRentalCost_revertsOnTooShort() public {
        vm.expectRevert("Duration too short");
        queueManager.calculateRentalCost(1, 6 days);
    }

    function test_calculateRentalCost_revertsOnTooLong() public {
        vm.expectRevert("Duration too long");
        queueManager.calculateRentalCost(1, 366 days);
    }

    // ========== Rent Featured Position Tests ==========

    function test_rentFeaturedPosition_emptyQueue_success() public {
        uint256 cost = queueManager.calculateRentalCost(1, 7 days);

        vm.prank(alice);
        queueManager.rentFeaturedPosition{value: cost}(instance1, 1, 7 days);

        // Verify position
        (IMasterRegistry.RentalSlot memory slot, uint256 position,,) = queueManager.getRentalInfo(instance1);
        assertEq(position, 1, "Should be at position 1");
        assertEq(slot.instance, instance1, "Instance should match");
        assertEq(slot.renter, alice, "Renter should be alice");
        assertTrue(slot.active, "Rental should be active");
        assertEq(slot.rentPaid, cost, "Rent paid should match");
    }

    function test_rentFeaturedPosition_appendToBack() public {
        // Rent position 1
        vm.prank(alice);
        uint256 cost1 = queueManager.calculateRentalCost(1, 7 days);
        queueManager.rentFeaturedPosition{value: cost1}(instance1, 1, 7 days);

        // Rent position 2
        vm.prank(bob);
        uint256 cost2 = queueManager.calculateRentalCost(2, 7 days);
        queueManager.rentFeaturedPosition{value: cost2}(instance2, 2, 7 days);

        // Verify positions
        (,uint256 pos1,,) = queueManager.getRentalInfo(instance1);
        (,uint256 pos2,,) = queueManager.getRentalInfo(instance2);

        assertEq(pos1, 1, "Instance1 should be at position 1");
        assertEq(pos2, 2, "Instance2 should be at position 2");
    }

    function test_rentFeaturedPosition_insertInMiddle_shiftsDown() public {
        // Rent positions 1 and 2
        vm.prank(alice);
        queueManager.rentFeaturedPosition{value: queueManager.calculateRentalCost(1, 7 days)}(instance1, 1, 7 days);

        vm.prank(bob);
        queueManager.rentFeaturedPosition{value: queueManager.calculateRentalCost(2, 7 days)}(instance2, 2, 7 days);

        // Insert at position 1 - should shift both down
        vm.prank(charlie);
        uint256 cost = queueManager.calculateRentalCost(1, 7 days);
        queueManager.rentFeaturedPosition{value: cost}(instance3, 1, 7 days);

        // Verify positions after shift
        (,uint256 pos1,,) = queueManager.getRentalInfo(instance1);
        (,uint256 pos2,,) = queueManager.getRentalInfo(instance2);
        (,uint256 pos3,,) = queueManager.getRentalInfo(instance3);

        assertEq(pos3, 1, "Instance3 should be at position 1");
        assertEq(pos1, 2, "Instance1 shifted to position 2");
        assertEq(pos2, 3, "Instance2 shifted to position 3");
    }

    function test_rentFeaturedPosition_revertsOnAlreadyInQueue() public {
        vm.startPrank(alice);
        uint256 cost = queueManager.calculateRentalCost(1, 7 days);
        queueManager.rentFeaturedPosition{value: cost}(instance1, 1, 7 days);

        // Try to rent again
        vm.expectRevert("Already in queue - use bumpPosition instead");
        queueManager.rentFeaturedPosition{value: cost}(instance1, 2, 7 days);
        vm.stopPrank();
    }

    function test_rentFeaturedPosition_revertsOnInsufficientPayment() public {
        uint256 cost = queueManager.calculateRentalCost(1, 7 days);

        vm.prank(alice);
        vm.expectRevert("Insufficient payment");
        queueManager.rentFeaturedPosition{value: cost - 1}(instance1, 1, 7 days);
    }

    function test_rentFeaturedPosition_refundsExcess() public {
        uint256 cost = queueManager.calculateRentalCost(1, 7 days);
        uint256 excess = 1 ether;

        uint256 balanceBefore = alice.balance;

        vm.prank(alice);
        queueManager.rentFeaturedPosition{value: cost + excess}(instance1, 1, 7 days);

        uint256 balanceAfter = alice.balance;
        assertEq(balanceBefore - balanceAfter, cost, "Should refund excess");
    }

    // ========== Bump Position Tests ==========

    function test_bumpPosition_shiftsQueueCorrectly() public {
        // Setup: Rent 3 positions
        uint256 cost1 = queueManager.calculateRentalCost(1, 7 days);
        vm.prank(alice);
        queueManager.rentFeaturedPosition{value: cost1}(instance1, 1, 7 days);

        uint256 cost2 = queueManager.calculateRentalCost(2, 7 days);
        vm.prank(bob);
        queueManager.rentFeaturedPosition{value: cost2}(instance2, 2, 7 days);

        uint256 cost3 = queueManager.calculateRentalCost(3, 7 days);
        vm.prank(charlie);
        queueManager.rentFeaturedPosition{value: cost3}(instance3, 3, 7 days);

        // Charlie bumps from position 3 to position 1
        uint256 bumpCost = 0.01 ether; // Sufficient for bump
        vm.prank(charlie);
        queueManager.bumpPosition{value: bumpCost}(instance3, 1, 0);

        // Verify new positions
        (,uint256 pos1,,) = queueManager.getRentalInfo(instance1);
        (,uint256 pos2,,) = queueManager.getRentalInfo(instance2);
        (,uint256 pos3,,) = queueManager.getRentalInfo(instance3);

        assertEq(pos3, 1, "Instance3 bumped to position 1");
        assertEq(pos1, 2, "Instance1 shifted to position 2");
        assertEq(pos2, 3, "Instance2 shifted to position 3");
    }

    function test_bumpPosition_firstPosition_noShift() public {
        // Rent position 1
        vm.prank(alice);
        queueManager.rentFeaturedPosition{value: queueManager.calculateRentalCost(1, 7 days)}(instance1, 1, 7 days);

        // Try to bump to position 1 (already there)
        vm.prank(alice);
        vm.expectRevert("Invalid target position");
        queueManager.bumpPosition{value: 0.01 ether}(instance1, 1, 0);
    }

    function test_bumpPosition_withAdditionalDuration() public {
        // Setup
        uint256 cost2 = queueManager.calculateRentalCost(2, 7 days);
        vm.prank(alice);
        queueManager.rentFeaturedPosition{value: cost2}(instance1, 2, 7 days);

        // Bump with additional 7 days
        (IMasterRegistry.RentalSlot memory slotBefore,,,) = queueManager.getRentalInfo(instance1);

        uint256 bumpCost = 0.05 ether;
        vm.prank(alice);
        queueManager.bumpPosition{value: bumpCost}(instance1, 1, 7 days);

        (IMasterRegistry.RentalSlot memory slotAfter,,,) = queueManager.getRentalInfo(instance1);

        assertGt(slotAfter.expiresAt, slotBefore.expiresAt, "Expiration should be extended");
    }

    function test_bumpPosition_revertsOnNotInQueue() public {
        vm.prank(alice);
        vm.expectRevert("Not in queue");
        queueManager.bumpPosition{value: 0.01 ether}(instance1, 1, 0);
    }

    function test_bumpPosition_revertsOnNotYourRental() public {
        // Alice rents position 2
        vm.prank(alice);
        queueManager.rentFeaturedPosition{value: queueManager.calculateRentalCost(2, 7 days)}(instance1, 2, 7 days);

        // Bob tries to bump Alice's rental
        vm.prank(bob);
        vm.expectRevert("Not your rental");
        queueManager.bumpPosition{value: 0.01 ether}(instance1, 1, 0);
    }

    function test_bumpPosition_revertsOnExpiredRental() public {
        // Rent and wait for expiration
        uint256 cost = queueManager.calculateRentalCost(2, 7 days);
        vm.prank(alice);
        queueManager.rentFeaturedPosition{value: cost}(instance1, 2, 7 days);

        vm.warp(block.timestamp + 8 days);

        vm.prank(alice);
        vm.expectRevert("Rental expired");
        queueManager.bumpPosition{value: 0.01 ether}(instance1, 1, 0);
    }

    // ========== Renew Position Tests ==========

    function test_renewPosition_extendsExpiration() public {
        // Rent position
        uint256 cost = queueManager.calculateRentalCost(1, 7 days);
        vm.prank(alice);
        queueManager.rentFeaturedPosition{value: cost}(instance1, 1, 7 days);

        (IMasterRegistry.RentalSlot memory slotBefore,,,) = queueManager.getRentalInfo(instance1);

        // Renew for additional 7 days
        uint256 renewalCost = 0.01 ether;
        vm.prank(alice);
        queueManager.renewPosition{value: renewalCost}(instance1, 7 days);

        (IMasterRegistry.RentalSlot memory slotAfter,,,) = queueManager.getRentalInfo(instance1);

        assertEq(slotAfter.expiresAt, slotBefore.expiresAt + 7 days, "Should extend by 7 days");
    }

    function test_renewPosition_appliesDiscount() public {
        // Rent position
        uint256 initialCost = queueManager.calculateRentalCost(1, 7 days);
        vm.prank(alice);
        queueManager.rentFeaturedPosition{value: initialCost}(instance1, 1, 7 days);

        // Calculate expected renewal cost (90% of base = 10% discount)
        uint256 basePrice = queueManager.getPositionRentalPrice(1);
        uint256 expectedRenewalCost = (basePrice * 90) / 100;

        // Renew (should cost less than initial)
        vm.prank(alice);
        queueManager.renewPosition{value: expectedRenewalCost}(instance1, 7 days);

        // Verify renewal was accepted (no revert)
        (IMasterRegistry.RentalSlot memory slot,,,) = queueManager.getRentalInfo(instance1);
        assertTrue(slot.active, "Rental should still be active");
    }

    function test_renewPosition_revertsOnNotRenter() public {
        vm.prank(alice);
        queueManager.rentFeaturedPosition{value: queueManager.calculateRentalCost(1, 7 days)}(instance1, 1, 7 days);

        vm.prank(bob);
        vm.expectRevert("Not the renter");
        queueManager.renewPosition{value: 0.01 ether}(instance1, 7 days);
    }

    function test_renewPosition_revertsOnTooShortDuration() public {
        uint256 cost = queueManager.calculateRentalCost(1, 7 days);
        vm.prank(alice);
        queueManager.rentFeaturedPosition{value: cost}(instance1, 1, 7 days);

        vm.prank(alice);
        vm.expectRevert("Duration too short");
        queueManager.renewPosition{value: 0.01 ether}(instance1, 1 days);
    }

    // ========== Cleanup Tests ==========

    function test_cleanupExpiredRentals_marksInactive() public {
        // Rent positions
        vm.prank(alice);
        queueManager.rentFeaturedPosition{value: queueManager.calculateRentalCost(1, 7 days)}(instance1, 1, 7 days);

        vm.prank(bob);
        queueManager.rentFeaturedPosition{value: queueManager.calculateRentalCost(2, 7 days)}(instance2, 2, 7 days);

        // Wait for expiration
        vm.warp(block.timestamp + 8 days);

        // Cleanup
        queueManager.cleanupExpiredRentals(10);

        // Verify instances removed from queue
        (,uint256 pos1,,) = queueManager.getRentalInfo(instance1);
        (,uint256 pos2,,) = queueManager.getRentalInfo(instance2);

        assertEq(pos1, 0, "Instance1 should be removed");
        assertEq(pos2, 0, "Instance2 should be removed");
    }

    function test_cleanupExpiredRentals_paysReward() public {
        // Rent and expire
        vm.prank(alice);
        queueManager.rentFeaturedPosition{value: queueManager.calculateRentalCost(1, 7 days)}(instance1, 1, 7 days);

        vm.warp(block.timestamp + 8 days);

        uint256 balanceBefore = bob.balance;

        vm.prank(bob);
        queueManager.cleanupExpiredRentals(10);

        uint256 balanceAfter = bob.balance;
        assertGt(balanceAfter, balanceBefore, "Should receive cleanup reward");
    }

    function test_cleanupExpiredRentals_compactsQueue() public {
        // Rent 3 positions
        vm.prank(alice);
        queueManager.rentFeaturedPosition{value: queueManager.calculateRentalCost(1, 7 days)}(instance1, 1, 7 days);

        vm.prank(bob);
        queueManager.rentFeaturedPosition{value: queueManager.calculateRentalCost(2, 7 days)}(instance2, 2, 7 days);

        vm.prank(charlie);
        queueManager.rentFeaturedPosition{value: queueManager.calculateRentalCost(3, 7 days)}(instance3, 3, 7 days);

        // Expire all
        vm.warp(block.timestamp + 8 days);

        queueManager.cleanupExpiredRentals(10);

        // Verify queue is empty by checking all instances are removed
        (,uint256 pos1,,) = queueManager.getRentalInfo(instance1);
        (,uint256 pos2,,) = queueManager.getRentalInfo(instance2);
        (,uint256 pos3,,) = queueManager.getRentalInfo(instance3);

        assertEq(pos1, 0, "Instance1 should be removed");
        assertEq(pos2, 0, "Instance2 should be removed");
        assertEq(pos3, 0, "Instance3 should be removed");
    }

    // ========== Auto-Renewal Tests ==========

    function test_depositForAutoRenewal_success() public {
        vm.prank(alice);
        queueManager.rentFeaturedPosition{value: queueManager.calculateRentalCost(1, 7 days)}(instance1, 1, 7 days);

        vm.prank(alice);
        queueManager.depositForAutoRenewal{value: 1 ether}(instance1);

        (,,uint256 deposit,) = queueManager.getRentalInfo(instance1);
        assertEq(deposit, 1 ether, "Deposit should be stored");
    }

    function test_autoRenewal_renewsOnExpiration() public {
        // Rent and deposit for auto-renewal
        vm.startPrank(alice);
        queueManager.rentFeaturedPosition{value: queueManager.calculateRentalCost(1, 7 days)}(instance1, 1, 7 days);
        queueManager.depositForAutoRenewal{value: 1 ether}(instance1);
        vm.stopPrank();

        (IMasterRegistry.RentalSlot memory slotBefore,,,) = queueManager.getRentalInfo(instance1);

        // Wait for expiration and cleanup (triggers auto-renewal)
        vm.warp(block.timestamp + 8 days);
        queueManager.cleanupExpiredRentals(10);

        // Should still be active due to auto-renewal
        (IMasterRegistry.RentalSlot memory slotAfter, uint256 position, uint256 depositAfter,) = queueManager.getRentalInfo(instance1);

        assertEq(position, 1, "Should still be in position 1");
        assertTrue(slotAfter.active, "Should still be active");
        assertGt(slotAfter.expiresAt, slotBefore.expiresAt, "Should have new expiration");
        assertLt(depositAfter, 1 ether, "Deposit should be reduced");
    }

    function test_withdrawRenewalDeposit_success() public {
        vm.startPrank(alice);
        queueManager.rentFeaturedPosition{value: queueManager.calculateRentalCost(1, 7 days)}(instance1, 1, 7 days);
        queueManager.depositForAutoRenewal{value: 1 ether}(instance1);

        uint256 balanceBefore = alice.balance;
        queueManager.withdrawRenewalDeposit(instance1);
        uint256 balanceAfter = alice.balance;

        assertEq(balanceAfter - balanceBefore, 1 ether, "Should withdraw full deposit");
        vm.stopPrank();
    }

    // ========== Edge Cases ==========

    function test_multipleRentals_queueGrowth() public {
        // Rent 10 positions
        for (uint256 i = 0; i < 10; i++) {
            address testInstance = address(uint160(0x2000 + i));
            address renter = address(uint160(0x3000 + i));

            vm.prank(factory);
            registry.registerInstance(testInstance, factory, renter, _validName(100 + i), "https://uri", address(0));

            vm.deal(renter, 10 ether);
            vm.prank(renter);
            uint256 cost = queueManager.calculateRentalCost(i + 1, 7 days);
            queueManager.rentFeaturedPosition{value: cost}(testInstance, i + 1, 7 days);
        }

        (,uint256 total) = queueManager.getFeaturedInstances(0, 10);
        assertEq(total, 10, "Queue should have 10 rentals");
    }

    function test_getFeaturedInstances_pagination() public {
        // Rent 5 positions
        address[5] memory instances = [instance1, instance2, instance3, instance4, instance5];
        address[5] memory renters = [alice, bob, charlie, dave, alice];

        for (uint256 i = 0; i < 5; i++) {
            vm.prank(renters[i]);
            uint256 cost = queueManager.calculateRentalCost(i + 1, 7 days);
            queueManager.rentFeaturedPosition{value: cost}(instances[i], i + 1, 7 days);
        }

        // Get first 3
        (address[] memory first3, uint256 total) = queueManager.getFeaturedInstances(0, 3);
        assertEq(first3.length, 3, "Should return 3 instances");
        assertEq(total, 5, "Total should be 5");
        assertEq(first3[0], instance1, "First should be instance1");
        assertEq(first3[1], instance2, "Second should be instance2");
        assertEq(first3[2], instance3, "Third should be instance3");
    }

    function test_queueUtilization_metrics() public {
        // Empty queue
        (uint256 util0, uint256 price0, uint256 len0,) = queueManager.getQueueUtilization();
        assertEq(util0, 0, "Utilization should be 0");
        assertEq(len0, 0, "Length should be 0");

        // Rent 25 positions (25% full)
        for (uint256 i = 0; i < 25; i++) {
            address testInstance = address(uint160(0x4000 + i));
            address renter = address(uint160(0x5000 + i));

            vm.prank(factory);
            registry.registerInstance(testInstance, factory, renter, _validName(200 + i), "https://uri", address(0));

            vm.deal(renter, 10 ether);
            vm.prank(renter);
            uint256 cost = queueManager.calculateRentalCost(i + 1, 7 days);
            queueManager.rentFeaturedPosition{value: cost}(testInstance, i + 1, 7 days);
        }

        (uint256 util25, uint256 price25, uint256 len25, uint256 max25) = queueManager.getQueueUtilization();
        assertEq(len25, 25, "Length should be 25");
        assertEq(max25, 100, "Max should be 100");
        assertEq(util25, 2500, "Utilization should be 2500 bps (25%)");
        assertGt(price25, price0, "Price should increase with utilization");
    }
}
