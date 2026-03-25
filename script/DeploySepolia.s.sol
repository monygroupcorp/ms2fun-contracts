// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {MasterRegistryV1} from "../src/master/MasterRegistryV1.sol";
import {MasterRegistry} from "../src/master/MasterRegistry.sol";
import {IMasterRegistry} from "../src/master/interfaces/IMasterRegistry.sol";
import {AlignmentRegistryV1} from "../src/master/AlignmentRegistryV1.sol";
import {IAlignmentRegistry} from "../src/master/interfaces/IAlignmentRegistry.sol";
import {FeaturedQueueManager} from "../src/master/FeaturedQueueManager.sol";
import {GlobalMessageRegistry} from "../src/registry/GlobalMessageRegistry.sol";
import {ProtocolTreasuryV1} from "../src/treasury/ProtocolTreasuryV1.sol";
import {UniAlignmentVault} from "../src/vaults/uni/UniAlignmentVault.sol";
import {UniswapVaultPriceValidator} from "../src/peripherals/UniswapVaultPriceValidator.sol";
import {IVaultPriceValidator} from "../src/interfaces/IVaultPriceValidator.sol";
import {ERC404Factory} from "../src/factories/erc404/ERC404Factory.sol";
import {ERC404BondingInstance} from "../src/factories/erc404/ERC404BondingInstance.sol";
import {LaunchManager} from "../src/factories/erc404/LaunchManager.sol";
import {CurveParamsComputer} from "../src/factories/erc404/CurveParamsComputer.sol";
import {ComponentRegistry} from "../src/registry/ComponentRegistry.sol";
import {ERC1155Factory} from "../src/factories/erc1155/ERC1155Factory.sol";
import {ERC721AuctionFactory} from "../src/factories/erc721/ERC721AuctionFactory.sol";
import {PromotionBadges} from "../src/promotion/PromotionBadges.sol";
import {zRouter} from "../src/peripherals/zRouter.sol";
import {MockSafe} from "../test/mocks/MockSafe.sol";
import {ICreateX, CREATEX} from "../src/shared/CreateXConstants.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

contract DeploySepolia is Script {
    // Algebra V2 (Cypher AMM) addresses on Sepolia — fill before deploying
    address public constant SEPOLIA_ALGEBRA_FACTORY  = address(0); // TODO: fill with real address
    address public constant SEPOLIA_POSITION_MANAGER = address(0); // TODO: fill with real address
    address public constant SEPOLIA_ALGEBRA_ROUTER   = address(0); // TODO: fill with real address

    // Sepolia default addresses (overridable via env vars)
    address public constant SEPOLIA_WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address public constant SEPOLIA_LINK = 0x779877A7B0D9E8603169DdbD7836e478b4624789;
    address public constant SEPOLIA_V4_POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address public constant SEPOLIA_V3_FACTORY = 0x0227628f3F023bb0B980b67D528571c95c6DaC1c;
    address public constant SEPOLIA_V2_FACTORY = 0xF62c03E08ada871A0bEb309762E260a7a6a880E6;

    uint24  public constant ZROUTER_FEE = 3000;
    int24   public constant ZROUTER_TICK_SPACING = 60;

    // Vanity CREATE3 salts (deployer 0x1821bd18cbdd267ce4e389f893ddfe7beb333ab6 guard, no cross-chain protection)
    // => addresses all share the 0x00001152________ prefix (chain-agnostic)
    bytes32 public constant SALT_MASTER_REGISTRY   = 0x1821bd18cbdd267ce4e389f893ddfe7beb333ab600721d1a3d22a2ea02871306; // => 0x000011526343950cfc6d74140f48f8ffdd013d61
    bytes32 public constant SALT_TREASURY          = 0x1821bd18cbdd267ce4e389f893ddfe7beb333ab600530939d9b7c16301180b07; // => 0x000011525d097fb6f344660c999f88bcd0dff0d7
    bytes32 public constant SALT_QUEUE_MANAGER     = 0x1821bd18cbdd267ce4e389f893ddfe7beb333ab6007cd1badd91acac0064a2a3; // => 0x0000115285007e94f9e959bc6a2dafdf97423a32
    bytes32 public constant SALT_GLOBAL_MSG_REG    = 0x1821bd18cbdd267ce4e389f893ddfe7beb333ab60009c6c91fc2b55e00e94a29; // => 0x00001152a764cb67f7e8971d222a54b01b84f578
    bytes32 public constant SALT_ALIGNMENT_REG     = 0x1821bd18cbdd267ce4e389f893ddfe7beb333ab60033170d37eaf164000226a2; // => 0x000011521939ecfe7f5a05162734cc8bd9a20b8a
    bytes32 public constant SALT_COMPONENT_REG     = 0x1821bd18cbdd267ce4e389f893ddfe7beb333ab6008821ee824b2be903e32004; // => 0x00001152ec8497a7d8343c38364b9677588e120d
    bytes32 public constant SALT_VAULT             = 0x1821bd18cbdd267ce4e389f893ddfe7beb333ab600d87ebcf59ab0b201476b7f; // => 0x0000115279605df875dc71b1d4e940b3b898e6cb

    // Deployed addresses (public for test access)
    MasterRegistryV1 public masterRegistryImpl;
    MasterRegistry public masterRegistryProxy;
    address public masterRegistry; // proxy address cast for calls
    ProtocolTreasuryV1 public treasuryImpl;
    ProtocolTreasuryV1 public treasury; // proxy
    FeaturedQueueManager public queueManagerImpl;
    FeaturedQueueManager public queueManager; // proxy
    GlobalMessageRegistry public globalMessageRegistryImpl;
    GlobalMessageRegistry public globalMessageRegistry; // proxy

    address public safe;

    AlignmentRegistryV1 public alignmentRegistryImpl;
    AlignmentRegistryV1 public alignmentRegistry; // proxy
    address public alignmentToken;
    uint256 public alignmentTargetId;

    UniAlignmentVault public vault;

    LaunchManager public launchManager;
    CurveParamsComputer public curveParamsComputer;
    ComponentRegistry public componentRegistry;

    zRouter public zrouter;

    ERC404Factory public erc404Factory;
    ERC1155Factory public erc1155Factory;
    ERC721AuctionFactory public erc721Factory;
    PromotionBadges public promotionBadges;

    function run() public {
        vm.startBroadcast();
        deploy(msg.sender);
        vm.stopBroadcast();
        _logAddresses();
    }

    /// @notice Deploy all contracts. Callable from tests without broadcast.
    function deploy(address deployer) public {
        // Resolve addresses with env var overrides
        address weth = vm.envOr("WETH", SEPOLIA_WETH);
        address poolManager = vm.envOr("V4_POOL_MANAGER", SEPOLIA_V4_POOL_MANAGER);
        address v3Factory = vm.envOr("V3_FACTORY", SEPOLIA_V3_FACTORY);
        address v2Factory = vm.envOr("V2_FACTORY", SEPOLIA_V2_FACTORY);

        // ============ Phase 1: Core Infrastructure ============

        // 1. MasterRegistryV1 implementation
        masterRegistryImpl = new MasterRegistryV1();

        // 2. MasterRegistry proxy via CREATE3
        {
            bytes memory proxyInitCode = abi.encodePacked(
                type(MasterRegistry).creationCode,
                abi.encode(address(masterRegistryImpl), abi.encodeWithSignature("initialize(address)", deployer))
            );
            masterRegistryProxy = MasterRegistry(payable(
                ICreateX(CREATEX).deployCreate3(vm.envOr("MASTER_REGISTRY_SALT", SALT_MASTER_REGISTRY), proxyInitCode)
            ));
        }
        masterRegistry = address(masterRegistryProxy);

        // 3. ProtocolTreasuryV1 via CREATE3 (atomic deploy+init)
        treasuryImpl = new ProtocolTreasuryV1();
        treasury = ProtocolTreasuryV1(payable(
            _deployProxyCreate3(
                address(treasuryImpl),
                vm.envOr("TREASURY_SALT", SALT_TREASURY),
                abi.encodeWithSignature("initialize(address)", deployer)
            )
        ));
        treasury.setV4PoolManager(poolManager);
        treasury.setWETH(weth);

        // 4. FeaturedQueueManager via CREATE3 (atomic deploy+init)
        queueManagerImpl = new FeaturedQueueManager();
        queueManager = FeaturedQueueManager(payable(
            _deployProxyCreate3(
                address(queueManagerImpl),
                vm.envOr("QUEUE_MANAGER_SALT", SALT_QUEUE_MANAGER),
                abi.encodeWithSignature("initialize(address,address)", masterRegistry, deployer)
            )
        ));

        // 5. GlobalMessageRegistry via CREATE3 (atomic deploy+init)
        globalMessageRegistryImpl = new GlobalMessageRegistry();
        globalMessageRegistry = GlobalMessageRegistry(
            _deployProxyCreate3(
                address(globalMessageRegistryImpl),
                vm.envOr("GLOBAL_MSG_REGISTRY_SALT", SALT_GLOBAL_MSG_REG),
                abi.encodeWithSignature("initialize(address,address)", deployer, masterRegistry)
            )
        );

        // 6. AlignmentRegistryV1 via CREATE3 (atomic deploy+init)
        alignmentRegistryImpl = new AlignmentRegistryV1();
        alignmentRegistry = AlignmentRegistryV1(
            _deployProxyCreate3(
                address(alignmentRegistryImpl),
                vm.envOr("ALIGNMENT_REGISTRY_SALT", SALT_ALIGNMENT_REG),
                abi.encodeWithSignature("initialize(address)", deployer)
            )
        );
        MasterRegistryV1(masterRegistry).setAlignmentRegistry(address(alignmentRegistry));

        // ============ Phase 2: Safe (multisig) ============

        safe = vm.envOr("SAFE_ADDRESS", address(0));
        if (safe == address(0)) {
            safe = address(new MockSafe());
        }

        // ============ Phase 3: Alignment Target (WETH) ============

        alignmentToken = SEPOLIA_LINK;
        IAlignmentRegistry.AlignmentAsset[] memory assets = new IAlignmentRegistry.AlignmentAsset[](1);
        assets[0] = IAlignmentRegistry.AlignmentAsset({
            token: SEPOLIA_LINK,
            symbol: "LINK",
            info: "Chainlink - Sepolia alignment target",
            metadataURI: ""
        });
        alignmentTargetId = alignmentRegistry.registerAlignmentTarget(
            "Chainlink",
            "LINK alignment target for Sepolia testing",
            "",
            assets
        );

        // ============ Phase 3.5: zRouter ============

        {
            address zrouterAddr = vm.envOr("ZROUTER_ADDRESS", address(0));
            if (zrouterAddr == address(0)) {
                zrouter = new zRouter();
            } else {
                zrouter = zRouter(payable(zrouterAddr));
            }
        }

        // ============ Phase 4: Vault ============

        // 12. UniAlignmentVault (atomic deploy+init via ERC1967 proxy)
        UniswapVaultPriceValidator priceValidator = new UniswapVaultPriceValidator(
            weth, v2Factory, v3Factory, poolManager, 1000, 1800
        );
        UniAlignmentVault vaultImpl = new UniAlignmentVault();
        vault = UniAlignmentVault(payable(
            _deployProxyCreate3(
                address(vaultImpl),
                vm.envOr("VAULT_SALT", SALT_VAULT),
                abi.encodeWithSignature(
                    "initialize(address,address,address,address,address,uint24,int24,address,address,uint256)",
                    deployer,
                    weth,
                    poolManager,
                    SEPOLIA_LINK,
                    address(zrouter),
                    ZROUTER_FEE,
                    ZROUTER_TICK_SPACING,
                    address(priceValidator),
                    address(alignmentRegistry),
                    alignmentTargetId
                )
            )
        ));

        // 13. Register vault
        MasterRegistryV1(masterRegistry).registerVault(
            address(vault),
            deployer,           // creator
            "Test Vault",
            "https://sepolia.ms2.fun/vault",
            alignmentTargetId
        );

        // 14. Set ETH/LINK V4 pool key (currency0 = ETH = address(0), currency1 = LINK)
        vault.setV4PoolKey(PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(SEPOLIA_LINK),
            fee: ZROUTER_FEE,
            tickSpacing: ZROUTER_TICK_SPACING,
            hooks: IHooks(address(0))
        }));

        // ============ Phase 5+5b: Factories ============
        _deployFactories(deployer, weth, poolManager);

        // ============ Phase 6: Promotional ============

        // 17. PromotionBadges
        promotionBadges = new PromotionBadges(address(treasury));
        // ERC404 perks now go via LaunchManager (authorized to call PromotionBadges)
        promotionBadges.setAuthorizedFactory(address(launchManager), true);
        promotionBadges.setAuthorizedFactory(address(erc721Factory), true);

        // ============ Phase 7: Wiring ============

        // Emergency revoker (deployer for now, transfer to Safe post-deploy)
        MasterRegistryV1(masterRegistry).setEmergencyRevoker(deployer);

        // QueueManager treasury
        queueManager.setProtocolTreasury(address(treasury));

        // 21. Register factories in MasterRegistry
        MasterRegistryV1(masterRegistry).registerFactory(
            address(erc404Factory), "ERC404", "ERC404-Bonding", "ERC404 Bonding Factory", "https://sepolia.ms2.fun/factory/erc404", new bytes32[](0)
        );
        MasterRegistryV1(masterRegistry).registerFactory(
            address(erc1155Factory), "ERC1155", "ERC1155-Editions", "ERC1155 Edition Factory", "https://sepolia.ms2.fun/factory/erc1155", new bytes32[](0)
        );
        MasterRegistryV1(masterRegistry).registerFactory(
            address(erc721Factory), "ERC721", "ERC721-Auction", "ERC721 Auction Factory", "https://sepolia.ms2.fun/factory/erc721", new bytes32[](0)
        );
    }

    function _deployFactories(address deployer, address weth, address poolManager) private {
        // Phase 5: ERC404Factory
        ERC404BondingInstance erc404Impl = new ERC404BondingInstance();
        launchManager = new LaunchManager(deployer);
        curveParamsComputer = new CurveParamsComputer(deployer);

        // Deploy ComponentRegistry (UUPS proxy via CREATE3)
        ComponentRegistry compRegImpl = new ComponentRegistry();
        componentRegistry = ComponentRegistry(
            _deployProxyCreate3(
                address(compRegImpl),
                vm.envOr("COMPONENT_REGISTRY_SALT", SALT_COMPONENT_REG),
                abi.encodeWithSignature("initialize(address)", deployer)
            )
        );

        erc404Factory = new ERC404Factory(
            ERC404Factory.CoreConfig({
                implementation: address(erc404Impl),
                masterRegistry: masterRegistry,
                protocol: deployer,
                weth: weth
            }),
            ERC404Factory.ModuleConfig({
                globalMessageRegistry: address(globalMessageRegistry),
                launchManager: address(launchManager),
                componentRegistry: address(componentRegistry)
            })
        );
        erc404Factory.setProtocolTreasury(address(treasury));
        // NOTE: Approve components (curveParamsComputer, liquidity deployer) in ComponentRegistry
        // and call launchManager.setPreset() before the factory is usable.

        // Phase 5: ERC1155Factory
        erc1155Factory = new ERC1155Factory(
            masterRegistry, address(globalMessageRegistry), address(componentRegistry), weth
        );
        erc1155Factory.setProtocolTreasury(address(treasury));

        // Phase 5: ERC721AuctionFactory
        erc721Factory = new ERC721AuctionFactory(
            masterRegistry, address(globalMessageRegistry), weth
        );
        erc721Factory.setProtocolTreasury(address(treasury));

    }

    /// @dev Deploy an ERC1967 proxy via CREATE3 and atomically initialize it.
    ///      Uses the same MasterRegistry proxy pattern so deploy+init happen in one tx,
    ///      eliminating the front-running window on initialize().
    ///      Requires the implementation's initializer to accept an explicit owner address
    ///      (not msg.sender), which is the case for all registry/manager contracts.
    function _deployProxyCreate3(address impl, bytes32 salt, bytes memory initData) private returns (address) {
        bytes memory proxyInitCode = abi.encodePacked(
            type(MasterRegistry).creationCode,
            abi.encode(impl, initData)
        );
        return ICreateX(CREATEX).deployCreate3(salt, proxyInitCode);
    }

    /// @dev Deploy a minimal EIP-1167 clone via CREATE3 WITHOUT initialization.
    ///      Only use this for contracts whose initializer uses msg.sender for ownership
    ///      (e.g. UniAlignmentVault, where the caller intentionally becomes owner).
    ///      The separate initialize() call is still a distinct transaction — callers
    ///      should be aware of the front-running window on testnets.
    function _deployCloneCreate3(address impl, bytes32 salt) private returns (address) {
        bytes memory proxyCreationCode = abi.encodePacked(
            hex"3d602d80600a3d3981f3363d3d373d3d3d363d73",
            impl,
            hex"5af43d82803e903d91602b57fd5bf3"
        );
        return ICreateX(CREATEX).deployCreate3(salt, proxyCreationCode);
    }

    function _logAddresses() internal view {
        console.log("=== DEPLOYED ADDRESSES ===");
        console.log("MasterRegistry (proxy):", masterRegistry);
        console.log("MasterRegistry (impl):", address(masterRegistryImpl));
        console.log("ProtocolTreasury (proxy):", address(treasury));
        console.log("ProtocolTreasury (impl):", address(treasuryImpl));
        console.log("FeaturedQueueManager (proxy):", address(queueManager));
        console.log("FeaturedQueueManager (impl):", address(queueManagerImpl));
        console.log("GlobalMessageRegistry (proxy):", address(globalMessageRegistry));
        console.log("GlobalMessageRegistry (impl):", address(globalMessageRegistryImpl));
        console.log("AlignmentRegistry (proxy):", address(alignmentRegistry));
        console.log("AlignmentRegistry (impl):", address(alignmentRegistryImpl));
        console.log("Safe:", safe);
        console.log("Alignment token (LINK):", alignmentToken);
        console.log("zRouter:", address(zrouter));
        console.log("UniAlignmentVault:", address(vault));
        console.log("ComponentRegistry:", address(componentRegistry));
        console.log("ERC404Factory:", address(erc404Factory));
        console.log("ERC1155Factory:", address(erc1155Factory));
        console.log("ERC721AuctionFactory:", address(erc721Factory));
        console.log("PromotionBadges:", address(promotionBadges));
        console.log("V4 pool key: ETH/LINK fee=3000 tickSpacing=60");
        console.log("Alignment target ID:", alignmentTargetId);
    }
}
