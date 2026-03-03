// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MasterRegistryV1} from "../../src/master/MasterRegistryV1.sol";
import {GrandCentral} from "../../src/dao/GrandCentral.sol";
import {LibClone} from "solady/utils/LibClone.sol";

contract MockSafe {
    function execTransactionFromModule(address, uint256, bytes memory, uint8) external pure returns (bool) {
        return true;
    }
    fallback() external payable {}
    receive() external payable {}
}

contract GlobalAgentTest is Test {
    MasterRegistryV1 public registry;
    GrandCentral public dao;
    address public daoOwner = address(0x1);
    address public agent = address(0x10);
    address public agentConductor = address(0x20);
    address public nobody = address(0x99);

    event AgentUpdated(address indexed agent, bool authorized);

    function setUp() public {
        // Deploy registry via proxy pattern
        MasterRegistryV1 impl = new MasterRegistryV1();
        address proxy = LibClone.deployERC1967(address(impl));
        registry = MasterRegistryV1(proxy);
        registry.initialize(daoOwner);

        // Deploy GrandCentral
        address safe = address(new MockSafe());
        dao = new GrandCentral(safe, daoOwner, 100, 1 days, 1 days, 51, 10, 50);

        // Set GrandCentral on registry
        vm.prank(daoOwner);
        registry.setGrandCentral(address(dao));

        // Grant agentConductor permission (bit 8)
        address[] memory addrs = new address[](1);
        addrs[0] = agentConductor;
        uint256[] memory perms = new uint256[](1);
        perms[0] = 8;
        vm.prank(address(dao));
        dao.setConductors(addrs, perms);
    }

    // ── setAgent ──

    function test_setAgent_by_owner() public {
        vm.prank(daoOwner);
        vm.expectEmit(true, false, false, true);
        emit AgentUpdated(agent, true);
        registry.setAgent(agent, true);

        assertTrue(registry.isAgent(agent));
    }

    function test_setAgent_reverts_for_non_owner() public {
        vm.prank(nobody);
        vm.expectRevert();
        registry.setAgent(agent, true);
    }

    function test_setAgent_can_disable() public {
        vm.startPrank(daoOwner);
        registry.setAgent(agent, true);
        registry.setAgent(agent, false);
        vm.stopPrank();

        assertFalse(registry.isAgent(agent));
    }

    // ── revokeAgent ──

    function test_revokeAgent_by_agent_conductor() public {
        vm.prank(daoOwner);
        registry.setAgent(agent, true);

        vm.prank(agentConductor);
        vm.expectEmit(true, false, false, true);
        emit AgentUpdated(agent, false);
        registry.revokeAgent(agent);

        assertFalse(registry.isAgent(agent));
    }

    function test_revokeAgent_reverts_for_non_conductor() public {
        vm.prank(daoOwner);
        registry.setAgent(agent, true);

        vm.prank(nobody);
        vm.expectRevert();
        registry.revokeAgent(agent);
    }

    function test_revokeAgent_reverts_for_owner_without_conductor_role() public {
        vm.prank(daoOwner);
        registry.setAgent(agent, true);

        // Owner alone cannot use revokeAgent (must use setAgent instead)
        vm.prank(daoOwner);
        vm.expectRevert();
        registry.revokeAgent(agent);
    }

    // ── isAgent ──

    function test_isAgent_false_by_default() public view {
        assertFalse(registry.isAgent(nobody));
    }

    // ── setGrandCentral ──

    function test_setGrandCentral_reverts_for_non_owner() public {
        vm.prank(nobody);
        vm.expectRevert();
        registry.setGrandCentral(address(dao));
    }

    function test_setGrandCentral_reverts_zero_address() public {
        vm.prank(daoOwner);
        vm.expectRevert();
        registry.setGrandCentral(address(0));
    }
}
