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
        vm.expectRevert("too early");
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
        vm.expectRevert("revoked");
        stipend.execute();
    }

    function test_Revoke_OnlyDAO() public {
        vm.prank(alice);
        vm.expectRevert(bytes("!dao"));
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
}
