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
                protocol: protocol
            }),
            ERC404Factory.ModuleConfig({
                globalMessageRegistry: makeAddr("gmr"),
                launchManager: address(launchMgr),
                tierGatingModule: address(0),
                componentRegistry: address(compReg)
            })
        );

        vm.stopPrank();

        bytes32[] memory feats = IFactory(address(factory)).features();
        assertEq(feats.length, 2, "ERC404Factory: features() must have exactly 2 elements");
        assertEq(feats[0], FeatureUtils.GATING,             "ERC404Factory: features()[0] must be GATING");
        assertEq(feats[1], FeatureUtils.LIQUIDITY_DEPLOYER, "ERC404Factory: features()[1] must be LIQUIDITY_DEPLOYER");
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
