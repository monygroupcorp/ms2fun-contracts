// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DeploySepolia} from "../../script/DeploySepolia.s.sol";
import {CREATEX} from "../../src/shared/CreateXConstants.sol";
import {CREATEX_BYTECODE} from "createx-forge/script/CreateX.d.sol";
import {MasterRegistryV1} from "../../src/master/MasterRegistryV1.sol";
import {IMasterRegistry} from "../../src/master/interfaces/IMasterRegistry.sol";
import {IAlignmentRegistry} from "../../src/master/interfaces/IAlignmentRegistry.sol";
import {Currency} from "v4-core/types/Currency.sol";

contract DeploySepoliaTest is Test {
    // Mainnet Lido addresses hardcoded in zRouter constructor
    address constant STETH  = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    // Sepolia LINK — vault init calls the alignment token outside try/catch
    address constant SEPOLIA_LINK = 0x779877A7B0D9E8603169DdbD7836e478b4624789;

    // Minimal stub: returns true (0x01) for any call (satisfies ERC20 approve)
    bytes constant RETURN_TRUE = hex"600160005260206000f3";

    DeploySepolia s;

    function setUp() public {
        vm.etch(CREATEX, CREATEX_BYTECODE);
        vm.etch(STETH,  RETURN_TRUE);
        vm.etch(WSTETH, RETURN_TRUE);
        vm.etch(SEPOLIA_LINK, RETURN_TRUE); // vault init calls alignment token outside try/catch
        // Use unguarded sequential salts so any address can call CreateX in tests
        vm.setEnv("MASTER_REGISTRY_SALT",  vm.toString(bytes32(uint256(1))));
        vm.setEnv("TREASURY_SALT",         vm.toString(bytes32(uint256(2))));
        vm.setEnv("QUEUE_MANAGER_SALT",    vm.toString(bytes32(uint256(3))));
        vm.setEnv("GLOBAL_MSG_REGISTRY_SALT", vm.toString(bytes32(uint256(4))));
        vm.setEnv("ALIGNMENT_REGISTRY_SALT",  vm.toString(bytes32(uint256(5))));
        vm.setEnv("COMPONENT_REGISTRY_SALT",  vm.toString(bytes32(uint256(6))));
        vm.setEnv("VAULT_SALT",            vm.toString(bytes32(uint256(7))));
        s = new DeploySepolia();
        s.deploy(address(s));
    }

    function test_allContractsDeployed() public view {
        assertTrue(s.masterRegistry() != address(0), "masterRegistry");
        assertTrue(address(s.treasury()) != address(0), "treasury");
        assertTrue(address(s.queueManager()) != address(0), "queueManager");
        assertTrue(address(s.globalMessageRegistry()) != address(0), "globalMessageRegistry");
        assertTrue(s.safe() != address(0), "safe");
        assertTrue(s.alignmentToken() != address(0), "alignmentToken");
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
        assertEq(assets[0].token, s.alignmentToken());
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

    function test_v4PoolKeySet() public view {
        (Currency c0, Currency c1, uint24 fee, int24 tickSpacing,) = s.vault().v4PoolKey();
        assertEq(Currency.unwrap(c0), address(0),   "currency0 should be ETH");
        assertEq(Currency.unwrap(c1), SEPOLIA_LINK, "currency1 should be LINK");
        assertEq(fee,         s.ZROUTER_FEE(),          "fee");
        assertEq(tickSpacing, s.ZROUTER_TICK_SPACING(), "tickSpacing");
    }
}
