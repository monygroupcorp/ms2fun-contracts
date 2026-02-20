// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {FeaturedQueueManager} from "../../src/master/FeaturedQueueManager.sol";
import {IMasterRegistry} from "../../src/master/interfaces/IMasterRegistry.sol";

// ── Minimal mock registry ──────────────────────────────────────────────────────

contract MockRegistry {
    mapping(address => bool) public registered;

    function register(address instance) external {
        registered[instance] = true;
    }

    function getInstanceInfo(address instance) external view returns (IMasterRegistry.InstanceInfo memory info) {
        require(registered[instance], "Not registered");
        info.instance = instance;
    }
}

// ── Test suite ─────────────────────────────────────────────────────────────────

contract MasterRegistryQueueTest is Test {
    FeaturedQueueManager queue;
    MockRegistry          registry;

    address owner     = makeAddr("owner");
    address alice     = makeAddr("alice");
    address bob       = makeAddr("bob");
    address charlie   = makeAddr("charlie");
    address factory_  = makeAddr("factory");

    // Three registered instances
    address inst1 = makeAddr("inst1");
    address inst2 = makeAddr("inst2");
    address inst3 = makeAddr("inst3");

    function setUp() public {
        registry = new MockRegistry();
        registry.register(inst1);
        registry.register(inst2);
        registry.register(inst3);

        queue = new FeaturedQueueManager();
        queue.initialize(address(registry), owner);

        vm.deal(alice,   100 ether);
        vm.deal(bob,     100 ether);
        vm.deal(charlie, 100 ether);
        vm.deal(factory_, 100 ether);
    }

    // ── Helpers ────────────────────────────────────────────────────────────────

    function _rentBasic(address instance, address renter, uint256 rankBoost) internal {
        uint256 duration     = queue.minDuration();
        uint256 durationCost = queue.quoteDurationCost(duration);
        uint256 total        = durationCost + rankBoost;
        vm.deal(renter, renter.balance + total);
        vm.prank(renter);
        queue.rentFeatured{value: total}(instance, duration, rankBoost);
    }

    // ── rentFeatured ──────────────────────────────────────────────────────────

    function test_rentFeatured_basic() public {
        _rentBasic(inst1, alice, 0);

        (, uint256 effectiveRank, uint256 expiresAt, bool isActive) = queue.getRentalInfo(inst1);
        assertEq(effectiveRank, 0);
        assertGt(expiresAt, block.timestamp);
        assertTrue(isActive);
    }

    function test_rentFeatured_withRankBoost() public {
        _rentBasic(inst1, alice, 0.01 ether);

        (, uint256 effectiveRank,, bool isActive) = queue.getRentalInfo(inst1);
        assertEq(effectiveRank, 0.01 ether);
        assertTrue(isActive);
    }

    function test_rentFeatured_renterRecorded() public {
        _rentBasic(inst1, alice, 0);
        (address renter,,,) = queue.getRentalInfo(inst1);
        assertEq(renter, alice);
    }

    function test_rentFeatured_refundsExcess() public {
        uint256 duration     = queue.minDuration();
        uint256 durationCost = queue.quoteDurationCost(duration);
        uint256 rankBoost    = 0.005 ether;
        uint256 excess       = 0.001 ether;

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        queue.rentFeatured{value: durationCost + rankBoost + excess}(inst1, duration, rankBoost);

        assertEq(alice.balance, balanceBefore - durationCost - rankBoost);
    }

    function test_rentFeatured_revert_alreadyActive() public {
        _rentBasic(inst1, alice, 0);

        // Pre-compute all values before vm.expectRevert (external calls reset the expectation)
        uint256 duration = queue.minDuration();
        uint256 cost     = queue.quoteDurationCost(duration);
        vm.deal(bob, bob.balance + cost);

        vm.prank(bob);
        vm.expectRevert("Already featured");
        queue.rentFeatured{value: cost}(inst1, duration, 0);
    }

    function test_rentFeatured_revert_insufficientPayment() public {
        uint256 duration = queue.minDuration();
        uint256 cost     = queue.quoteDurationCost(duration);

        vm.prank(alice);
        vm.expectRevert("Insufficient payment");
        queue.rentFeatured{value: cost - 1}(inst1, duration, 0);
    }

    function test_rentFeatured_revert_durationTooShort() public {
        uint256 minDur = queue.minDuration();
        uint256 cost   = queue.quoteDurationCost(minDur - 1);

        vm.prank(alice);
        vm.expectRevert("Invalid duration");
        queue.rentFeatured{value: cost}(inst1, minDur - 1, 0);
    }

    function test_rentFeatured_revert_durationTooLong() public {
        uint256 maxDur = queue.maxDuration();
        uint256 cost   = queue.quoteDurationCost(maxDur + 1 days);

        vm.prank(alice);
        vm.expectRevert("Invalid duration");
        queue.rentFeatured{value: cost}(inst1, maxDur + 1 days, 0);
    }

    function test_rentFeatured_revert_unregisteredInstance() public {
        address unknown  = makeAddr("unknown");
        uint256 duration = queue.minDuration();
        uint256 cost     = queue.quoteDurationCost(duration);

        vm.prank(alice);
        vm.expectRevert("Instance not registered");
        queue.rentFeatured{value: cost}(unknown, duration, 0);
    }

    function test_rentFeatured_incrementsQueueLength() public {
        assertEq(queue.queueLength(), 0);
        _rentBasic(inst1, alice, 0);
        assertEq(queue.queueLength(), 1);
        _rentBasic(inst2, bob, 0);
        assertEq(queue.queueLength(), 2);
    }

    function test_rentFeatured_afterExpiry_allowsRerent() public {
        _rentBasic(inst1, alice, 0);
        (,, uint256 expiresAt,) = queue.getRentalInfo(inst1);
        vm.warp(expiresAt + 1);
        _rentBasic(inst1, bob, 0);
        (address renter,,,) = queue.getRentalInfo(inst1);
        assertEq(renter, bob);
    }

    // ── boostRank ─────────────────────────────────────────────────────────────

    function test_boostRank_increasesRank() public {
        _rentBasic(inst1, alice, 0.01 ether);
        (, uint256 rankBefore,,) = queue.getRentalInfo(inst1);

        vm.prank(bob);
        queue.boostRank{value: 0.005 ether}(inst1);

        (, uint256 rankAfter,,) = queue.getRentalInfo(inst1);
        assertGt(rankAfter, rankBefore);
    }

    function test_boostRank_anyoneCanBoost() public {
        _rentBasic(inst1, alice, 0);

        vm.prank(charlie);
        queue.boostRank{value: 0.01 ether}(inst1);

        (, uint256 rank,,) = queue.getRentalInfo(inst1);
        assertEq(rank, 0.01 ether);
    }

    function test_boostRank_revert_slotInactive() public {
        vm.prank(alice);
        vm.expectRevert("Slot not active");
        queue.boostRank{value: 0.01 ether}(inst1);
    }

    function test_boostRank_revert_zeroValue() public {
        _rentBasic(inst1, alice, 0);

        vm.prank(alice);
        vm.expectRevert("Must send ETH");
        queue.boostRank{value: 0}(inst1);
    }

    // ── renewDuration ─────────────────────────────────────────────────────────

    function test_renewDuration_extendsExpiry() public {
        _rentBasic(inst1, alice, 0);
        (,, uint256 expiresAtBefore,) = queue.getRentalInfo(inst1);

        uint256 extra = queue.minDuration();
        uint256 cost  = queue.quoteDurationCost(extra);
        vm.deal(alice, alice.balance + cost);
        vm.prank(alice);
        queue.renewDuration{value: cost}(inst1, extra);

        (,, uint256 expiresAtAfter,) = queue.getRentalInfo(inst1);
        assertEq(expiresAtAfter, expiresAtBefore + extra);
    }

    function test_renewDuration_doesNotAffectRank() public {
        _rentBasic(inst1, alice, 0.01 ether);
        (, uint256 rankBefore,,) = queue.getRentalInfo(inst1);

        uint256 extra = queue.minDuration();
        uint256 cost  = queue.quoteDurationCost(extra);
        vm.deal(bob, bob.balance + cost);
        vm.prank(bob);
        queue.renewDuration{value: cost}(inst1, extra);

        (, uint256 rankAfter,,) = queue.getRentalInfo(inst1);
        assertEq(rankAfter, rankBefore);
    }

    function test_renewDuration_anyoneCanRenew() public {
        _rentBasic(inst1, alice, 0);
        (,, uint256 expiresAtBefore,) = queue.getRentalInfo(inst1);

        uint256 extra = queue.minDuration();
        uint256 cost  = queue.quoteDurationCost(extra);
        vm.deal(charlie, charlie.balance + cost);
        vm.prank(charlie);
        queue.renewDuration{value: cost}(inst1, extra);

        (,, uint256 expiresAtAfter,) = queue.getRentalInfo(inst1);
        assertGt(expiresAtAfter, expiresAtBefore);
    }

    function test_renewDuration_revert_slotExpired() public {
        _rentBasic(inst1, alice, 0);
        (,, uint256 expiresAt,) = queue.getRentalInfo(inst1);
        vm.warp(expiresAt + 1);

        uint256 extra = queue.minDuration();
        uint256 cost  = queue.quoteDurationCost(extra);
        vm.deal(bob, bob.balance + cost);

        vm.prank(bob);
        vm.expectRevert("Slot expired - use rentFeatured");
        queue.renewDuration{value: cost}(inst1, extra);
    }

    function test_renewDuration_refundsExcess() public {
        _rentBasic(inst1, alice, 0);

        uint256 extra  = queue.minDuration();
        uint256 cost   = queue.quoteDurationCost(extra);
        uint256 excess = 0.002 ether;

        uint256 balBefore = alice.balance;
        vm.deal(alice, alice.balance + cost + excess);
        vm.prank(alice);
        queue.renewDuration{value: cost + excess}(inst1, extra);

        assertEq(alice.balance, balBefore + excess);
    }

    // ── Rank decay ─────────────────────────────────────────────────────────────

    function test_rankDecay_reducesOverTime() public {
        _rentBasic(inst1, alice, 1 ether);

        (, uint256 rankDay0,,) = queue.getRentalInfo(inst1);
        assertEq(rankDay0, 1 ether);

        vm.warp(block.timestamp + 1 days);
        (, uint256 rankDay1,,) = queue.getRentalInfo(inst1);
        assertEq(rankDay1, 1 ether - queue.dailyDecayRate());

        vm.warp(block.timestamp + 4 days); // 5 days total
        (, uint256 rankDay5,,) = queue.getRentalInfo(inst1);
        assertEq(rankDay5, 1 ether - queue.dailyDecayRate() * 5);
    }

    function test_rankDecay_floorsAtZero() public {
        _rentBasic(inst1, alice, 0.001 ether);

        vm.warp(block.timestamp + 100 days);
        (, uint256 rank,,) = queue.getRentalInfo(inst1);
        assertEq(rank, 0);
    }

    function test_rankDecay_crystallizedOnBoost() public {
        _rentBasic(inst1, alice, 1 ether);

        vm.warp(block.timestamp + 3 days);
        (, uint256 rankBeforeBoost,,) = queue.getRentalInfo(inst1);
        assertEq(rankBeforeBoost, 1 ether - queue.dailyDecayRate() * 3);

        vm.prank(bob);
        queue.boostRank{value: 0.5 ether}(inst1);

        (, uint256 rankAfterBoost,,) = queue.getRentalInfo(inst1);
        assertEq(rankAfterBoost, rankBeforeBoost + 0.5 ether);

        // Decay clock reset — only 1 day of decay from the boost time
        vm.warp(block.timestamp + 1 days);
        (, uint256 rankNextDay,,) = queue.getRentalInfo(inst1);
        assertEq(rankNextDay, rankAfterBoost - queue.dailyDecayRate());
    }

    // ── Rank carry ────────────────────────────────────────────────────────────

    function test_rankCarry_acrossExpiry() public {
        _rentBasic(inst1, alice, 0.5 ether);

        // Warp to expiry — minDuration days have elapsed, so 7 days of decay applied
        (,, uint256 expiresAt,) = queue.getRentalInfo(inst1);
        vm.warp(expiresAt + 1);

        // Re-rent — carries decayed rank (7 integer days elapsed)
        uint256 daysElapsed  = (queue.minDuration() + 1) / 1 days; // = 7
        uint256 expectedRank = 0.5 ether - queue.dailyDecayRate() * daysElapsed;

        _rentBasic(inst1, alice, 0);
        (, uint256 rankSecond,,) = queue.getRentalInfo(inst1);
        assertEq(rankSecond, expectedRank);
    }

    function test_rankCarry_acrossDifferentRenters() public {
        _rentBasic(inst1, alice, 0.5 ether);

        // Expire and re-rent by bob
        (,, uint256 expiresAt,) = queue.getRentalInfo(inst1);
        vm.warp(expiresAt + 1);

        uint256 daysElapsed  = (queue.minDuration() + 1) / 1 days;
        uint256 expectedRank = 0.5 ether - queue.dailyDecayRate() * daysElapsed;

        _rentBasic(inst1, bob, 0);
        (address renter, uint256 rankBob,,) = queue.getRentalInfo(inst1);
        assertEq(renter, bob);
        assertEq(rankBob, expectedRank);
    }

    // ── getFeaturedInstances ordering ─────────────────────────────────────────

    function test_getFeaturedInstances_sortedByRankDesc() public {
        _rentBasic(inst1, alice,   0.01 ether);
        _rentBasic(inst2, bob,     0.05 ether);
        _rentBasic(inst3, charlie, 0.03 ether);

        (address[] memory result,) = queue.getFeaturedInstances(0, 10);
        assertEq(result.length, 3);
        assertEq(result[0], inst2);
        assertEq(result[1], inst3);
        assertEq(result[2], inst1);
    }

    function test_getFeaturedInstances_excludesExpired() public {
        _rentBasic(inst1, alice, 0);
        vm.warp(block.timestamp + 2); // 2-second gap — inst2 expires 2 seconds after inst1
        _rentBasic(inst2, bob,   0);

        // Warp to inst1 expiry + 1 second — inst1 expired, inst2 has 1 second left
        (,, uint256 expiresAt1,) = queue.getRentalInfo(inst1);
        vm.warp(expiresAt1 + 1);

        (address[] memory result, uint256 total) = queue.getFeaturedInstances(0, 10);
        assertEq(total, 1);
        assertEq(result.length, 1);
        assertEq(result[0], inst2);
    }

    function test_getFeaturedInstances_pagination() public {
        _rentBasic(inst1, alice,   0.01 ether);
        _rentBasic(inst2, bob,     0.05 ether);
        _rentBasic(inst3, charlie, 0.03 ether);

        // Sorted: inst2 (0.05), inst3 (0.03), inst1 (0.01)
        (address[] memory page0, uint256 total) = queue.getFeaturedInstances(0, 2);
        assertEq(total, 3);
        assertEq(page0.length, 2);
        assertEq(page0[0], inst2);
        assertEq(page0[1], inst3);

        (address[] memory page1,) = queue.getFeaturedInstances(2, 2);
        assertEq(page1.length, 1);
        assertEq(page1[0], inst1);
    }

    function test_getFeaturedInstances_rankBoostUpdatesOrder() public {
        _rentBasic(inst1, alice, 0.05 ether);
        _rentBasic(inst2, bob,   0.01 ether);

        (address[] memory resultBefore,) = queue.getFeaturedInstances(0, 10);
        assertEq(resultBefore[0], inst1);

        vm.prank(charlie);
        queue.boostRank{value: 0.1 ether}(inst2);

        (address[] memory resultAfter,) = queue.getFeaturedInstances(0, 10);
        assertEq(resultAfter[0], inst2);
        assertEq(resultAfter[1], inst1);
    }

    function test_getFeaturedInstances_decayShiftsOrder() public {
        // Use max duration so slots outlast the decay period
        uint256 maxDur       = queue.maxDuration();
        uint256 durationCost = queue.quoteDurationCost(maxDur);
        uint256 rank         = 1 ether;

        // Rent inst1 first — decay clock starts at T0
        vm.deal(alice, alice.balance + durationCost + rank);
        vm.prank(alice);
        queue.rentFeatured{value: durationCost + rank}(inst1, maxDur, rank);

        // Advance 30 days — inst1 has been decaying while inst2 hasn't started
        vm.warp(block.timestamp + 30 days);

        // Rent inst2 with same rank — fresh decay clock at T0+30d
        vm.deal(bob, bob.balance + durationCost + rank);
        vm.prank(bob);
        queue.rentFeatured{value: durationCost + rank}(inst2, maxDur, rank);

        // inst1 effective = 1e - 30*decayRate; inst2 effective = 1e → inst2 leads
        (address[] memory result,) = queue.getFeaturedInstances(0, 10);
        assertEq(result.length, 2);
        assertEq(result[0], inst2);
        assertEq(result[1], inst1);
    }

    function test_getFeaturedInstances_emptyWhenNoneActive() public {
        (address[] memory result, uint256 total) = queue.getFeaturedInstances(0, 10);
        assertEq(result.length, 0);
        assertEq(total, 0);
    }

    function test_getFeaturedInstances_offsetBeyondTotal() public {
        _rentBasic(inst1, alice, 0);

        (address[] memory result, uint256 total) = queue.getFeaturedInstances(5, 10);
        assertEq(total, 1);
        assertEq(result.length, 0);
    }

    // ── queueLength ──────────────────────────────────────────────────────────

    function test_queueLength_onlyCountsActive() public {
        _rentBasic(inst1, alice, 0);
        vm.warp(block.timestamp + 2); // 2-second gap so inst2 expires later
        _rentBasic(inst2, bob,   0);
        assertEq(queue.queueLength(), 2);

        // Expire only inst1
        (,, uint256 expiresAt1,) = queue.getRentalInfo(inst1);
        vm.warp(expiresAt1 + 1);
        assertEq(queue.queueLength(), 1);
    }

    // ── maxFeaturedSize cap ───────────────────────────────────────────────────

    function test_rentFeatured_revert_featuredSetFull() public {
        vm.prank(owner);
        queue.setMaxFeaturedSize(2);

        _rentBasic(inst1, alice, 0);
        _rentBasic(inst2, bob,   0);

        address inst4 = makeAddr("inst4");
        registry.register(inst4);

        // Pre-compute values before vm.expectRevert
        uint256 duration = queue.minDuration();
        uint256 cost     = queue.quoteDurationCost(duration);
        vm.deal(charlie, charlie.balance + cost);

        vm.prank(charlie);
        vm.expectRevert("Featured set full");
        queue.rentFeatured{value: cost}(inst4, duration, 0);
    }

    // ── rentFeaturedFor (factory bundle) ─────────────────────────────────────

    function test_rentFeaturedFor_authorizedFactory_succeeds() public {
        vm.prank(owner);
        queue.setAuthorizedFactory(factory_, true, 1000); // 10% discount

        uint256 duration     = queue.minDuration();
        uint256 durationCost = queue.quoteDurationCost(duration);
        uint256 discount     = durationCost * 1000 / 10000;
        uint256 netCost      = durationCost - discount;
        uint256 rankBoost    = 0.005 ether;

        vm.prank(factory_);
        queue.rentFeaturedFor{value: netCost + rankBoost}(inst1, alice, duration, rankBoost);

        (address renter,,, bool isActive) = queue.getRentalInfo(inst1);
        assertEq(renter, alice);
        assertTrue(isActive);
    }

    function test_rentFeaturedFor_unauthorizedFactory_reverts() public {
        // Pre-compute values before vm.expectRevert
        uint256 duration = queue.minDuration();
        uint256 cost     = queue.quoteDurationCost(duration);

        vm.prank(factory_);
        vm.expectRevert("Not authorized");
        queue.rentFeaturedFor{value: cost}(inst1, alice, duration, 0);
    }

    function test_rentFeaturedFor_zeroDiscount() public {
        vm.prank(owner);
        queue.setAuthorizedFactory(factory_, true, 0);

        uint256 duration = queue.minDuration();
        uint256 cost     = queue.quoteDurationCost(duration);

        vm.prank(factory_);
        queue.rentFeaturedFor{value: cost}(inst1, alice, duration, 0);

        (,,, bool isActive) = queue.getRentalInfo(inst1);
        assertTrue(isActive);
    }

    // ── Admin functions ───────────────────────────────────────────────────────

    function test_withdrawProtocolFees() public {
        _rentBasic(inst1, alice, 0);

        vm.prank(owner);
        queue.setProtocolTreasury(makeAddr("treasury"));

        address treasury    = queue.protocolTreasury();
        uint256 contractBal = address(queue).balance;
        assertGt(contractBal, 0);

        uint256 treasuryBefore = treasury.balance;

        vm.prank(owner);
        queue.withdrawProtocolFees();

        assertEq(treasury.balance, treasuryBefore + contractBal);
        assertEq(address(queue).balance, 0);
    }

    function test_setDailyRate_onlyOwner() public {
        vm.prank(owner);
        queue.setDailyRate(0.002 ether);
        assertEq(queue.dailyRate(), 0.002 ether);
    }

    function test_setDailyRate_revert_notOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        queue.setDailyRate(0.002 ether);
    }

    function test_setAuthorizedFactory_maxDiscount() public {
        vm.prank(owner);
        vm.expectRevert("Discount too high");
        queue.setAuthorizedFactory(factory_, true, 5001);
    }

    function test_setAuthorizedFactory_deauthorize() public {
        vm.prank(owner);
        queue.setAuthorizedFactory(factory_, true, 0);

        vm.prank(owner);
        queue.setAuthorizedFactory(factory_, false, 0);

        assertFalse(queue.authorizedFactories(factory_));
        assertEq(queue.factoryDiscountBps(factory_), 0);
    }

    function test_quoteDurationCost_matchesDailyRate() public view {
        uint256 cost = queue.quoteDurationCost(1 days);
        assertEq(cost, queue.dailyRate());
    }
}
