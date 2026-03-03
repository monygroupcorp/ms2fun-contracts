// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {GrandCentral} from "../../src/dao/GrandCentral.sol";

contract AgentConductorTest is Test {
    GrandCentral public dao;
    address public safe;
    address public founder = address(0x1);
    address public conductor = address(0x2);

    function setUp() public {
        safe = address(new MockSafe());
        dao = new GrandCentral(
            safe,
            founder,
            100,    // initialShares
            1 days, // votingPeriod
            1 days, // gracePeriod
            51,     // quorumPercent
            10,     // sponsorThreshold
            50      // minRetentionPercent
        );
    }

    function test_isAgentConductor_false_by_default() public view {
        assertFalse(dao.isAgentConductor(conductor));
    }

    function test_isAgentConductor_true_when_bit_8_set() public {
        // bit 8 = agentConductor permission
        address[] memory addrs = new address[](1);
        addrs[0] = conductor;
        uint256[] memory perms = new uint256[](1);
        perms[0] = 8;

        vm.prank(address(dao));
        dao.setConductors(addrs, perms);

        assertTrue(dao.isAgentConductor(conductor));
    }

    function test_isAgentConductor_combined_permissions() public {
        // 2 (manager) | 8 (agentConductor) = 10
        address[] memory addrs = new address[](1);
        addrs[0] = conductor;
        uint256[] memory perms = new uint256[](1);
        perms[0] = 10;

        vm.prank(address(dao));
        dao.setConductors(addrs, perms);

        assertTrue(dao.isAgentConductor(conductor));
        assertTrue(dao.isManager(conductor));
        assertFalse(dao.isAdmin(conductor));
    }
}

contract MockSafe {
    function execTransactionFromModule(address, uint256, bytes memory, uint8) external pure returns (bool) {
        return true;
    }
    fallback() external payable {}
    receive() external payable {}
}
