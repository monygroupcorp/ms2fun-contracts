// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {MasterRegistryV1} from "../src/master/MasterRegistryV1.sol";
import {IMasterRegistry} from "../src/master/interfaces/IMasterRegistry.sol";
import {ComponentRegistry} from "../src/registry/ComponentRegistry.sol";
import {LaunchManager} from "../src/factories/erc404/LaunchManager.sol";
import {FeatureUtils} from "../src/master/libraries/FeatureUtils.sol";

/// @notice Read-only validation script. Checks all Sepolia protocol config
///         required for the ERC404 creation flow to work end-to-end.
///
///         Run with:
///         forge script script/ValidateSepolia.s.sol --rpc-url $SEPOLIA_RPC_URL
contract ValidateSepolia is Script {

    // ── Addresses ─────────────────────────────────────────────────────────
    address constant MASTER_REGISTRY     = 0x00001152CBa5fDB16A0FAE780fFebD5b9dF8e7cF;
    address constant COMPONENT_REGISTRY  = 0x00001152Ed1bD8e76693cB775c79708275bBb2F3;
    address constant LAUNCH_MANAGER      = 0x354768153a0d3edC314D9f6baa2fd56a6961B449;
    address constant ERC404_FACTORY      = 0xE57B69D9e27C5559Ae632e1a7EE9a941262181ba;

    ComponentRegistry cr = ComponentRegistry(COMPONENT_REGISTRY);
    LaunchManager lm     = LaunchManager(LAUNCH_MANAGER);
    MasterRegistryV1 mr  = MasterRegistryV1(MASTER_REGISTRY);

    function run() public view {
        console.log("\n=== Sepolia Protocol Validation ===\n");

        _checkFactory();
        _checkComponentRegistry();
        _checkLaunchManager();

        console.log("\n=== Done ===");
    }

    function _checkFactory() internal view {
        console.log("-- ERC404Factory --");
        bool registered = mr.isFactoryRegistered(ERC404_FACTORY);
        console.log("  registered in MasterRegistry:", registered);
        if (registered) {
            IMasterRegistry.FactoryInfo memory info = MasterRegistryV1(MASTER_REGISTRY).getFactoryInfoByAddress(ERC404_FACTORY);
            console.log("  active:", info.active);
            console.log("  factoryId:", info.factoryId);
        }
        console.log("");
    }

    function _checkComponentRegistry() internal view {
        console.log("-- ComponentRegistry --");

        address[] memory all = cr.getApprovedComponents();
        console.log("  total approved:", all.length);

        address[] memory liquidityDeployers = cr.getApprovedComponentsByTag(FeatureUtils.LIQUIDITY_DEPLOYER);
        console.log("  liquidity deployers:", liquidityDeployers.length);
        for (uint256 i = 0; i < liquidityDeployers.length; i++) {
            console.log("    ", liquidityDeployers[i]);
        }

        address[] memory gatingModules = cr.getApprovedComponentsByTag(FeatureUtils.GATING);
        console.log("  gating modules:", gatingModules.length);
        for (uint256 i = 0; i < gatingModules.length; i++) {
            console.log("    ", gatingModules[i]);
        }

        address[] memory curveComputers = cr.getApprovedComponentsByTag(bytes32("curve_computer"));
        console.log("  curve computers:", curveComputers.length);
        for (uint256 i = 0; i < curveComputers.length; i++) {
            console.log("    ", curveComputers[i]);
        }

        address[] memory stakingModules = cr.getApprovedComponentsByTag(FeatureUtils.STAKING);
        console.log("  staking modules:", stakingModules.length);
        for (uint256 i = 0; i < stakingModules.length; i++) {
            console.log("    ", stakingModules[i]);
        }
        console.log("");
    }

    function _checkLaunchManager() internal view {
        console.log("-- LaunchManager presets --");
        for (uint256 i = 0; i <= 2; i++) {
            LaunchManager.Preset memory preset = lm.getPreset(i);
            console.log("  preset", i);
            console.log("    active:", preset.active);
            console.log("    targetETH:", preset.targetETH);
            console.log("    curveComputer:", preset.curveComputer);
            bool curveApproved = preset.curveComputer != address(0) &&
                cr.isApprovedComponent(preset.curveComputer);
            console.log("    curveComputer approved:", curveApproved);
        }
        console.log("");
    }
}

