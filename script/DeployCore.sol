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

        // ── Phase 2: Safe ────────────────────────────────────────────────────

        safe = cfg.safe != address(0) ? cfg.safe : address(new MockSafe());

        // ── Phase 3: zRouter ─────────────────────────────────────────────────

        zrouter = cfg.zrouter != address(0)
            ? zRouter(payable(cfg.zrouter))
            : new zRouter();

        // ── Phase 4: Vault infrastructure ───────────────────────────────────

        // Always deploy — self-guards with code.length checks when pools don't exist
        priceValidator = new UniswapVaultPriceValidator(
            cfg.weth, cfg.v2Factory, cfg.v3Factory, cfg.v4PoolManager,
            cfg.priceDeviationBps, cfg.twapSeconds
        );

        uniVaultFactory = new UniAlignmentVaultFactory(
            cfg.weth,
            cfg.v4PoolManager,
            address(zrouter),
            cfg.zrouterFee,
            cfg.zrouterTickSpacing,
            IVaultPriceValidator(address(priceValidator)),
            alignmentRegistry
        );

        if (cfg.cypherPositionManager != address(0)) {
            CypherAlignmentVault cypherImpl = new CypherAlignmentVault();
            cypherVaultFactory = new CypherAlignmentVaultFactory(address(cypherImpl));
        }

        if (cfg.zamm != address(0)) {
            zammVaultFactory = new ZAMMAlignmentVaultFactory(
                cfg.zamm, address(zrouter), address(treasury)
            );
        }

        // ── Phase 5: Alignment targets + vault instances ─────────────────────

        for (uint256 i = 0; i < cfg.alignmentTargets.length; i++) {
            AlignmentTargetConfig memory t = cfg.alignmentTargets[i];

            IAlignmentRegistry.AlignmentAsset[] memory assets =
                new IAlignmentRegistry.AlignmentAsset[](1);
            assets[0] = IAlignmentRegistry.AlignmentAsset({
                token: t.token, symbol: t.symbol, info: t.description, metadataURI: ""
            });

            uint256 targetId = alignmentRegistry.registerAlignmentTarget(
                t.name, t.description, "", assets
            );
            alignmentTargetIds.push(targetId);

            if (t.deployUniVault) {
                bytes32 salt = keccak256(abi.encode(cfg.chainId, i, "UNIv4"));
                address vault = uniVaultFactory.deployVault(
                    salt, t.token, targetId, IVaultPriceValidator(address(0))
                );
                // Note: setV4PoolKey must be called by the vault owner (the factory).
                // Pool key is operational config set post-deploy via a separate governance call.
                MasterRegistryV1(masterRegistry).registerVault(
                    vault, deployer, string.concat(t.symbol, " UNIv4 Vault"),
                    "https://ms2.fun", targetId
                );
                uniVaults.push(vault);
            }

            if (t.deployCypherVault && address(cypherVaultFactory) != address(0)) {
                bytes32 salt = keccak256(abi.encode(cfg.chainId, i, "CYPHER"));
                address vault = address(cypherVaultFactory.createVault(
                    salt, cfg.cypherPositionManager, cfg.cypherRouter,
                    cfg.weth, t.token, address(treasury), address(0)
                ));
                MasterRegistryV1(masterRegistry).registerVault(
                    vault, deployer, string.concat(t.symbol, " Cypher Vault"),
                    "https://ms2.fun", targetId
                );
                cypherVaults.push(vault);
            }

            if (t.deployZAMMVault && address(zammVaultFactory) != address(0)) {
                bytes32 salt = keccak256(abi.encode(cfg.chainId, i, "ZAMM"));
                IZAMM.PoolKey memory poolKey; // zero poolKey — configure post-deploy when live
                address vault = zammVaultFactory.deployVault(salt, t.token, poolKey);
                MasterRegistryV1(masterRegistry).registerVault(
                    vault, deployer, string.concat(t.symbol, " ZAMM Vault"),
                    "https://ms2.fun", targetId
                );
                zammVaults.push(vault);
            }
        }

        // ── Phase 6: ERC404Factory ───────────────────────────────────────────

        erc404Impl = new ERC404BondingInstance();
        launchManager = new LaunchManager(deployer);
        curveParamsComputer = new CurveParamsComputer(deployer);

        erc404Factory = new ERC404Factory(
            ERC404Factory.CoreConfig({
                implementation: address(erc404Impl),
                masterRegistry: masterRegistry,
                protocol:       deployer,
                weth:           cfg.weth
            }),
            ERC404Factory.ModuleConfig({
                globalMessageRegistry: address(globalMessageRegistry),
                launchManager:         address(launchManager),
                componentRegistry:     address(componentRegistry)
            })
        );
        erc404Factory.setProtocolTreasury(address(treasury));

        componentRegistry.approveComponent(
            address(curveParamsComputer), bytes32("CurveComputer"), "CurveParamsComputer"
        );

        // Hardcoded protocol presets — NICHE / STANDARD / HYPE
        launchManager.setPreset(0, LaunchManager.Preset({
            targetETH: 5 ether, unitPerNFT: 1_000_000_000,
            liquidityReserveBps: 1000, curveComputer: address(curveParamsComputer), active: true
        }));
        launchManager.setPreset(1, LaunchManager.Preset({
            targetETH: 25 ether, unitPerNFT: 1_000_000,
            liquidityReserveBps: 1000, curveComputer: address(curveParamsComputer), active: true
        }));
        launchManager.setPreset(2, LaunchManager.Preset({
            targetETH: 50 ether, unitPerNFT: 1_000,
            liquidityReserveBps: 1000, curveComputer: address(curveParamsComputer), active: true
        }));

        // ── Phase 7: ERC1155Factory + DynamicPricingModule ───────────────────

        erc1155Factory = new ERC1155Factory(
            masterRegistry, address(globalMessageRegistry), address(componentRegistry), cfg.weth
        );
        erc1155Factory.setProtocolTreasury(address(treasury));

        dynamicPricingModule = new DynamicPricingModule();
        componentRegistry.approveComponent(
            address(dynamicPricingModule), bytes32("DynamicPricing"), "DynamicPricingModule"
        );
        erc1155Factory.setDynamicPricingModule(address(dynamicPricingModule));

        // ── Phase 8: ERC721AuctionFactory ────────────────────────────────────

        erc721Factory = new ERC721AuctionFactory(
            masterRegistry, address(globalMessageRegistry), cfg.weth
        );
        erc721Factory.setProtocolTreasury(address(treasury));

        // ── Phase 9: QueryAggregator ─────────────────────────────────────────

        queryAggregator = new QueryAggregator();
        queryAggregator.initialize(
            masterRegistry, address(queueManager), address(globalMessageRegistry), deployer
        );

        // ── Phase 10: MasterRegistry wiring ──────────────────────────────────

        MasterRegistryV1(masterRegistry).registerFactory(
            address(erc404Factory), "ERC404", "ERC404-Bonding-Curve-Factory",
            "ERC404 Bonding Curve", "https://ms2.fun", new bytes32[](0)
        );
        MasterRegistryV1(masterRegistry).registerFactory(
            address(erc1155Factory), "ERC1155", "ERC1155-Edition-Factory",
            "ERC1155 Editions", "https://ms2.fun", new bytes32[](0)
        );
        MasterRegistryV1(masterRegistry).registerFactory(
            address(erc721Factory), "ERC721", "ERC721-Auction-Factory",
            "ERC721 Auction", "https://ms2.fun", new bytes32[](0)
        );

        MasterRegistryV1(masterRegistry).setEmergencyRevoker(deployer);
        queueManager.setProtocolTreasury(address(treasury));
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
