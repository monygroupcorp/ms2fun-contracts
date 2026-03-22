// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DeploySepolia} from "../../script/DeploySepolia.s.sol";
import {CREATEX} from "../../src/shared/CreateXConstants.sol";
import {CREATEX_BYTECODE} from "createx-forge/script/CreateX.d.sol";
import {MasterRegistryV1} from "../../src/master/MasterRegistryV1.sol";
import {IMasterRegistry} from "../../src/master/interfaces/IMasterRegistry.sol";
import {IAlignmentRegistry} from "../../src/master/interfaces/IAlignmentRegistry.sol";

contract DeploySepoliaTest is Test {
    DeploySepolia s;

    function setUp() public {
        vm.etch(CREATEX, CREATEX_BYTECODE);
        s = new DeploySepolia();
        s.deploy(address(s));
    }

    function test_allContractsDeployed() public view {
        assertTrue(s.masterRegistry() != address(0), "masterRegistry");
        assertTrue(address(s.treasury()) != address(0), "treasury");
        assertTrue(address(s.queueManager()) != address(0), "queueManager");
        assertTrue(address(s.globalMessageRegistry()) != address(0), "globalMessageRegistry");
        assertTrue(s.safe() != address(0), "safe");
        assertTrue(address(s.testToken()) != address(0), "testToken");
        assertTrue(address(s.vault()) != address(0), "vault");
        assertTrue(address(s.erc404Factory()) != address(0), "erc404Factory");
        assertTrue(address(s.erc1155Factory()) != address(0), "erc1155Factory");
        assertTrue(address(s.erc721Factory()) != address(0), "erc721Factory");
        assertTrue(address(s.promotionBadges()) != address(0), "promotionBadges");
        assertTrue(address(s.launchManager()) != address(0), "launchManager");
        assertTrue(address(s.curveParamsComputer()) != address(0), "curveParamsComputer");
    }

    function test_masterRegistryProxyInitialized() public view {
        MasterRegistryV1 registry = MasterRegistryV1(s.masterRegistry());
        assertEq(registry.owner(), address(s));
    }

    function test_emergencyRevokerSet() public view {
        MasterRegistryV1 registry = MasterRegistryV1(s.masterRegistry());
        assertEq(registry.emergencyRevoker(), address(s));
    }

    function test_factoriesRegistered() public view {
        MasterRegistryV1 registry = MasterRegistryV1(s.masterRegistry());
        assertTrue(registry.isFactoryRegistered(address(s.erc404Factory())));
        assertTrue(registry.isFactoryRegistered(address(s.erc1155Factory())));
        assertTrue(registry.isFactoryRegistered(address(s.erc721Factory())));
    }

    function test_vaultRegisteredWithCorrectTarget() public view {
        MasterRegistryV1 registry = MasterRegistryV1(s.masterRegistry());
        IMasterRegistry.VaultInfo memory info = registry.getVaultInfo(address(s.vault()));
        assertEq(info.vault, address(s.vault()));
        assertEq(info.targetId, s.alignmentTargetId());
        assertTrue(info.active);
    }

    function test_alignmentTargetCreated() public view {
        IAlignmentRegistry.AlignmentTarget memory target = s.alignmentRegistry().getAlignmentTarget(s.alignmentTargetId());
        assertEq(target.id, s.alignmentTargetId());
        assertTrue(target.active);

        IAlignmentRegistry.AlignmentAsset[] memory assets = s.alignmentRegistry().getAlignmentTargetAssets(s.alignmentTargetId());
        assertEq(assets.length, 1);
        assertEq(assets[0].token, address(s.testToken()));
    }

    function test_factoryWiring() public view {
        assertEq(s.erc404Factory().protocolTreasury(), address(s.treasury()));
        assertEq(s.erc1155Factory().protocolTreasury(), address(s.treasury()));
        assertEq(s.erc721Factory().protocolTreasury(), address(s.treasury()));
    }

    function test_treasuryConfig() public view {
        assertEq(s.treasury().v4PoolManager(), s.SEPOLIA_V4_POOL_MANAGER());
        assertEq(s.treasury().weth(), s.SEPOLIA_WETH());
    }

    function test_promotionBadgesAuthorized() public view {
        assertTrue(s.promotionBadges().authorizedFactories(address(s.launchManager())));
        assertTrue(s.promotionBadges().authorizedFactories(address(s.erc721Factory())));
    }

    function test_erc404LaunchManager_deployed() public view {
        assertTrue(address(s.launchManager()) != address(0), "LaunchManager should be deployed");
    }
}
