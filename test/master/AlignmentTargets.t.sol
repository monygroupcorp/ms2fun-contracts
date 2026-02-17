// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MasterRegistryV1} from "../../src/master/MasterRegistryV1.sol";
import {IMasterRegistry} from "../../src/master/interfaces/IMasterRegistry.sol";

contract MockVaultForTarget {
    address public alignmentToken;
    constructor(address _token) {
        alignmentToken = _token;
    }
}

contract MockAlignedVault {
    address public alignmentToken;
    constructor(address _token) {
        alignmentToken = _token;
    }
}

contract AlignmentTargetsTest is Test {
    MasterRegistryV1 public registry;
    address public daoOwner = makeAddr("dao");
    address public alice = makeAddr("alice");
    address public cultToken = makeAddr("CULT");
    address public remiliaMultisig = makeAddr("remilia-multisig");
    address public remiliaMultisig2 = makeAddr("remilia-multisig2");

    function setUp() public {
        registry = new MasterRegistryV1();
        registry.initialize(daoOwner);
    }

    function test_RegisterAlignmentTarget_Basic() public {
        IMasterRegistry.AlignmentAsset[] memory assets = new IMasterRegistry.AlignmentAsset[](1);
        assets[0] = IMasterRegistry.AlignmentAsset({
            token: cultToken,
            symbol: "CULT",
            info: "Majority LP in Uniswap V3 pool",
            metadataURI: ""
        });

        vm.prank(daoOwner);
        uint256 targetId = registry.registerAlignmentTarget(
            "Remilia",
            "Cyber yakuza accelerationist cult",
            "https://ms2fun.com/targets/remilia",
            assets
        );

        assertEq(targetId, 1);

        IMasterRegistry.AlignmentTarget memory target = registry.getAlignmentTarget(targetId);
        assertEq(target.title, "Remilia");
        assertTrue(target.active);
        assertGt(target.approvedAt, 0);
    }

    function test_RegisterAlignmentTarget_RevertIfNotOwner() public {
        IMasterRegistry.AlignmentAsset[] memory assets = new IMasterRegistry.AlignmentAsset[](0);

        vm.prank(alice);
        vm.expectRevert("Only owner");
        registry.registerAlignmentTarget("Test", "Test", "https://test.com", assets);
    }

    function test_DeactivateAlignmentTarget() public {
        IMasterRegistry.AlignmentAsset[] memory assets = new IMasterRegistry.AlignmentAsset[](1);
        assets[0] = IMasterRegistry.AlignmentAsset({
            token: cultToken,
            symbol: "CULT",
            info: "",
            metadataURI: ""
        });

        vm.prank(daoOwner);
        uint256 targetId = registry.registerAlignmentTarget("Remilia", "", "", assets);

        vm.prank(daoOwner);
        registry.deactivateAlignmentTarget(targetId);

        assertFalse(registry.isAlignmentTargetActive(targetId));
    }

    function test_DeactivateAlignmentTarget_RevertIfNotOwner() public {
        IMasterRegistry.AlignmentAsset[] memory assets = new IMasterRegistry.AlignmentAsset[](1);
        assets[0] = IMasterRegistry.AlignmentAsset({
            token: cultToken,
            symbol: "CULT",
            info: "",
            metadataURI: ""
        });

        vm.prank(daoOwner);
        uint256 targetId = registry.registerAlignmentTarget("Remilia", "", "", assets);

        vm.prank(alice);
        vm.expectRevert("Only owner");
        registry.deactivateAlignmentTarget(targetId);
    }

    function test_UpdateAlignmentTarget() public {
        IMasterRegistry.AlignmentAsset[] memory assets = new IMasterRegistry.AlignmentAsset[](1);
        assets[0] = IMasterRegistry.AlignmentAsset({
            token: cultToken,
            symbol: "CULT",
            info: "",
            metadataURI: ""
        });

        vm.prank(daoOwner);
        uint256 targetId = registry.registerAlignmentTarget("Remilia", "old desc", "https://old.com", assets);

        vm.prank(daoOwner);
        registry.updateAlignmentTarget(targetId, "new desc", "https://new.com");

        IMasterRegistry.AlignmentTarget memory target = registry.getAlignmentTarget(targetId);
        assertEq(target.description, "new desc");
        assertEq(target.metadataURI, "https://new.com");
    }

    function test_UpdateAlignmentTarget_RevertIfNotOwner() public {
        IMasterRegistry.AlignmentAsset[] memory assets = new IMasterRegistry.AlignmentAsset[](1);
        assets[0] = IMasterRegistry.AlignmentAsset({
            token: cultToken,
            symbol: "CULT",
            info: "",
            metadataURI: ""
        });

        vm.prank(daoOwner);
        uint256 targetId = registry.registerAlignmentTarget("Remilia", "", "", assets);

        vm.prank(alice);
        vm.expectRevert("Only owner");
        registry.updateAlignmentTarget(targetId, "new", "https://new.com");
    }

    // ============ Ambassador Tests ============

    function _createRemiliaTarget() internal returns (uint256) {
        IMasterRegistry.AlignmentAsset[] memory assets = new IMasterRegistry.AlignmentAsset[](1);
        assets[0] = IMasterRegistry.AlignmentAsset({
            token: cultToken,
            symbol: "CULT",
            info: "",
            metadataURI: ""
        });
        vm.prank(daoOwner);
        return registry.registerAlignmentTarget("Remilia", "", "", assets);
    }

    function test_AddAmbassador() public {
        uint256 targetId = _createRemiliaTarget();

        vm.prank(daoOwner);
        registry.addAmbassador(targetId, remiliaMultisig);

        assertTrue(registry.isAmbassador(targetId, remiliaMultisig));

        address[] memory ambassadors = registry.getAmbassadors(targetId);
        assertEq(ambassadors.length, 1);
        assertEq(ambassadors[0], remiliaMultisig);
    }

    function test_AddAmbassador_RevertIfNotOwner() public {
        uint256 targetId = _createRemiliaTarget();

        vm.prank(alice);
        vm.expectRevert("Only owner");
        registry.addAmbassador(targetId, remiliaMultisig);
    }

    function test_RemoveAmbassador() public {
        uint256 targetId = _createRemiliaTarget();

        vm.prank(daoOwner);
        registry.addAmbassador(targetId, remiliaMultisig);

        vm.prank(daoOwner);
        registry.removeAmbassador(targetId, remiliaMultisig);

        assertFalse(registry.isAmbassador(targetId, remiliaMultisig));
    }

    function test_AddMultipleAmbassadors() public {
        uint256 targetId = _createRemiliaTarget();

        vm.prank(daoOwner);
        registry.addAmbassador(targetId, remiliaMultisig);

        vm.prank(daoOwner);
        registry.addAmbassador(targetId, remiliaMultisig2);

        address[] memory ambassadors = registry.getAmbassadors(targetId);
        assertEq(ambassadors.length, 2);
    }

    // ============ Vault Registration with Alignment Target Tests ============

    function test_RegisterVault_WithApprovedTarget() public {
        uint256 targetId = _createRemiliaTarget();

        MockAlignedVault vault = new MockAlignedVault(cultToken);

        vm.prank(daoOwner);
        registry.registerVault(address(vault), "Remilia Vault", "ipfs://test", targetId);

        assertTrue(registry.isVaultRegistered(address(vault)));

        IMasterRegistry.VaultInfo memory info = registry.getVaultInfo(address(vault));
        assertEq(info.targetId, targetId);
    }

    function test_RegisterVault_RevertIfTargetNotApproved() public {
        MockAlignedVault vault = new MockAlignedVault(cultToken);

        vm.prank(daoOwner);
        vm.expectRevert("Target not found");
        registry.registerVault(address(vault), "Bad Vault", "ipfs://test", 999);
    }

    function test_RegisterVault_RevertIfTargetInactive() public {
        uint256 targetId = _createRemiliaTarget();

        vm.prank(daoOwner);
        registry.deactivateAlignmentTarget(targetId);

        MockAlignedVault vault = new MockAlignedVault(cultToken);

        vm.prank(daoOwner);
        vm.expectRevert("Target not active");
        registry.registerVault(address(vault), "Bad Vault", "ipfs://test", targetId);
    }

    function test_RegisterVault_RevertIfTokenNotInTarget() public {
        uint256 targetId = _createRemiliaTarget();

        address wrongToken = makeAddr("WRONG");
        MockAlignedVault vault = new MockAlignedVault(wrongToken);

        vm.prank(daoOwner);
        vm.expectRevert("Token not in target assets");
        registry.registerVault(address(vault), "Bad Vault", "ipfs://test", targetId);
    }
}
