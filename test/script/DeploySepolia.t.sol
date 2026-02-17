// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DeploySepolia} from "../../script/DeploySepolia.s.sol";
import {MasterRegistryV1} from "../../src/master/MasterRegistryV1.sol";
import {IMasterRegistry} from "../../src/master/interfaces/IMasterRegistry.sol";

contract DeploySepoliaTest is Test {
    DeploySepolia s;

    function setUp() public {
        s = new DeploySepolia();
        // deploy() creates all contracts with msg.sender = address(s)
        // so all ownership goes to the DeploySepolia contract
        s.deploy(address(s));
    }

    function test_allContractsDeployed() public view {
        assertTrue(s.masterRegistry() != address(0), "masterRegistry");
        assertTrue(address(s.treasury()) != address(0), "treasury");
        assertTrue(address(s.queueManager()) != address(0), "queueManager");
        assertTrue(address(s.globalMessageRegistry()) != address(0), "globalMessageRegistry");
        assertTrue(address(s.dao()) != address(0), "dao");
        assertTrue(address(s.shareOffering()) != address(0), "shareOffering");
        assertTrue(address(s.stipendConductor()) != address(0), "stipendConductor");
        assertTrue(s.safe() != address(0), "safe");
        assertTrue(address(s.testToken()) != address(0), "testToken");
        assertTrue(address(s.vault()) != address(0), "vault");
        assertTrue(address(s.erc404Factory()) != address(0), "erc404Factory");
        assertTrue(address(s.erc1155Factory()) != address(0), "erc1155Factory");
        assertTrue(address(s.erc721Factory()) != address(0), "erc721Factory");
        assertTrue(address(s.promotionBadges()) != address(0), "promotionBadges");
    }

    function test_masterRegistryProxyInitialized() public view {
        MasterRegistryV1 registry = MasterRegistryV1(s.masterRegistry());
        // Owner is deployer param passed to deploy(), which is address(s)
        assertEq(registry.owner(), address(s));
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
        MasterRegistryV1 registry = MasterRegistryV1(s.masterRegistry());
        IMasterRegistry.AlignmentTarget memory target = registry.getAlignmentTarget(s.alignmentTargetId());
        assertEq(target.id, s.alignmentTargetId());
        assertTrue(target.active);

        IMasterRegistry.AlignmentAsset[] memory assets = registry.getAlignmentTargetAssets(s.alignmentTargetId());
        assertEq(assets.length, 1);
        assertEq(assets[0].token, address(s.testToken()));
    }

    function test_factoryWiring() public view {
        // ERC404Factory
        assertEq(s.erc404Factory().protocolTreasury(), address(s.treasury()));
        assertEq(address(s.erc404Factory().promotionBadges()), address(s.promotionBadges()));
        assertEq(address(s.erc404Factory().featuredQueueManager()), address(s.queueManager()));

        // ERC1155Factory
        assertEq(s.erc1155Factory().protocolTreasury(), address(s.treasury()));
        assertEq(address(s.erc1155Factory().promotionBadges()), address(s.promotionBadges()));
        assertEq(address(s.erc1155Factory().featuredQueueManager()), address(s.queueManager()));

        // ERC721AuctionFactory
        assertEq(s.erc721Factory().protocolTreasury(), address(s.treasury()));
        assertEq(address(s.erc721Factory().promotionBadges()), address(s.promotionBadges()));
        assertEq(address(s.erc721Factory().featuredQueueManager()), address(s.queueManager()));
    }

    function test_masterRegistryWiring() public view {
        MasterRegistryV1 registry = MasterRegistryV1(s.masterRegistry());
        assertEq(registry.getGlobalMessageRegistry(), address(s.globalMessageRegistry()));
        assertEq(registry.featuredQueueManager(), address(s.queueManager()));
    }

    function test_daoConfig() public view {
        assertEq(s.dao().votingPeriod(), 1 days);
        assertEq(s.dao().gracePeriod(), 1 days);
    }

    function test_treasuryConfig() public view {
        assertEq(s.treasury().v4PoolManager(), s.SEPOLIA_V4_POOL_MANAGER());
        assertEq(s.treasury().weth(), s.SEPOLIA_WETH());
    }

    function test_promotionBadgesAuthorized() public view {
        assertTrue(s.promotionBadges().authorizedFactories(address(s.erc404Factory())));
        assertTrue(s.promotionBadges().authorizedFactories(address(s.erc1155Factory())));
        assertTrue(s.promotionBadges().authorizedFactories(address(s.erc721Factory())));
    }

    function test_erc404GraduationProfile() public view {
        (uint256 targetETH, uint256 unitPerNFT, uint24 poolFee, int24 tickSpacing, uint256 liquidityReserveBps, bool active) =
            s.erc404Factory().profiles(1);
        assertEq(targetETH, 15 ether);
        assertEq(unitPerNFT, 1_000_000);
        assertEq(poolFee, 3000);
        assertEq(tickSpacing, 60);
        assertEq(liquidityReserveBps, 1000);
        assertTrue(active);
    }
}
