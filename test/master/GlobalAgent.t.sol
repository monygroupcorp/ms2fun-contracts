// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MasterRegistryV1} from "../../src/master/MasterRegistryV1.sol";
import {LibClone} from "solady/utils/LibClone.sol";

contract GlobalAgentTest is Test {
    MasterRegistryV1 public registry;
    address public owner = address(0x1);
    address public agent = address(0x10);
    address public emergencyRevoker = address(0x20);
    address public nobody = address(0x99);

    event AgentUpdated(address indexed agent, bool authorized);
    event EmergencyRevokerSet(address indexed oldRevoker, address indexed newRevoker);

    function setUp() public {
        MasterRegistryV1 impl = new MasterRegistryV1();
        address proxy = LibClone.deployERC1967(address(impl));
        registry = MasterRegistryV1(proxy);
        registry.initialize(owner);

        vm.prank(owner);
        registry.setEmergencyRevoker(emergencyRevoker);
    }

    // ── setAgent ──

    function test_setAgent_by_owner() public {
        vm.prank(owner);
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
        vm.startPrank(owner);
        registry.setAgent(agent, true);
        registry.setAgent(agent, false);
        vm.stopPrank();

        assertFalse(registry.isAgent(agent));
    }

    // ── revokeAgent ──

    function test_revokeAgent_by_emergency_revoker() public {
        vm.prank(owner);
        registry.setAgent(agent, true);

        vm.prank(emergencyRevoker);
        vm.expectEmit(true, false, false, true);
        emit AgentUpdated(agent, false);
        registry.revokeAgent(agent);

        assertFalse(registry.isAgent(agent));
    }

    function test_revokeAgent_reverts_for_non_revoker() public {
        vm.prank(owner);
        registry.setAgent(agent, true);

        vm.prank(nobody);
        vm.expectRevert();
        registry.revokeAgent(agent);
    }

    function test_revokeAgent_reverts_for_owner_without_revoker_role() public {
        vm.prank(owner);
        registry.setAgent(agent, true);

        vm.prank(owner);
        vm.expectRevert();
        registry.revokeAgent(agent);
    }

    // ── setEmergencyRevoker ──

    function test_setEmergencyRevoker_by_owner() public {
        address newRevoker = address(0x30);
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit EmergencyRevokerSet(emergencyRevoker, newRevoker);
        registry.setEmergencyRevoker(newRevoker);

        assertEq(registry.emergencyRevoker(), newRevoker);
    }

    function test_setEmergencyRevoker_reverts_for_non_owner() public {
        vm.prank(nobody);
        vm.expectRevert();
        registry.setEmergencyRevoker(address(0x30));
    }

    function test_setEmergencyRevoker_can_clear_to_zero() public {
        vm.prank(owner);
        registry.setEmergencyRevoker(address(0));
        assertEq(registry.emergencyRevoker(), address(0));
    }

    // ── isAgent ──

    function test_isAgent_false_by_default() public view {
        assertFalse(registry.isAgent(nobody));
    }
}
