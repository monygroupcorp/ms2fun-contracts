// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IFactory} from "../../src/interfaces/IFactory.sol";
import {FeatureUtils} from "../../src/master/libraries/FeatureUtils.sol";

// Factories under test
import {ERC404Factory} from "../../src/factories/erc404/ERC404Factory.sol";
import {ERC1155Factory} from "../../src/factories/erc1155/ERC1155Factory.sol";
import {ERC721AuctionFactory} from "../../src/factories/erc721/ERC721AuctionFactory.sol";

// Supporting contracts needed to construct factories
import {ERC404BondingInstance} from "../../src/factories/erc404/ERC404BondingInstance.sol";
import {LaunchManager} from "../../src/factories/erc404/LaunchManager.sol";
import {CurveParamsComputer} from "../../src/factories/erc404/CurveParamsComputer.sol";
import {PasswordTierGatingModule} from "../../src/gating/PasswordTierGatingModule.sol";
import {ComponentRegistry} from "../../src/registry/ComponentRegistry.sol";
import {MockMasterRegistry} from "../mocks/MockMasterRegistry.sol";
import {LibClone} from "solady/utils/LibClone.sol";

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

        LaunchManager launchMgr = new LaunchManager(protocol);
        CurveParamsComputer curveComp = new CurveParamsComputer(protocol);
        ComponentRegistry compReg = _deployComponentRegistry();
        ERC404BondingInstance impl = new ERC404BondingInstance();

        ERC404Factory factory = new ERC404Factory(
            ERC404Factory.CoreConfig({
                implementation: address(impl),
                masterRegistry: makeAddr("mr"),
                protocol: protocol,
                weth: address(0xBEEF)
            }),
            ERC404Factory.ModuleConfig({
                globalMessageRegistry: makeAddr("gmr"),
                launchManager: address(launchMgr),
                componentRegistry: address(compReg)
            })
        );

        vm.stopPrank();

        bytes32[] memory feats = IFactory(address(factory)).features();
        assertEq(feats.length, 3, "ERC404Factory: features() must have exactly 3 elements");
        assertEq(feats[0], FeatureUtils.GATING,             "ERC404Factory: features()[0] must be GATING");
        assertEq(feats[1], FeatureUtils.LIQUIDITY_DEPLOYER, "ERC404Factory: features()[1] must be LIQUIDITY_DEPLOYER");
        assertEq(feats[2], FeatureUtils.STAKING,            "ERC404Factory: features()[2] must be STAKING");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ERC1155Factory
    // ─────────────────────────────────────────────────────────────────────────

    function test_ERC1155Factory_features_returnsArrayViaInterface() public {
        ComponentRegistry compReg = _deployComponentRegistry();

        ERC1155Factory factory = new ERC1155Factory(
            makeAddr("mr"),
            makeAddr("gmr"),
            address(compReg),
            address(0xBEEF)
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
            makeAddr("gmr"),
            address(0xBEEF)
        );

        bytes32[] memory feats = IFactory(address(factory)).features();
        assertEq(feats.length, 0, "ERC721AuctionFactory: features() must return empty array");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // requiredFeatures()
    // ─────────────────────────────────────────────────────────────────────────

    function test_ERC404Factory_requiredFeatures_returnsLiquidityDeployer() public {
        vm.startPrank(protocol);

        LaunchManager launchMgr = new LaunchManager(protocol);
        CurveParamsComputer curveComp = new CurveParamsComputer(protocol);
        ComponentRegistry compReg = _deployComponentRegistry();
        ERC404BondingInstance impl = new ERC404BondingInstance();

        ERC404Factory factory = new ERC404Factory(
            ERC404Factory.CoreConfig({
                implementation: address(impl),
                masterRegistry: makeAddr("mr"),
                protocol: protocol,
                weth: address(0xBEEF)
            }),
            ERC404Factory.ModuleConfig({
                globalMessageRegistry: makeAddr("gmr"),
                launchManager: address(launchMgr),
                componentRegistry: address(compReg)
            })
        );

        vm.stopPrank();

        bytes32[] memory req = IFactory(address(factory)).requiredFeatures();
        assertEq(req.length, 1, "ERC404Factory: requiredFeatures() must have 1 element");
        assertEq(req[0], FeatureUtils.LIQUIDITY_DEPLOYER, "ERC404Factory: requiredFeatures()[0] must be LIQUIDITY_DEPLOYER");

        // requiredFeatures must be a subset of features
        bytes32[] memory feats = IFactory(address(factory)).features();
        assertTrue(FeatureUtils.hasFeature(feats, req[0]), "requiredFeatures must be subset of features");
    }

    function test_ERC1155Factory_requiredFeatures_returnsEmpty() public {
        ComponentRegistry compReg = _deployComponentRegistry();

        ERC1155Factory factory = new ERC1155Factory(
            makeAddr("mr"),
            makeAddr("gmr"),
            address(compReg),
            address(0xBEEF)
        );

        bytes32[] memory req = IFactory(address(factory)).requiredFeatures();
        assertEq(req.length, 0, "ERC1155Factory: requiredFeatures() must be empty");
    }

    function test_ERC721AuctionFactory_requiredFeatures_returnsEmpty() public {
        ERC721AuctionFactory factory = new ERC721AuctionFactory(
            makeAddr("mr"),
            makeAddr("gmr"),
            address(0xBEEF)
        );

        bytes32[] memory req = IFactory(address(factory)).requiredFeatures();
        assertEq(req.length, 0, "ERC721AuctionFactory: requiredFeatures() must be empty");
    }
}
