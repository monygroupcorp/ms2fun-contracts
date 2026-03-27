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
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

/// @notice Post-deployment seed script for the existing Sepolia deployment.
///         Adds missing state that was previously handled by the Node.js seed-common.mjs:
///         - MS2 + CULT test tokens
///         - Alignment targets + UniAlignmentVaults for each (via a NEW factory with setVaultPoolKey)
///         - V4 pool initialization + pool key assignment for each vault
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

    AlignmentRegistryV1 constant ALIGNMENT_REGISTRY = AlignmentRegistryV1(0x00001152db13C4AFb4d9F4bbA93F364692F372eB);
    MasterRegistryV1    constant MASTER_REGISTRY    = MasterRegistryV1(0x00001152CBa5fDB16A0FAE780fFebD5b9dF8e7cF);
    ComponentRegistry   constant COMPONENT_REGISTRY = ComponentRegistry(0x00001152Ed1bD8e76693cB775c79708275bBb2F3);
    address             constant MASTER_REGISTRY_ADDR = 0x00001152CBa5fDB16A0FAE780fFebD5b9dF8e7cF;
    address             constant LAUNCH_MANAGER     = 0x354768153a0d3edC314D9f6baa2fd56a6961B449;
    address             constant PRICE_VALIDATOR    = 0x2d3C9f10671314639FCBD4d85F3DcfbFF2D5610E;
    address             constant ZROUTER            = 0x4ABdEaB1A6Dca8CEFB3280cb2843DDbEf0FA1CFB;

    // Sepolia infrastructure
    address constant V4_POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address constant WETH            = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;

    uint256 constant SEPOLIA_CHAIN_ID = 11155111;

    // V4 pool params: 0.3% fee, tickSpacing 60, no hooks
    uint24  constant POOL_FEE         = 3000;
    int24   constant POOL_TICK_SPACING = 60;

    // Starting price: 1 ETH = 1 token (sqrtPriceX96 = sqrt(1) * 2^96 = 2^96)
    uint160 constant SQRT_PRICE_1_1   = 79228162514264337593543950336;

    // ── Deployed by this script (written to sepolia-seed.json) ───────────────

    UniAlignmentVaultFactory public vaultFactory;
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

        // ── Phase 3: New factory + vaults + pools ────────────────────────────
        //
        // The original factory (0x5dE980...) is ownerless and has no setVaultPoolKey.
        // Deploy a new factory (now Ownable with setVaultPoolKey) for MS2/CULT vaults.

        vaultFactory = new UniAlignmentVaultFactory(
            WETH,
            V4_POOL_MANAGER,
            ZROUTER,
            POOL_FEE,
            POOL_TICK_SPACING,
            IVaultPriceValidator(PRICE_VALIDATOR),
            ALIGNMENT_REGISTRY
        );

        // Index-based salts — consistent with DeployCore pattern (LINK was index 0)
        bytes32 ms2Salt  = keccak256(abi.encode(SEPOLIA_CHAIN_ID, uint256(1), "UNIv4"));
        bytes32 cultSalt = keccak256(abi.encode(SEPOLIA_CHAIN_ID, uint256(2), "UNIv4"));

        ms2Vault  = vaultFactory.deployVault(ms2Salt,  address(ms2Token),  ms2TargetId,  IVaultPriceValidator(address(0)));
        cultVault = vaultFactory.deployVault(cultSalt, address(cultToken), cultTargetId, IVaultPriceValidator(address(0)));

        MASTER_REGISTRY.registerVault(
            ms2Vault, deployer, "MS2 UNIv4 Vault",
            "data:application/json,{\"name\":\"MS2 UNIv4 Vault\",\"symbol\":\"MS2\"}", ms2TargetId
        );
        MASTER_REGISTRY.registerVault(
            cultVault, deployer, "CULT UNIv4 Vault",
            "data:application/json,{\"name\":\"CULT UNIv4 Vault\",\"symbol\":\"CULT\"}", cultTargetId
        );

        // V4 pool key: ETH (address(0)) is always < token address → currency0 = ETH
        PoolKey memory ms2PoolKey = PoolKey({
            currency0:   Currency.wrap(address(0)),
            currency1:   Currency.wrap(address(ms2Token)),
            fee:         POOL_FEE,
            tickSpacing: POOL_TICK_SPACING,
            hooks:       IHooks(address(0))
        });
        PoolKey memory cultPoolKey = PoolKey({
            currency0:   Currency.wrap(address(0)),
            currency1:   Currency.wrap(address(cultToken)),
            fee:         POOL_FEE,
            tickSpacing: POOL_TICK_SPACING,
            hooks:       IHooks(address(0))
        });

        // Initialize pools (permissionless — sets starting price, no liquidity required)
        IPoolManager(V4_POOL_MANAGER).initialize(ms2PoolKey,  SQRT_PRICE_1_1);
        IPoolManager(V4_POOL_MANAGER).initialize(cultPoolKey, SQRT_PRICE_1_1);

        // Wire pool keys into vaults (only possible because factory now owns vaults + has setVaultPoolKey)
        vaultFactory.setVaultPoolKey(ms2Vault,  ms2PoolKey);
        vaultFactory.setVaultPoolKey(cultVault, cultPoolKey);

        // ── Phase 4: ComponentRegistry — real contracts ───────────────────────

        // Real PasswordTierGatingModule
        passwordTierGatingModule = new PasswordTierGatingModule(MASTER_REGISTRY_ADDR);
        COMPONENT_REGISTRY.approveComponent(
            address(passwordTierGatingModule), FeatureUtils.GATING, "Password Tier Gating (real)"
        );

        // LaunchManager was deployed in the original Sepolia deploy — approve it for liquidity tag
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
        vm.serializeAddress(s, "vaultFactory",           address(vaultFactory));
        vm.serializeAddress(s, "ms2Token",               address(ms2Token));
        vm.serializeAddress(s, "cultToken",              address(cultToken));
        vm.serializeUint(s,   "ms2TargetId",             ms2TargetId);
        vm.serializeUint(s,   "cultTargetId",            cultTargetId);
        vm.serializeAddress(s, "ms2Vault",               ms2Vault);
        vm.serializeAddress(s, "cultVault",              cultVault);
        vm.serializeAddress(s, "passwordTierGatingModule", address(passwordTierGatingModule));
        vm.serializeAddress(s, "modulePasswordGating",   address(modulePasswordGating));
        vm.serializeAddress(s, "moduleMerkleGating",     address(moduleMerkleGating));
        vm.serializeAddress(s, "moduleUniV4Deployer",    address(moduleUniV4Deployer));
        vm.serializeAddress(s, "moduleZAMMDeployer",     address(moduleZAMMDeployer));
        string memory json = vm.serializeAddress(s, "moduleCypherDeployer", address(moduleCypherDeployer));
        vm.writeJson(json, "./deployments/sepolia-seed.json");
        console.log("Seed JSON written to: ./deployments/sepolia-seed.json");
    }
}
