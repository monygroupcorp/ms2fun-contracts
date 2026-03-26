// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DeployCore} from "../../script/DeployCore.sol";
import {CREATEX} from "../../src/shared/CreateXConstants.sol";
import {CREATEX_BYTECODE} from "createx-forge/script/CreateX.d.sol";
import {MasterRegistryV1} from "../../src/master/MasterRegistryV1.sol";
import {IMasterRegistry} from "../../src/master/interfaces/IMasterRegistry.sol";
import {IAlignmentRegistry} from "../../src/master/interfaces/IAlignmentRegistry.sol";
import {LaunchManager} from "../../src/factories/erc404/LaunchManager.sol";
import {QueryAggregator} from "../../src/query/QueryAggregator.sol";
import {Currency} from "v4-core/types/Currency.sol";

contract DeployCoreTest is Test {
    address constant STETH  = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant STUB_LINK = 0x779877A7B0D9E8603169DdbD7836e478b4624789;

    bytes constant RETURN_TRUE = hex"600160005260206000f3";

    DeployCore s;

    function setUp() public {
        vm.etch(CREATEX, CREATEX_BYTECODE);
        vm.etch(STETH,     RETURN_TRUE);
        vm.etch(WSTETH,    RETURN_TRUE);
        vm.etch(STUB_LINK, RETURN_TRUE);

        s = new DeployCore();
        s.deploy(address(s), _testConfig());
    }

    // Build a minimal but complete NetworkConfig for tests.
    // Uses sequential unguarded salts so any address can call CreateX.
    // jsonOutputPath is empty — no file I/O in tests.
    function _testConfig() internal returns (DeployCore.NetworkConfig memory cfg) {
        DeployCore.AlignmentTargetConfig[] memory targets =
            new DeployCore.AlignmentTargetConfig[](1);
        targets[0] = DeployCore.AlignmentTargetConfig({
            token:             STUB_LINK,
            symbol:            "LINK",
            name:              "Chainlink",
            description:       "Test alignment target",
            deployUniVault:    true,
            deployCypherVault: false,
            deployZAMMVault:   false
        });

        cfg.chainId             = 1337;
        cfg.weth                = STUB_LINK; // reuse stub — vault init calls it
        cfg.v4PoolManager       = address(1); // non-zero stub — vault init rejects address(0)
        cfg.v3Factory           = address(0);
        cfg.v2Factory           = address(0);
        cfg.cypherPositionManager = address(0);
        cfg.cypherRouter        = address(0);
        cfg.zamm                = address(0);
        cfg.zrouter             = address(0);
        cfg.safe                = address(0);
        cfg.saltMasterRegistry  = bytes32(uint256(1));
        cfg.saltTreasury        = bytes32(uint256(2));
        cfg.saltQueueManager    = bytes32(uint256(3));
        cfg.saltGlobalMsgReg    = bytes32(uint256(4));
        cfg.saltAlignmentReg    = bytes32(uint256(5));
        cfg.saltComponentReg    = bytes32(uint256(6));
        cfg.priceDeviationBps   = 1000;
        cfg.twapSeconds         = 1800;
        cfg.zrouterFee          = 3000;
        cfg.zrouterTickSpacing  = 60;
        cfg.alignmentTargets    = targets;
        cfg.jsonOutputPath      = ""; // empty = skip write
    }

    // ── Core registry ──────────────────────────────────────────────

    function test_allCoreContractsDeployed() public view {
        assertTrue(s.masterRegistry()           != address(0), "masterRegistry");
        assertTrue(address(s.treasury())        != address(0), "treasury");
        assertTrue(address(s.queueManager())    != address(0), "queueManager");
        assertTrue(address(s.globalMessageRegistry()) != address(0), "gmr");
        assertTrue(address(s.alignmentRegistry()) != address(0), "alignmentReg");
        assertTrue(address(s.componentRegistry()) != address(0), "componentReg");
        assertTrue(s.safe()                     != address(0), "safe");
        assertTrue(address(s.zrouter())         != address(0), "zrouter");
    }

    function test_allFactoryContractsDeployed() public view {
        assertTrue(address(s.erc404Factory())   != address(0), "erc404Factory");
        assertTrue(address(s.erc1155Factory())  != address(0), "erc1155Factory");
        assertTrue(address(s.erc721Factory())   != address(0), "erc721Factory");
        assertTrue(address(s.launchManager())   != address(0), "launchManager");
        assertTrue(address(s.curveParamsComputer()) != address(0), "curveComputer");
        assertTrue(address(s.dynamicPricingModule()) != address(0), "dynPricing");
        assertTrue(address(s.queryAggregator()) != address(0), "queryAgg");
        assertTrue(address(s.priceValidator())  != address(0), "priceValidator");
    }

    function test_masterRegistryOwner() public view {
        assertEq(MasterRegistryV1(s.masterRegistry()).owner(), address(s));
    }

    function test_emergencyRevokerSet() public view {
        assertEq(MasterRegistryV1(s.masterRegistry()).emergencyRevoker(), address(s));
    }

    function test_allThreeFactoriesRegistered() public view {
        assertEq(MasterRegistryV1(s.masterRegistry()).getTotalFactories(), 3);
    }

    function test_factoryTreasuryWiring() public view {
        assertEq(s.erc404Factory().protocolTreasury(),  address(s.treasury()));
        assertEq(s.erc1155Factory().protocolTreasury(), address(s.treasury()));
        assertEq(s.erc721Factory().protocolTreasury(),  address(s.treasury()));
    }

    function test_alignmentTargetRegistered() public view {
        IAlignmentRegistry.AlignmentTarget memory target =
            s.alignmentRegistry().getAlignmentTarget(s.alignmentTargetIds(0));
        assertEq(target.id, s.alignmentTargetIds(0));
        assertTrue(target.active);
    }

    function test_vaultRegistered() public view {
        IMasterRegistry.VaultInfo memory info =
            MasterRegistryV1(s.masterRegistry()).getVaultInfo(s.uniVaults(0));
        assertEq(info.vault,    s.uniVaults(0));
        assertEq(info.targetId, s.alignmentTargetIds(0));
        assertTrue(info.active);
    }

    function test_queryAggregatorInitialized() public view {
        assertEq(address(s.queryAggregator().masterRegistry()), s.masterRegistry());
    }

    function test_launchManagerPreset1Active() public view {
        LaunchManager.Preset memory p = s.launchManager().getPreset(1);
        assertTrue(p.active);
        assertEq(p.targetETH, 25 ether);
    }

    function test_dynamicPricingModuleWired() public view {
        assertEq(s.erc1155Factory().dynamicPricingModule(), address(s.dynamicPricingModule()));
    }

    function test_treasuryConfig() public view {
        assertTrue(address(s.treasury()) != address(0));
    }
}
