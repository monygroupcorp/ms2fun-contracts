// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {MasterRegistryV1} from "../src/master/MasterRegistryV1.sol";
import {MasterRegistry} from "../src/master/MasterRegistry.sol";
import {AlignmentRegistryV1} from "../src/master/AlignmentRegistryV1.sol";
import {IAlignmentRegistry} from "../src/master/interfaces/IAlignmentRegistry.sol";
import {FeaturedQueueManager} from "../src/master/FeaturedQueueManager.sol";
import {GlobalMessageRegistry} from "../src/registry/GlobalMessageRegistry.sol";
import {ComponentRegistry} from "../src/registry/ComponentRegistry.sol";
import {ProtocolTreasuryV1} from "../src/treasury/ProtocolTreasuryV1.sol";
import {UniAlignmentVault} from "../src/vaults/uni/UniAlignmentVault.sol";
import {UniAlignmentVaultFactory} from "../src/vaults/uni/UniAlignmentVaultFactory.sol";
import {CypherAlignmentVault} from "../src/vaults/cypher/CypherAlignmentVault.sol";
import {CypherAlignmentVaultFactory} from "../src/vaults/cypher/CypherAlignmentVaultFactory.sol";
import {IZAMM, ZAMMAlignmentVault} from "../src/vaults/zamm/ZAMMAlignmentVault.sol";
import {ZAMMAlignmentVaultFactory} from "../src/vaults/zamm/ZAMMAlignmentVaultFactory.sol";
import {UniswapVaultPriceValidator} from "../src/peripherals/UniswapVaultPriceValidator.sol";
import {IVaultPriceValidator} from "../src/interfaces/IVaultPriceValidator.sol";
import {ERC404Factory} from "../src/factories/erc404/ERC404Factory.sol";
import {ERC404BondingInstance} from "../src/factories/erc404/ERC404BondingInstance.sol";
import {LaunchManager} from "../src/factories/erc404/LaunchManager.sol";
import {CurveParamsComputer} from "../src/factories/erc404/CurveParamsComputer.sol";
import {ERC1155Factory} from "../src/factories/erc1155/ERC1155Factory.sol";
import {DynamicPricingModule} from "../src/factories/erc1155/DynamicPricingModule.sol";
import {ERC721AuctionFactory} from "../src/factories/erc721/ERC721AuctionFactory.sol";
import {QueryAggregator} from "../src/query/QueryAggregator.sol";
import {zRouter} from "../src/peripherals/zRouter.sol";
import {MockSafe} from "../test/mocks/MockSafe.sol";
import {ICreateX, CREATEX} from "../src/shared/CreateXConstants.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

/// @title DeployCore
/// @notice Single source of truth for protocol deployment across all networks.
///         Extend this contract and inject a NetworkConfig to deploy to any network.
///         Never calls vm.envOr — all config comes through the struct.
contract DeployCore is Script {

    // ─────────────────────────── Config Structs ────────────────────────────

    struct AlignmentTargetConfig {
        address token;
        string  symbol;
        string  name;
        string  description;
        bool    deployUniVault;
        bool    deployCypherVault;
        bool    deployZAMMVault;
    }

    struct NetworkConfig {
        uint256 chainId;

        // External protocol addresses
        address weth;
        address v4PoolManager;
        address v3Factory;
        address v2Factory;

        // Vault AMM addresses — address(0) means that AMM isn't on this network, skip factory
        address cypherPositionManager;
        address cypherRouter;
        address zamm;

        // Pre-existing contracts — address(0) = deploy fresh
        address zrouter;
        address safe;

        // CREATE3 salts for UUPS proxies
        bytes32 saltMasterRegistry;
        bytes32 saltTreasury;
        bytes32 saltQueueManager;
        bytes32 saltGlobalMsgReg;
        bytes32 saltAlignmentReg;
        bytes32 saltComponentReg;

        // Price validator params
        uint256 priceDeviationBps;
        uint32  twapSeconds;

        // Vault pool params (used for UniAlignmentVault V4 pool key per target)
        uint24  zrouterFee;
        int24   zrouterTickSpacing;

        // One or more alignment targets — each can have 1-3 vault types
        AlignmentTargetConfig[] alignmentTargets;

        // Output path for deployments JSON — empty string = skip (test mode)
        string jsonOutputPath;
    }

    // ───────────────────────── Deployed State (public for test access) ──────

    // Core proxies
    address public masterRegistry;
    MasterRegistryV1 public masterRegistryImpl;
    ProtocolTreasuryV1 public treasury;
    ProtocolTreasuryV1 public treasuryImpl;
    FeaturedQueueManager public queueManager;
    FeaturedQueueManager public queueManagerImpl;
    GlobalMessageRegistry public globalMessageRegistry;
    GlobalMessageRegistry public globalMessageRegistryImpl;
    AlignmentRegistryV1 public alignmentRegistry;
    AlignmentRegistryV1 public alignmentRegistryImpl;
    ComponentRegistry public componentRegistry;
    ComponentRegistry public componentRegistryImpl;

    // Infrastructure
    address public safe;
    zRouter public zrouter;
    UniswapVaultPriceValidator public priceValidator;

    // Vault factories
    UniAlignmentVaultFactory public uniVaultFactory;
    CypherAlignmentVaultFactory public cypherVaultFactory;
    ZAMMAlignmentVaultFactory public zammVaultFactory;

    // Deployed vault instances — indexed by target index
    address[] public uniVaults;
    address[] public cypherVaults;
    address[] public zammVaults;
    uint256[] public alignmentTargetIds;

    // Project factories
    ERC404Factory public erc404Factory;
    ERC404BondingInstance public erc404Impl;
    LaunchManager public launchManager;
    CurveParamsComputer public curveParamsComputer;
    ERC1155Factory public erc1155Factory;
    DynamicPricingModule public dynamicPricingModule;
    ERC721AuctionFactory public erc721Factory;
    QueryAggregator public queryAggregator;

    // ───────────────────────────── Entry Point ──────────────────────────────

    /// @notice Deploy all protocol contracts for the given network config.
    ///         Callable from forge scripts (with broadcast) or tests (without).
    function deploy(address deployer, NetworkConfig memory cfg) public {
        // ── Phase 1: Protocol proxies (CREATE3) ─────────────────────────────

        masterRegistryImpl = new MasterRegistryV1();
        {
            bytes memory initData = abi.encodeWithSignature("initialize(address)", deployer);
            bytes memory proxyInitCode = abi.encodePacked(
                type(MasterRegistry).creationCode,
                abi.encode(address(masterRegistryImpl), initData)
            );
            masterRegistry = ICreateX(CREATEX).deployCreate3(cfg.saltMasterRegistry, proxyInitCode);
        }

        treasuryImpl = new ProtocolTreasuryV1();
        treasury = ProtocolTreasuryV1(payable(
            _deployProxyCreate3(address(treasuryImpl), cfg.saltTreasury,
                abi.encodeWithSignature("initialize(address)", deployer))
        ));
        if (cfg.v4PoolManager != address(0)) treasury.setV4PoolManager(cfg.v4PoolManager);
        if (cfg.weth != address(0)) treasury.setWETH(cfg.weth);

        queueManagerImpl = new FeaturedQueueManager();
        queueManager = FeaturedQueueManager(payable(
            _deployProxyCreate3(address(queueManagerImpl), cfg.saltQueueManager,
                abi.encodeWithSignature("initialize(address,address)", masterRegistry, deployer))
        ));
        queueManager.setWeth(cfg.weth);

        globalMessageRegistryImpl = new GlobalMessageRegistry();
        globalMessageRegistry = GlobalMessageRegistry(
            _deployProxyCreate3(address(globalMessageRegistryImpl), cfg.saltGlobalMsgReg,
                abi.encodeWithSignature("initialize(address,address)", deployer, masterRegistry))
        );

        alignmentRegistryImpl = new AlignmentRegistryV1();
        alignmentRegistry = AlignmentRegistryV1(
            _deployProxyCreate3(address(alignmentRegistryImpl), cfg.saltAlignmentReg,
                abi.encodeWithSignature("initialize(address)", deployer))
        );

        componentRegistryImpl = new ComponentRegistry();
        componentRegistry = ComponentRegistry(
            _deployProxyCreate3(address(componentRegistryImpl), cfg.saltComponentReg,
                abi.encodeWithSignature("initialize(address)", deployer))
        );

        MasterRegistryV1(masterRegistry).setAlignmentRegistry(address(alignmentRegistry));
    }

    // ─────────────────────────── Internal Helpers ───────────────────────────

    /// @dev Deploy an ERC1967 proxy via CREATE3, atomically initializing it.
    function _deployProxyCreate3(
        address impl,
        bytes32 salt,
        bytes memory initData
    ) internal returns (address) {
        bytes memory proxyInitCode = abi.encodePacked(
            type(MasterRegistry).creationCode,
            abi.encode(impl, initData)
        );
        return ICreateX(CREATEX).deployCreate3(salt, proxyInitCode);
    }
}
