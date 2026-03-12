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
}
