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

    function test_isAgentConductor_all_permissions() public {
        // 1 + 2 + 4 + 8 = 15
        address[] memory addrs = new address[](1);
        addrs[0] = conductor;
        uint256[] memory perms = new uint256[](1);
        perms[0] = 15;

        vm.prank(address(dao));
        dao.setConductors(addrs, perms);

        assertTrue(dao.isAdmin(conductor));
        assertTrue(dao.isManager(conductor));
        assertTrue(dao.isGovernor(conductor));
        assertTrue(dao.isAgentConductor(conductor));
    }

    function test_revoke_agentConductor() public {
        address[] memory addrs = new address[](1);
        addrs[0] = conductor;
        uint256[] memory perms = new uint256[](1);
        perms[0] = 8;

        vm.prank(address(dao));
        dao.setConductors(addrs, perms);
        assertTrue(dao.isAgentConductor(conductor));

        // Revoke
        perms[0] = 0;
        vm.prank(address(dao));
        dao.setConductors(addrs, perms);
        assertFalse(dao.isAgentConductor(conductor));
    }

    function test_downgrade_removes_agentConductor() public {
        address[] memory addrs = new address[](1);
        addrs[0] = conductor;
        uint256[] memory perms = new uint256[](1);
        perms[0] = 10; // manager + agent

        vm.prank(address(dao));
        dao.setConductors(addrs, perms);
        assertTrue(dao.isAgentConductor(conductor));
        assertTrue(dao.isManager(conductor));

        // Downgrade to manager only
        perms[0] = 2;
        vm.prank(address(dao));
        dao.setConductors(addrs, perms);
        assertFalse(dao.isAgentConductor(conductor));
        assertTrue(dao.isManager(conductor));
    }

    function test_agentConductor_bit_unaffected_by_locks() public {
        // Agent conductor bit (8) is not admin/manager/governor, so locks shouldn't block it
        vm.prank(address(dao));
        dao.lockAdmin();
        vm.prank(address(dao));
        dao.lockManager();
        vm.prank(address(dao));
        dao.lockGovernor();

        // Setting agent conductor (bit 8 only) should still work
        address[] memory addrs = new address[](1);
        addrs[0] = conductor;
        uint256[] memory perms = new uint256[](1);
        perms[0] = 8;

        vm.prank(address(dao));
        dao.setConductors(addrs, perms);
        assertTrue(dao.isAgentConductor(conductor));
    }

    function test_multiple_conductors_batch() public {
        address cond2 = address(0x3);
        address cond3 = address(0x4);

        address[] memory addrs = new address[](3);
        addrs[0] = conductor;
        addrs[1] = cond2;
        addrs[2] = cond3;
        uint256[] memory perms = new uint256[](3);
        perms[0] = 8;  // agent only
        perms[1] = 10; // manager + agent
        perms[2] = 2;  // manager only

        vm.prank(address(dao));
        dao.setConductors(addrs, perms);

        assertTrue(dao.isAgentConductor(conductor));
        assertFalse(dao.isManager(conductor));

        assertTrue(dao.isAgentConductor(cond2));
        assertTrue(dao.isManager(cond2));

        assertFalse(dao.isAgentConductor(cond3));
        assertTrue(dao.isManager(cond3));
    }
}

contract MockSafe {
    function execTransactionFromModule(address, uint256, bytes memory, uint8) external pure returns (bool) {
        return true;
    }
    fallback() external payable {}
    receive() external payable {}
}
