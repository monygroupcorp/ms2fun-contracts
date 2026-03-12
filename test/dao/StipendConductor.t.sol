// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {GrandCentral} from "../../src/dao/GrandCentral.sol";
import {StipendConductor} from "../../src/dao/conductors/StipendConductor.sol";
import {MockSafe} from "../mocks/MockSafe.sol";

contract StipendConductorTest is Test {
    GrandCentral public dao;
    MockSafe public mockSafe;
    StipendConductor public stipend;

    address public founder = makeAddr("founder");
    address public alice = makeAddr("alice");

    uint256 constant MONTHLY_AMOUNT = 6 ether;
    uint256 constant INITIAL_SHARES = 1000;

    function setUp() public {
        mockSafe = new MockSafe();
        dao = new GrandCentral(address(mockSafe), founder, INITIAL_SHARES, 5 days, 2 days, 0, 1, 66);
        vm.deal(address(mockSafe), 100 ether);

        stipend = new StipendConductor(address(dao), founder, MONTHLY_AMOUNT, 30 days);

        // Register stipend as manager conductor via DAO self-call
        address[] memory addrs = new address[](1);
        addrs[0] = address(stipend);
        uint256[] memory perms = new uint256[](1);
        perms[0] = 2; // manager
        vm.prank(address(dao));
        dao.setConductors(addrs, perms);
    }

    function test_ExecuteStipend() public {
        stipend.execute();
        assertEq(founder.balance, MONTHLY_AMOUNT);
    }

    function test_ExecuteStipend_RevertIfTooEarly() public {
        stipend.execute();
        vm.expectRevert(StipendConductor.TooEarly.selector);
        stipend.execute();
    }

    function test_ExecuteStipend_WorksAfterInterval() public {
        stipend.execute();
        vm.warp(block.timestamp + 30 days + 1);
        stipend.execute();
        assertEq(founder.balance, MONTHLY_AMOUNT * 2);
    }

    function test_ExecuteStipend_RevertIfRevoked() public {
        vm.prank(address(dao));
        stipend.revoke();
        vm.expectRevert(StipendConductor.Revoked.selector);
        stipend.execute();
    }

    function test_Revoke_OnlyDAO() public {
        vm.prank(alice);
        vm.expectRevert(StipendConductor.Unauthorized.selector);
        stipend.revoke();
    }

    function test_UpdateAmount() public {
        vm.prank(address(dao));
        stipend.updateAmount(10 ether);
        stipend.execute();
        assertEq(founder.balance, 10 ether);
    }

    function test_UpdateBeneficiary() public {
        vm.prank(address(dao));
        stipend.updateBeneficiary(alice);
        stipend.execute();
        assertEq(alice.balance, MONTHLY_AMOUNT);
    }

    function test_StipendRoutedThroughSafe() public {
        stipend.execute();
        assertGt(mockSafe.executionCount(), 0);
    }

    // ============ Constructor Validation ============

    function test_Constructor_SetsImmutables() public view {
        assertEq(stipend.dao(), address(dao));
        assertEq(stipend.beneficiary(), founder);
        assertEq(stipend.amount(), MONTHLY_AMOUNT);
        assertEq(stipend.interval(), 30 days);
    }

    function test_Constructor_RevertIfZeroDAO() public {
        vm.expectRevert(StipendConductor.InvalidAddress.selector);
        new StipendConductor(address(0), founder, MONTHLY_AMOUNT, 30 days);
    }

    function test_Constructor_RevertIfZeroBeneficiary() public {
        vm.expectRevert(StipendConductor.InvalidAddress.selector);
        new StipendConductor(address(dao), address(0), MONTHLY_AMOUNT, 30 days);
    }

    function test_Constructor_RevertIfZeroAmount() public {
        vm.expectRevert(StipendConductor.ZeroAmount.selector);
        new StipendConductor(address(dao), founder, 0, 30 days);
    }

    function test_Constructor_RevertIfZeroInterval() public {
        vm.expectRevert(StipendConductor.ZeroInterval.selector);
        new StipendConductor(address(dao), founder, MONTHLY_AMOUNT, 0);
    }

    // ============ nextExecutionTime ============

    function test_NextExecutionTime_ZeroBeforeFirstExecution() public view {
        assertEq(stipend.nextExecutionTime(), 0);
    }

    function test_NextExecutionTime_AfterExecution() public {
        uint256 execTime = block.timestamp;
        stipend.execute();
        assertEq(stipend.nextExecutionTime(), execTime + 30 days);
    }

    function test_NextExecutionTime_UpdatesAfterSecondExecution() public {
        vm.warp(1000);
        stipend.execute();
        assertEq(stipend.nextExecutionTime(), 1000 + 30 days);

        vm.warp(1000 + 30 days);
        stipend.execute();
        assertEq(stipend.nextExecutionTime(), 1000 + 60 days);
    }

    // ============ Events ============

    function test_Execute_EmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit StipendConductor.StipendExecuted(founder, MONTHLY_AMOUNT, block.timestamp);
        stipend.execute();
    }

    function test_Revoke_EmitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit StipendConductor.StipendRevoked(block.timestamp);
        vm.prank(address(dao));
        stipend.revoke();
    }

    function test_UpdateAmount_EmitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit StipendConductor.StipendAmountUpdated(MONTHLY_AMOUNT, 10 ether);
        vm.prank(address(dao));
        stipend.updateAmount(10 ether);
    }

    function test_UpdateBeneficiary_EmitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit StipendConductor.BeneficiaryUpdated(founder, alice);
        vm.prank(address(dao));
        stipend.updateBeneficiary(alice);
    }

    // ============ Update Revert Cases ============

    function test_UpdateAmount_RevertIfZero() public {
        vm.expectRevert(StipendConductor.ZeroAmount.selector);
        vm.prank(address(dao));
        stipend.updateAmount(0);
    }

    function test_UpdateAmount_RevertIfNotDAO() public {
        vm.expectRevert(StipendConductor.Unauthorized.selector);
        vm.prank(alice);
        stipend.updateAmount(10 ether);
    }

    function test_UpdateBeneficiary_RevertIfZeroAddress() public {
        vm.expectRevert(StipendConductor.InvalidAddress.selector);
        vm.prank(address(dao));
        stipend.updateBeneficiary(address(0));
    }

    function test_UpdateBeneficiary_RevertIfNotDAO() public {
        vm.expectRevert(StipendConductor.Unauthorized.selector);
        vm.prank(alice);
        stipend.updateBeneficiary(alice);
    }

    // ============ Edge Cases ============

    function test_Execute_AtExactInterval() public {
        stipend.execute();
        // Warp to exactly lastExecuted + interval (should still revert — strict <)
        vm.warp(block.timestamp + 30 days - 1);
        vm.expectRevert(StipendConductor.TooEarly.selector);
        stipend.execute();

        // At exact boundary
        vm.warp(block.timestamp + 1);
        stipend.execute();
        assertEq(founder.balance, MONTHLY_AMOUNT * 2);
    }

    function test_Revoke_PermanentlyBlocks() public {
        vm.prank(address(dao));
        stipend.revoke();
        assertTrue(stipend.revoked());

        // Even after time passes, still reverted
        vm.warp(block.timestamp + 365 days);
        vm.expectRevert(StipendConductor.Revoked.selector);
        stipend.execute();
    }
}
