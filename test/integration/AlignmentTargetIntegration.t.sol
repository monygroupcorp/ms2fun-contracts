// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MasterRegistryV1} from "../../src/master/MasterRegistryV1.sol";
import {IMasterRegistry} from "../../src/master/interfaces/IMasterRegistry.sol";

contract MockAlignedVaultIntegration {
    address public alignmentToken;
    constructor(address _token) {
        alignmentToken = _token;
    }
}

contract MockFactoryIntegration {
    address public creator;
    address public protocol;
    constructor(address _creator, address _protocol) {
        creator = _creator;
        protocol = _protocol;
    }
}

/**
 * @notice End-to-end test: DAO approves target -> vault deployed -> instances registered
 */
contract AlignmentTargetIntegrationTest is Test {
    MasterRegistryV1 public registry;
    address public daoOwner = makeAddr("dao");
    address public vaultDev = makeAddr("vaultDev");
    address public artist = makeAddr("artist");
    address public cultToken = makeAddr("CULT");
    address public remiliaMultisig = makeAddr("remilia");

    function setUp() public {
        registry = new MasterRegistryV1();
        registry.initialize(daoOwner);
    }

    function test_FullLifecycle() public {
        // 1. DAO approves Remilia as alignment target
        IMasterRegistry.AlignmentAsset[] memory assets = new IMasterRegistry.AlignmentAsset[](1);
        assets[0] = IMasterRegistry.AlignmentAsset({
            token: cultToken,
            symbol: "CULT",
            info: "Majority LP in Uniswap V3",
            metadataURI: ""
        });

        vm.prank(daoOwner);
        uint256 targetId = registry.registerAlignmentTarget(
            "Remilia",
            "Cyber yakuza accelerationist cult",
            "https://ms2fun.com/targets/remilia",
            assets
        );

        // 2. Anyone deploys a vault for Remilia
        MockAlignedVaultIntegration vault = new MockAlignedVaultIntegration(cultToken);

        vm.prank(daoOwner);
        registry.registerVault(address(vault), "Remilia Ultra Vault", "ipfs://vault", targetId);

        assertTrue(registry.isVaultRegistered(address(vault)));

        // 3. Verify vault is linked to target
        IMasterRegistry.VaultInfo memory vInfo = registry.getVaultInfo(address(vault));
        assertEq(vInfo.targetId, targetId);

        // 4. Remilia connects - DAO adds ambassador
        vm.prank(daoOwner);
        registry.addAmbassador(targetId, remiliaMultisig);
        assertTrue(registry.isAmbassador(targetId, remiliaMultisig));

        // 5. Verify target profile
        IMasterRegistry.AlignmentTarget memory target = registry.getAlignmentTarget(targetId);
        assertEq(target.title, "Remilia");
        assertTrue(target.active);

        // 6. DAO can update target metadata
        vm.prank(daoOwner);
        registry.updateAlignmentTarget(targetId, "Updated description", "https://ms2fun.com/targets/remilia/v2");

        target = registry.getAlignmentTarget(targetId);
        assertEq(target.description, "Updated description");
    }

    function test_CannotRegisterVaultForUnapprovedTarget() public {
        MockAlignedVaultIntegration vault = new MockAlignedVaultIntegration(cultToken);

        vm.prank(daoOwner);
        vm.expectRevert("Target not found");
        registry.registerVault(address(vault), "Bad Vault", "ipfs://bad", 1);
    }

    function test_MultipleVaultsPerTarget() public {
        IMasterRegistry.AlignmentAsset[] memory assets = new IMasterRegistry.AlignmentAsset[](1);
        assets[0] = IMasterRegistry.AlignmentAsset({
            token: cultToken,
            symbol: "CULT",
            info: "",
            metadataURI: ""
        });

        vm.prank(daoOwner);
        uint256 targetId = registry.registerAlignmentTarget("Remilia", "", "", assets);

        MockAlignedVaultIntegration vault1 = new MockAlignedVaultIntegration(cultToken);
        MockAlignedVaultIntegration vault2 = new MockAlignedVaultIntegration(cultToken);

        vm.prank(daoOwner);
        registry.registerVault(address(vault1), "Remilia Vault 1", "ipfs://1", targetId);

        vm.prank(daoOwner);
        registry.registerVault(address(vault2), "Remilia Vault 2", "ipfs://2", targetId);

        assertTrue(registry.isVaultRegistered(address(vault1)));
        assertTrue(registry.isVaultRegistered(address(vault2)));
    }
}
