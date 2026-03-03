// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ComponentRegistry} from "../../src/registry/ComponentRegistry.sol";
import {IComponentRegistry} from "../../src/registry/interfaces/IComponentRegistry.sol";

contract ComponentRegistryTest is Test {
    ComponentRegistry public impl;
    ComponentRegistry public registry;

    address public owner   = address(0xDA0);
    address public module1 = address(0xAA1);
    address public module2 = address(0xAA2);
    address public module3 = address(0xAA3);
    address public stranger = address(0xBEEF);

    bytes32 public GATING_TAG = keccak256("gating");
    bytes32 public OTHER_TAG  = keccak256("other");

    function setUp() public {
        impl = new ComponentRegistry();
        address proxy = LibClone.deployERC1967(address(impl));
        registry = ComponentRegistry(proxy);
        registry.initialize(owner);
    }

    // ── Initialization ─────────────────────────────────────────────────────────

    function test_initialize_setsOwner() public {
        assertEq(registry.owner(), owner);
    }

    function test_initialize_revertsOnDoubleInit() public {
        vm.expectRevert(Ownable.AlreadyInitialized.selector);
        registry.initialize(owner);
    }

    function test_initialize_revertsOnZeroOwner() public {
        address newImpl = address(new ComponentRegistry());
        address proxy = LibClone.deployERC1967(newImpl);
        ComponentRegistry r = ComponentRegistry(proxy);
        vm.expectRevert(ComponentRegistry.InvalidAddress.selector);
        r.initialize(address(0));
    }

    // ── approveComponent ──────────────────────────────────────────────────────

    function test_approveComponent_setsState() public {
        vm.prank(owner);
        registry.approveComponent(module1, GATING_TAG, "PasswordTierGating");

        assertTrue(registry.isApproved(module1));
        assertEq(registry.componentTag(module1), GATING_TAG);
        assertEq(registry.componentName(module1), "PasswordTierGating");
    }

    function test_approveComponent_emitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit IComponentRegistry.ComponentApproved(module1, GATING_TAG, "PasswordTierGating");
        vm.prank(owner);
        registry.approveComponent(module1, GATING_TAG, "PasswordTierGating");
    }

    function test_approveComponent_revertsOnDuplicate() public {
        vm.prank(owner);
        registry.approveComponent(module1, GATING_TAG, "PasswordTierGating");
        vm.prank(owner);
        vm.expectRevert(ComponentRegistry.AlreadyApproved.selector);
        registry.approveComponent(module1, GATING_TAG, "PasswordTierGating");
    }

    function test_approveComponent_revertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(ComponentRegistry.InvalidAddress.selector);
        registry.approveComponent(address(0), GATING_TAG, "Bad");
    }

    function test_approveComponent_revertsIfNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        registry.approveComponent(module1, GATING_TAG, "PasswordTierGating");
    }

    // ── revokeComponent ───────────────────────────────────────────────────────

    function test_revokeComponent_clearsApproval() public {
        vm.prank(owner);
        registry.approveComponent(module1, GATING_TAG, "PasswordTierGating");
        vm.prank(owner);
        registry.revokeComponent(module1);

        assertFalse(registry.isApproved(module1));
    }

    function test_revokeComponent_emitsEvent() public {
        vm.prank(owner);
        registry.approveComponent(module1, GATING_TAG, "PasswordTierGating");

        vm.expectEmit(true, false, false, false);
        emit IComponentRegistry.ComponentRevoked(module1);
        vm.prank(owner);
        registry.revokeComponent(module1);
    }

    function test_revokeComponent_revertsIfNotApproved() public {
        vm.prank(owner);
        vm.expectRevert(ComponentRegistry.NotApproved.selector);
        registry.revokeComponent(module1);
    }

    function test_revokeComponent_revertsIfNotOwner() public {
        vm.prank(owner);
        registry.approveComponent(module1, GATING_TAG, "PasswordTierGating");
        vm.prank(stranger);
        vm.expectRevert();
        registry.revokeComponent(module1);
    }

    // ── isApprovedComponent ───────────────────────────────────────────────────

    function test_isApprovedComponent_trueAfterApprove() public {
        vm.prank(owner);
        registry.approveComponent(module1, GATING_TAG, "PasswordTierGating");
        assertTrue(registry.isApprovedComponent(module1));
    }

    function test_isApprovedComponent_falseAfterRevoke() public {
        vm.prank(owner);
        registry.approveComponent(module1, GATING_TAG, "PasswordTierGating");
        vm.prank(owner);
        registry.revokeComponent(module1);
        assertFalse(registry.isApprovedComponent(module1));
    }

    function test_isApprovedComponent_falseForUnknown() public {
        assertFalse(registry.isApprovedComponent(module1));
    }

    // ── getApprovedComponents ─────────────────────────────────────────────────

    function test_getApprovedComponents_returnsAll() public {
        vm.startPrank(owner);
        registry.approveComponent(module1, GATING_TAG, "Mod1");
        registry.approveComponent(module2, OTHER_TAG, "Mod2");
        vm.stopPrank();

        address[] memory result = registry.getApprovedComponents();
        assertEq(result.length, 2);
    }

    function test_getApprovedComponents_excludesRevoked() public {
        vm.startPrank(owner);
        registry.approveComponent(module1, GATING_TAG, "Mod1");
        registry.approveComponent(module2, OTHER_TAG, "Mod2");
        registry.revokeComponent(module1);
        vm.stopPrank();

        address[] memory result = registry.getApprovedComponents();
        assertEq(result.length, 1);
        assertEq(result[0], module2);
    }

    function test_getApprovedComponents_emptyInitially() public {
        address[] memory result = registry.getApprovedComponents();
        assertEq(result.length, 0);
    }

    // ── getApprovedComponentsByTag ────────────────────────────────────────────

    function test_getApprovedComponentsByTag_filtersByTag() public {
        vm.startPrank(owner);
        registry.approveComponent(module1, GATING_TAG, "Gating1");
        registry.approveComponent(module2, GATING_TAG, "Gating2");
        registry.approveComponent(module3, OTHER_TAG,  "Other1");
        vm.stopPrank();

        address[] memory gating = registry.getApprovedComponentsByTag(GATING_TAG);
        assertEq(gating.length, 2);

        address[] memory other = registry.getApprovedComponentsByTag(OTHER_TAG);
        assertEq(other.length, 1);
        assertEq(other[0], module3);
    }

    function test_getApprovedComponentsByTag_excludesRevoked() public {
        vm.startPrank(owner);
        registry.approveComponent(module1, GATING_TAG, "Gating1");
        registry.approveComponent(module2, GATING_TAG, "Gating2");
        registry.revokeComponent(module1);
        vm.stopPrank();

        address[] memory gating = registry.getApprovedComponentsByTag(GATING_TAG);
        assertEq(gating.length, 1);
        assertEq(gating[0], module2);
    }

    // ── Upgradeability ────────────────────────────────────────────────────────

    function test_upgradeAuthorization_revertsIfNotOwner() public {
        address newImpl = address(new ComponentRegistry());
        vm.expectRevert();
        registry.upgradeToAndCall(newImpl, "");
    }

    function test_upgradeAuthorization_succeedsAsOwner() public {
        address newImpl = address(new ComponentRegistry());
        vm.prank(owner);
        registry.upgradeToAndCall(newImpl, "");
        assertEq(registry.owner(), owner);
    }
}
