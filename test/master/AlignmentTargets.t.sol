// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {AlignmentRegistryV1} from "../../src/master/AlignmentRegistryV1.sol";
import {MasterRegistryV1} from "../../src/master/MasterRegistryV1.sol";
import {IAlignmentRegistry} from "../../src/master/interfaces/IAlignmentRegistry.sol";
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
    AlignmentRegistryV1 public alignmentRegistry;
    MasterRegistryV1 public masterRegistry;
    address public daoOwner = makeAddr("dao");
    address public alice = makeAddr("alice");
    address public cultToken = makeAddr("CULT");
    address public remiliaMultisig = makeAddr("remilia-multisig");
    address public remiliaMultisig2 = makeAddr("remilia-multisig2");

    function setUp() public {
        alignmentRegistry = new AlignmentRegistryV1();
        alignmentRegistry.initialize(daoOwner);

        masterRegistry = new MasterRegistryV1();
        masterRegistry.initialize(daoOwner);

        // Wire alignment registry to master registry
        vm.prank(daoOwner);
        masterRegistry.setAlignmentRegistry(address(alignmentRegistry));
    }

    function test_RegisterAlignmentTarget_Basic() public {
        IAlignmentRegistry.AlignmentAsset[] memory assets = new IAlignmentRegistry.AlignmentAsset[](1);
        assets[0] = IAlignmentRegistry.AlignmentAsset({
            token: cultToken,
            symbol: "CULT",
            info: "Majority LP in Uniswap V3 pool",
            metadataURI: ""
        });

        vm.prank(daoOwner);
        uint256 targetId = alignmentRegistry.registerAlignmentTarget(
            "Remilia",
            "Cyber yakuza accelerationist cult",
            "https://ms2fun.com/targets/remilia",
            assets
        );

        assertEq(targetId, 1);

        IAlignmentRegistry.AlignmentTarget memory target = alignmentRegistry.getAlignmentTarget(targetId);
        assertEq(target.title, "Remilia");
        assertTrue(target.active);
        assertGt(target.approvedAt, 0);
    }

    function test_RegisterAlignmentTarget_RevertIfNotOwner() public {
        IAlignmentRegistry.AlignmentAsset[] memory assets = new IAlignmentRegistry.AlignmentAsset[](0);

        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        alignmentRegistry.registerAlignmentTarget("Test", "Test", "https://test.com", assets);
    }

    function test_DeactivateAlignmentTarget() public {
        IAlignmentRegistry.AlignmentAsset[] memory assets = new IAlignmentRegistry.AlignmentAsset[](1);
        assets[0] = IAlignmentRegistry.AlignmentAsset({
            token: cultToken,
            symbol: "CULT",
            info: "",
            metadataURI: ""
        });

        vm.prank(daoOwner);
        uint256 targetId = alignmentRegistry.registerAlignmentTarget("Remilia", "", "", assets);

        vm.prank(daoOwner);
        alignmentRegistry.deactivateAlignmentTarget(targetId);

        assertFalse(alignmentRegistry.isAlignmentTargetActive(targetId));
    }

    function test_DeactivateAlignmentTarget_RevertIfNotOwner() public {
        IAlignmentRegistry.AlignmentAsset[] memory assets = new IAlignmentRegistry.AlignmentAsset[](1);
        assets[0] = IAlignmentRegistry.AlignmentAsset({
            token: cultToken,
            symbol: "CULT",
            info: "",
            metadataURI: ""
        });

        vm.prank(daoOwner);
        uint256 targetId = alignmentRegistry.registerAlignmentTarget("Remilia", "", "", assets);

        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        alignmentRegistry.deactivateAlignmentTarget(targetId);
    }

    function test_UpdateAlignmentTarget() public {
        IAlignmentRegistry.AlignmentAsset[] memory assets = new IAlignmentRegistry.AlignmentAsset[](1);
        assets[0] = IAlignmentRegistry.AlignmentAsset({
            token: cultToken,
            symbol: "CULT",
            info: "",
            metadataURI: ""
        });

        vm.prank(daoOwner);
        uint256 targetId = alignmentRegistry.registerAlignmentTarget("Remilia", "old desc", "https://old.com", assets);

        vm.prank(daoOwner);
        alignmentRegistry.updateAlignmentTarget(targetId, "new desc", "https://new.com");

        IAlignmentRegistry.AlignmentTarget memory target = alignmentRegistry.getAlignmentTarget(targetId);
        assertEq(target.description, "new desc");
        assertEq(target.metadataURI, "https://new.com");
    }

    function test_UpdateAlignmentTarget_RevertIfNotOwner() public {
        IAlignmentRegistry.AlignmentAsset[] memory assets = new IAlignmentRegistry.AlignmentAsset[](1);
        assets[0] = IAlignmentRegistry.AlignmentAsset({
            token: cultToken,
            symbol: "CULT",
            info: "",
            metadataURI: ""
        });

        vm.prank(daoOwner);
        uint256 targetId = alignmentRegistry.registerAlignmentTarget("Remilia", "", "", assets);

        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        alignmentRegistry.updateAlignmentTarget(targetId, "new", "https://new.com");
    }

    // ============ Ambassador Tests ============

    function _createRemiliaTarget() internal returns (uint256) {
        IAlignmentRegistry.AlignmentAsset[] memory assets = new IAlignmentRegistry.AlignmentAsset[](1);
        assets[0] = IAlignmentRegistry.AlignmentAsset({
            token: cultToken,
            symbol: "CULT",
            info: "",
            metadataURI: ""
        });
        vm.prank(daoOwner);
        return alignmentRegistry.registerAlignmentTarget("Remilia", "", "", assets);
    }

    function test_AddAmbassador() public {
        uint256 targetId = _createRemiliaTarget();

        vm.prank(daoOwner);
        alignmentRegistry.addAmbassador(targetId, remiliaMultisig);

        assertTrue(alignmentRegistry.isAmbassador(targetId, remiliaMultisig));

        address[] memory ambassadors = alignmentRegistry.getAmbassadors(targetId);
        assertEq(ambassadors.length, 1);
        assertEq(ambassadors[0], remiliaMultisig);
    }

    function test_AddAmbassador_RevertIfNotOwner() public {
        uint256 targetId = _createRemiliaTarget();

        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        alignmentRegistry.addAmbassador(targetId, remiliaMultisig);
    }

    function test_RemoveAmbassador() public {
        uint256 targetId = _createRemiliaTarget();

        vm.prank(daoOwner);
        alignmentRegistry.addAmbassador(targetId, remiliaMultisig);

        vm.prank(daoOwner);
        alignmentRegistry.removeAmbassador(targetId, remiliaMultisig);

        assertFalse(alignmentRegistry.isAmbassador(targetId, remiliaMultisig));
    }

    function test_AddMultipleAmbassadors() public {
        uint256 targetId = _createRemiliaTarget();

        vm.prank(daoOwner);
        alignmentRegistry.addAmbassador(targetId, remiliaMultisig);

        vm.prank(daoOwner);
        alignmentRegistry.addAmbassador(targetId, remiliaMultisig2);

        address[] memory ambassadors = alignmentRegistry.getAmbassadors(targetId);
        assertEq(ambassadors.length, 2);
    }

    // ============ Vault Registration with Alignment Target Tests ============

    function test_RegisterVault_WithApprovedTarget() public {
        uint256 targetId = _createRemiliaTarget();

        MockAlignedVault vault = new MockAlignedVault(cultToken);

        vm.prank(daoOwner);
        masterRegistry.registerVault(address(vault), daoOwner, "Remilia Vault", "ipfs://test", targetId);

        assertTrue(masterRegistry.isVaultRegistered(address(vault)));

        IMasterRegistry.VaultInfo memory info = masterRegistry.getVaultInfo(address(vault));
        assertEq(info.targetId, targetId);
    }

    function test_RegisterVault_RevertIfTargetNotApproved() public {
        MockAlignedVault vault = new MockAlignedVault(cultToken);

        vm.prank(daoOwner);
        vm.expectRevert("Target not active");
        masterRegistry.registerVault(address(vault), daoOwner, "Bad Vault", "ipfs://test", 999);
    }

    function test_RegisterVault_RevertIfTargetInactive() public {
        uint256 targetId = _createRemiliaTarget();

        vm.prank(daoOwner);
        alignmentRegistry.deactivateAlignmentTarget(targetId);

        MockAlignedVault vault = new MockAlignedVault(cultToken);

        vm.prank(daoOwner);
        vm.expectRevert("Target not active");
        masterRegistry.registerVault(address(vault), daoOwner, "Bad Vault", "ipfs://test", targetId);
    }

    function test_RegisterVault_RevertIfTokenNotInTarget() public {
        uint256 targetId = _createRemiliaTarget();

        address wrongToken = makeAddr("WRONG");
        MockAlignedVault vault = new MockAlignedVault(wrongToken);

        vm.prank(daoOwner);
        vm.expectRevert("Token not in target assets");
        masterRegistry.registerVault(address(vault), daoOwner, "Bad Vault", "ipfs://test", targetId);
    }
}
