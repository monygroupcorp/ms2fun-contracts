// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IFactory} from "../../src/interfaces/IFactory.sol";
import {FeatureUtils} from "../../src/master/libraries/FeatureUtils.sol";

// Factories under test
import {ERC404Factory} from "../../src/factories/erc404/ERC404Factory.sol";
import {ERC404ZAMMFactory} from "../../src/factories/erc404zamm/ERC404ZAMMFactory.sol";
import {ERC404CypherFactory} from "../../src/factories/erc404cypher/ERC404CypherFactory.sol";
import {ERC1155Factory} from "../../src/factories/erc1155/ERC1155Factory.sol";
import {ERC721AuctionFactory} from "../../src/factories/erc721/ERC721AuctionFactory.sol";

// Supporting contracts needed to construct factories
import {ERC404BondingInstance} from "../../src/factories/erc404/ERC404BondingInstance.sol";
import {ERC404StakingModule} from "../../src/factories/erc404/ERC404StakingModule.sol";
import {LaunchManager} from "../../src/factories/erc404/LaunchManager.sol";
import {CurveParamsComputer} from "../../src/factories/erc404/CurveParamsComputer.sol";
import {ERC404ZAMMBondingInstance} from "../../src/factories/erc404zamm/ERC404ZAMMBondingInstance.sol";
import {ZAMMLiquidityDeployerModule} from "../../src/factories/erc404zamm/ZAMMLiquidityDeployerModule.sol";
import {ERC404CypherBondingInstance} from "../../src/factories/erc404cypher/ERC404CypherBondingInstance.sol";
import {CypherLiquidityDeployerModule} from "../../src/factories/erc404cypher/CypherLiquidityDeployerModule.sol";
import {CypherAlignmentVault} from "../../src/vaults/cypher/CypherAlignmentVault.sol";
import {CypherAlignmentVaultFactory} from "../../src/vaults/cypher/CypherAlignmentVaultFactory.sol";
import {PasswordTierGatingModule} from "../../src/gating/PasswordTierGatingModule.sol";
import {ComponentRegistry} from "../../src/registry/ComponentRegistry.sol";
import {MockZAMM} from "../mocks/MockZAMM.sol";
import {MockWETH} from "../mocks/MockWETH.sol";
import {MockAlgebraFactory, MockAlgebraPositionManager, MockAlgebraSwapRouter} from "../mocks/MockCypherAlgebra.sol";
import {MockMasterRegistry} from "../mocks/MockMasterRegistry.sol";
import {LibClone} from "solady/utils/LibClone.sol";

// Minimal mock for staking registry (used by ERC404StakingModule)
contract MockStakingRegistry {
    function isRegisteredInstance(address) external pure returns (bool) { return false; }
}

/// @title FactoryFeaturesTest
/// @notice Verifies that every factory implements IFactory.features() correctly and
///         that each factory returns the FeatureUtils.GATING tag (or an empty array
///         for ERC721AuctionFactory which has no pluggable components).
contract FactoryFeaturesTest is Test {
    address protocol = makeAddr("protocol");

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _hasGating(bytes32[] memory arr) internal pure returns (bool) {
        for (uint256 i; i < arr.length; i++) {
            if (arr[i] == FeatureUtils.GATING) return true;
        }
        return false;
    }

    function _deployComponentRegistry() internal returns (ComponentRegistry) {
        ComponentRegistry impl = new ComponentRegistry();
        address proxy = LibClone.deployERC1967(address(impl));
        ComponentRegistry reg = ComponentRegistry(proxy);
        reg.initialize(protocol);
        return reg;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // FeatureUtils.GATING constant
    // ─────────────────────────────────────────────────────────────────────────

    function test_FeatureUtils_GATING_equals_keccak_gating() public pure {
        assertEq(FeatureUtils.GATING, keccak256("gating"));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ERC404Factory
    // ─────────────────────────────────────────────────────────────────────────

    function test_ERC404Factory_features_returnsArrayViaInterface() public {
        vm.startPrank(protocol);

        MockStakingRegistry stakingReg = new MockStakingRegistry();
        ERC404StakingModule stakingModule = new ERC404StakingModule(address(stakingReg));
        LaunchManager launchMgr = new LaunchManager(protocol);
        CurveParamsComputer curveComp = new CurveParamsComputer(protocol);
        ComponentRegistry compReg = _deployComponentRegistry();
        ERC404BondingInstance impl = new ERC404BondingInstance();

        ERC404Factory factory = new ERC404Factory(
            ERC404Factory.CoreConfig({
                implementation: address(impl),
                masterRegistry: makeAddr("mr"),
                instanceTemplate: makeAddr("tmpl"),
                v4PoolManager: makeAddr("pm"),
                weth: makeAddr("weth"),
                protocol: protocol
            }),
            ERC404Factory.ModuleConfig({
                stakingModule: address(stakingModule),
                liquidityDeployer: makeAddr("ld"),
                globalMessageRegistry: makeAddr("gmr"),
                launchManager: address(launchMgr),
                curveComputer: address(curveComp),
                tierGatingModule: address(0),
                componentRegistry: address(compReg)
            })
        );

        vm.stopPrank();

        bytes32[] memory feats = IFactory(address(factory)).features();
        assertTrue(_hasGating(feats), "ERC404Factory: GATING tag missing from features()");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ERC404ZAMMFactory
    // ─────────────────────────────────────────────────────────────────────────

    function test_ERC404ZAMMFactory_features_returnsArrayViaInterface() public {
        MockZAMM zamm = new MockZAMM();
        ZAMMLiquidityDeployerModule deployer = new ZAMMLiquidityDeployerModule();
        ERC404ZAMMBondingInstance impl = new ERC404ZAMMBondingInstance();
        CurveParamsComputer curveComp = new CurveParamsComputer(protocol);
        PasswordTierGatingModule tierGating = new PasswordTierGatingModule();
        ComponentRegistry compReg = _deployComponentRegistry();

        ERC404ZAMMFactory factory = new ERC404ZAMMFactory(
            ERC404ZAMMFactory.CoreConfig({
                implementation: address(impl),
                masterRegistry: makeAddr("mr"),
                zamm: address(zamm),
                zRouter: address(0),
                feeOrHook: 30,
                protocol: protocol
            }),
            ERC404ZAMMFactory.ModuleConfig({
                globalMessageRegistry: makeAddr("gmr"),
                curveComputer: address(curveComp),
                liquidityDeployer: address(deployer),
                tierGatingModule: address(tierGating),
                componentRegistry: address(compReg)
            })
        );

        bytes32[] memory feats = IFactory(address(factory)).features();
        assertTrue(_hasGating(feats), "ERC404ZAMMFactory: GATING tag missing from features()");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ERC404CypherFactory
    // ─────────────────────────────────────────────────────────────────────────

    function test_ERC404CypherFactory_features_returnsArrayViaInterface() public {
        ERC404CypherBondingInstance impl = new ERC404CypherBondingInstance();
        CypherLiquidityDeployerModule deployer = new CypherLiquidityDeployerModule();
        CypherAlignmentVault vaultImpl = new CypherAlignmentVault();
        CypherAlignmentVaultFactory vaultFactory = new CypherAlignmentVaultFactory(address(vaultImpl));
        CurveParamsComputer curveComp = new CurveParamsComputer(protocol);
        PasswordTierGatingModule tierGating = new PasswordTierGatingModule();
        MockAlgebraFactory algebraFactory = new MockAlgebraFactory();
        MockAlgebraPositionManager positionManager = new MockAlgebraPositionManager();
        MockAlgebraSwapRouter swapRouter = new MockAlgebraSwapRouter();
        MockWETH weth = new MockWETH();
        ComponentRegistry compReg = _deployComponentRegistry();

        ERC404CypherFactory factory = new ERC404CypherFactory(
            ERC404CypherFactory.CoreConfig({
                implementation: address(impl),
                masterRegistry: makeAddr("mr"),
                vaultFactory: address(vaultFactory),
                liquidityDeployer: address(deployer),
                algebraFactory: address(algebraFactory),
                positionManager: address(positionManager),
                swapRouter: address(swapRouter),
                weth: address(weth),
                protocol: protocol
            }),
            ERC404CypherFactory.ModuleConfig({
                globalMessageRegistry: makeAddr("gmr"),
                curveComputer: address(curveComp),
                tierGatingModule: address(tierGating),
                componentRegistry: address(compReg)
            })
        );

        bytes32[] memory feats = IFactory(address(factory)).features();
        assertTrue(_hasGating(feats), "ERC404CypherFactory: GATING tag missing from features()");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ERC1155Factory
    // ─────────────────────────────────────────────────────────────────────────

    function test_ERC1155Factory_features_returnsArrayViaInterface() public {
        ComponentRegistry compReg = _deployComponentRegistry();

        ERC1155Factory factory = new ERC1155Factory(
            makeAddr("mr"),
            makeAddr("tmpl"),
            makeAddr("gmr"),
            address(compReg)
        );

        bytes32[] memory feats = IFactory(address(factory)).features();
        assertTrue(_hasGating(feats), "ERC1155Factory: GATING tag missing from features()");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ERC721AuctionFactory — empty features array
    // ─────────────────────────────────────────────────────────────────────────

    function test_ERC721AuctionFactory_features_returnsEmptyArrayViaInterface() public {
        ERC721AuctionFactory factory = new ERC721AuctionFactory(
            makeAddr("mr"),
            makeAddr("gmr")
        );

        bytes32[] memory feats = IFactory(address(factory)).features();
        assertEq(feats.length, 0, "ERC721AuctionFactory: features() must return empty array");
    }
}
