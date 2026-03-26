// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {AlignmentRegistryV1} from "../src/master/AlignmentRegistryV1.sol";
import {IAlignmentRegistry} from "../src/master/interfaces/IAlignmentRegistry.sol";
import {MasterRegistryV1} from "../src/master/MasterRegistryV1.sol";
import {ComponentRegistry} from "../src/registry/ComponentRegistry.sol";
import {UniAlignmentVaultFactory} from "../src/vaults/uni/UniAlignmentVaultFactory.sol";
import {IVaultPriceValidator} from "../src/interfaces/IVaultPriceValidator.sol";
import {FeatureUtils} from "../src/master/libraries/FeatureUtils.sol";
import {PasswordTierGatingModule} from "../src/gating/PasswordTierGatingModule.sol";
import {MockComponentModule} from "../test/mocks/MockComponentModule.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/// @notice Post-deployment seed script for the existing Sepolia deployment.
///         Adds missing state that was previously handled by the Node.js seed-common.mjs:
///         - MS2 + CULT test tokens
///         - Alignment targets + UniAlignmentVaults for each
///         - 5 MockComponentModules for the creation wizard
///         - PasswordTierGatingModule (real gating contract)
///         - LaunchManager approval (enables ERC404 creation)
///
///         Run with:
///         forge script script/SeedSepolia.s.sol \
///           --account <keystore> \
///           --sender 0x1821bd18cbdd267ce4e389f893ddfe7beb333ab6 \
///           --rpc-url <sepolia-rpc> \
///           --broadcast --verify
contract SeedSepolia is Script {

    // ── Existing Sepolia deployment ───────────────────────────────────────────

    AlignmentRegistryV1    constant ALIGNMENT_REGISTRY  = AlignmentRegistryV1(0x00001152db13C4AFb4d9F4bbA93F364692F372eB);
    MasterRegistryV1       constant MASTER_REGISTRY     = MasterRegistryV1(0x00001152CBa5fDB16A0FAE780fFebD5b9dF8e7cF);
    ComponentRegistry      constant COMPONENT_REGISTRY  = ComponentRegistry(0x00001152Ed1bD8e76693cB775c79708275bBb2F3);
    UniAlignmentVaultFactory constant VAULT_FACTORY     = UniAlignmentVaultFactory(0x5dE980F4F8e0e759A722cEc822cD8c18F13212B4);
    address                constant MASTER_REGISTRY_ADDR = 0x00001152CBa5fDB16A0FAE780fFebD5b9dF8e7cF;
    // LaunchManager and DynamicPricingModule from original deploy
    address                constant LAUNCH_MANAGER      = 0x354768153a0d3edC314D9f6baa2fd56a6961B449;

    uint256 constant SEPOLIA_CHAIN_ID = 11155111;

    // ── Deployed by this script (written to sepolia-seed.json) ───────────────

    MockERC20 public ms2Token;
    MockERC20 public cultToken;
    uint256 public ms2TargetId;
    uint256 public cultTargetId;
    address public ms2Vault;
    address public cultVault;
    PasswordTierGatingModule public passwordTierGatingModule;
    MockComponentModule public modulePasswordGating;
    MockComponentModule public moduleMerkleGating;
    MockComponentModule public moduleUniV4Deployer;
    MockComponentModule public moduleZAMMDeployer;
    MockComponentModule public moduleCypherDeployer;

    function run() public {
        vm.startBroadcast();
        seed(msg.sender);
        vm.stopBroadcast();
    }

    function seed(address deployer) public {

        // ── Phase 1: Test tokens ─────────────────────────────────────────────

        ms2Token  = new MockERC20("Milady Station 2", "MS2");
        cultToken = new MockERC20("CULT DAO", "CULT");

        // ── Phase 2: Alignment targets ───────────────────────────────────────

        IAlignmentRegistry.AlignmentAsset[] memory ms2Assets = new IAlignmentRegistry.AlignmentAsset[](1);
        ms2Assets[0] = IAlignmentRegistry.AlignmentAsset({
            token: address(ms2Token), symbol: "MS2", info: "MS2 community alignment target", metadataURI: ""
        });
        ms2TargetId = ALIGNMENT_REGISTRY.registerAlignmentTarget(
            "Milady Station 2", "MS2 community alignment target", "", ms2Assets
        );

        IAlignmentRegistry.AlignmentAsset[] memory cultAssets = new IAlignmentRegistry.AlignmentAsset[](1);
        cultAssets[0] = IAlignmentRegistry.AlignmentAsset({
            token: address(cultToken), symbol: "CULT", info: "CULT community alignment target", metadataURI: ""
        });
        cultTargetId = ALIGNMENT_REGISTRY.registerAlignmentTarget(
            "CULT DAO", "CULT community alignment target", "", cultAssets
        );

        // ── Phase 3: Vaults ──────────────────────────────────────────────────

        // Use index-based salts consistent with DeployCore's pattern (LINK was index 0)
        bytes32 ms2Salt  = keccak256(abi.encode(SEPOLIA_CHAIN_ID, uint256(1), "UNIv4"));
        bytes32 cultSalt = keccak256(abi.encode(SEPOLIA_CHAIN_ID, uint256(2), "UNIv4"));

        ms2Vault = VAULT_FACTORY.deployVault(ms2Salt, address(ms2Token), ms2TargetId, IVaultPriceValidator(address(0)));
        MASTER_REGISTRY.registerVault(
            ms2Vault, deployer, "MS2 UNIv4 Vault",
            "data:application/json,{\"name\":\"MS2 UNIv4 Vault\"}", ms2TargetId
        );

        cultVault = VAULT_FACTORY.deployVault(cultSalt, address(cultToken), cultTargetId, IVaultPriceValidator(address(0)));
        MASTER_REGISTRY.registerVault(
            cultVault, deployer, "CULT UNIv4 Vault",
            "data:application/json,{\"name\":\"CULT UNIv4 Vault\"}", cultTargetId
        );

        // ── Phase 4: PasswordTierGatingModule (real gating contract) ─────────

        passwordTierGatingModule = new PasswordTierGatingModule(MASTER_REGISTRY_ADDR);
        COMPONENT_REGISTRY.approveComponent(
            address(passwordTierGatingModule), FeatureUtils.GATING, "Password Tier Gating (real)"
        );

        // Approve existing LaunchManager — required for ERC404 creation
        // (isApprovedComponent(preset.curveComputer) is a separate check handled by original deploy)
        COMPONENT_REGISTRY.approveComponent(
            LAUNCH_MANAGER, FeatureUtils.LIQUIDITY_DEPLOYER, "LaunchManager"
        );

        // ── Phase 4b: MockComponentModules — creation wizard UI ───────────────

        string memory passwordGatingMeta = "data:application/json,{\"name\":\"Password Tier Gating\",\"subtitle\":\"Password \\u00b7 Tiered Access\",\"description\":\"Set one or more passwords, each unlocking a different tier of access or pricing.\",\"configType\":\"password-tier-gating\"}";
        string memory merkleGatingMeta   = "data:application/json,{\"name\":\"Merkle Allowlist Gating\",\"subtitle\":\"Allowlist \\u00b7 Merkle Tree\",\"description\":\"Upload a list of wallet addresses to restrict minting to an allowlist.\"}";
        string memory uniV4Meta          = "data:application/json,{\"name\":\"Uniswap V4 Deployer\",\"subtitle\":\"Uniswap V4 \\u00b7 Concentrated Liquidity\",\"description\":\"Deploy liquidity to a Uniswap V4 pool on graduation.\",\"configType\":\"launch-profile\"}";
        string memory zammMeta           = "data:application/json,{\"name\":\"ZAMM Deployer\",\"subtitle\":\"ZAMM \\u00b7 Constant Product\",\"description\":\"Deploy liquidity to ZAMM on graduation.\",\"configType\":\"launch-profile\"}";
        string memory cypherMeta         = "data:application/json,{\"name\":\"Cypher Deployer\",\"subtitle\":\"Cypher \\u00b7 Concentrated Liquidity\",\"description\":\"Deploy liquidity to Cypher on graduation.\",\"configType\":\"launch-profile\"}";

        modulePasswordGating = new MockComponentModule(deployer, passwordGatingMeta);
        COMPONENT_REGISTRY.approveComponent(address(modulePasswordGating),  FeatureUtils.GATING,             "Password Tier Gating");

        moduleMerkleGating   = new MockComponentModule(deployer, merkleGatingMeta);
        COMPONENT_REGISTRY.approveComponent(address(moduleMerkleGating),    FeatureUtils.GATING,             "Merkle Allowlist Gating");

        moduleUniV4Deployer  = new MockComponentModule(deployer, uniV4Meta);
        COMPONENT_REGISTRY.approveComponent(address(moduleUniV4Deployer),   FeatureUtils.LIQUIDITY_DEPLOYER, "Uniswap V4 Deployer");

        moduleZAMMDeployer   = new MockComponentModule(deployer, zammMeta);
        COMPONENT_REGISTRY.approveComponent(address(moduleZAMMDeployer),    FeatureUtils.LIQUIDITY_DEPLOYER, "ZAMM Deployer");

        moduleCypherDeployer = new MockComponentModule(deployer, cypherMeta);
        COMPONENT_REGISTRY.approveComponent(address(moduleCypherDeployer),  FeatureUtils.LIQUIDITY_DEPLOYER, "Cypher Deployer");

        // ── Output ───────────────────────────────────────────────────────────

        _writeSeedJson();
    }

    function _writeSeedJson() internal {
        string memory s = "seed";
        vm.serializeAddress(s, "ms2Token",              address(ms2Token));
        vm.serializeAddress(s, "cultToken",             address(cultToken));
        vm.serializeUint(s,   "ms2TargetId",            ms2TargetId);
        vm.serializeUint(s,   "cultTargetId",           cultTargetId);
        vm.serializeAddress(s, "ms2Vault",              ms2Vault);
        vm.serializeAddress(s, "cultVault",             cultVault);
        vm.serializeAddress(s, "passwordTierGatingModule", address(passwordTierGatingModule));
        vm.serializeAddress(s, "modulePasswordGating",  address(modulePasswordGating));
        vm.serializeAddress(s, "moduleMerkleGating",    address(moduleMerkleGating));
        vm.serializeAddress(s, "moduleUniV4Deployer",   address(moduleUniV4Deployer));
        vm.serializeAddress(s, "moduleZAMMDeployer",    address(moduleZAMMDeployer));
        string memory json = vm.serializeAddress(s, "moduleCypherDeployer", address(moduleCypherDeployer));
        vm.writeJson(json, "./deployments/sepolia-seed.json");
        console.log("Seed JSON written to: ./deployments/sepolia-seed.json");
    }
}
