// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {MasterRegistryV1} from "../src/master/MasterRegistryV1.sol";
import {MasterRegistry} from "../src/master/MasterRegistry.sol";
import {IMasterRegistry} from "../src/master/interfaces/IMasterRegistry.sol";
import {FeaturedQueueManager} from "../src/master/FeaturedQueueManager.sol";
import {GlobalMessageRegistry} from "../src/registry/GlobalMessageRegistry.sol";
import {ProtocolTreasuryV1} from "../src/treasury/ProtocolTreasuryV1.sol";
import {GrandCentral} from "../src/dao/GrandCentral.sol";
import {ShareOffering} from "../src/dao/conductors/ShareOffering.sol";
import {StipendConductor} from "../src/dao/conductors/StipendConductor.sol";
import {UltraAlignmentVault} from "../src/vaults/UltraAlignmentVault.sol";
import {ERC404Factory} from "../src/factories/erc404/ERC404Factory.sol";
import {ERC1155Factory} from "../src/factories/erc1155/ERC1155Factory.sol";
import {ERC721AuctionFactory} from "../src/factories/erc721/ERC721AuctionFactory.sol";
import {PromotionBadges} from "../src/promotion/PromotionBadges.sol";
import {MockSafe} from "../test/mocks/MockSafe.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

contract DeploySepolia is Script {
    // Sepolia default addresses (overridable via env vars)
    address public constant SEPOLIA_WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address public constant SEPOLIA_V4_POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address public constant SEPOLIA_V3_SWAP_ROUTER = 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E;
    address public constant SEPOLIA_V3_FACTORY = 0x0227628f3F023bb0B980b67D528571c95c6DaC1c;
    address public constant SEPOLIA_V2_ROUTER = 0xeE567Fe1712Faf6149d80dA1E6934E354124CfE3;
    address public constant SEPOLIA_V2_FACTORY = 0xF62c03E08ada871A0bEb309762E260a7a6a880E6;

    // Deployed addresses (public for test access)
    MasterRegistryV1 public masterRegistryImpl;
    MasterRegistry public masterRegistryProxy;
    address public masterRegistry; // proxy address cast for calls
    ProtocolTreasuryV1 public treasury;
    FeaturedQueueManager public queueManager;
    GlobalMessageRegistry public globalMessageRegistry;

    address public safe;
    GrandCentral public dao;
    ShareOffering public shareOffering;
    StipendConductor public stipendConductor;

    MockERC20 public testToken;
    uint256 public alignmentTargetId;

    UltraAlignmentVault public vault;

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
        address v3Router = vm.envOr("V3_SWAP_ROUTER", SEPOLIA_V3_SWAP_ROUTER);
        address v3Factory = vm.envOr("V3_FACTORY", SEPOLIA_V3_FACTORY);
        address v2Router = vm.envOr("V2_ROUTER", SEPOLIA_V2_ROUTER);
        address v2Factory = vm.envOr("V2_FACTORY", SEPOLIA_V2_FACTORY);

        // ============ Phase 1: Core Infrastructure ============

        // 1. MasterRegistryV1 implementation
        masterRegistryImpl = new MasterRegistryV1();

        // 2. MasterRegistry proxy
        bytes memory initData = abi.encodeWithSignature("initialize(address)", deployer);
        masterRegistryProxy = new MasterRegistry(address(masterRegistryImpl), initData);
        masterRegistry = masterRegistryProxy.getProxyAddress();

        // 3. ProtocolTreasuryV1
        treasury = new ProtocolTreasuryV1();
        treasury.initialize(deployer);
        treasury.setV4PoolManager(poolManager);
        treasury.setWETH(weth);

        // 4. FeaturedQueueManager
        queueManager = new FeaturedQueueManager();
        queueManager.initialize(masterRegistry, deployer);

        // 5. GlobalMessageRegistry
        globalMessageRegistry = new GlobalMessageRegistry(deployer, masterRegistry);

        // ============ Phase 2: DAO Layer ============

        // 6. Safe: use env var or deploy MockSafe
        safe = vm.envOr("SAFE_ADDRESS", address(0));
        if (safe == address(0)) {
            safe = address(new MockSafe());
        }

        // 7. GrandCentral DAO
        dao = new GrandCentral(
            safe,
            deployer,
            1000,       // initial shares
            1 days,     // voting period
            1 days,     // grace period
            0,          // quorum (no minimum for bootstrap)
            1,          // sponsor threshold
            66          // min retention
        );

        // 8. ShareOffering
        shareOffering = new ShareOffering(address(dao));

        // 9. StipendConductor
        stipendConductor = new StipendConductor(
            address(dao),
            deployer,
            3.15 ether,
            30 days
        );

        // ============ Phase 3: Mock Alignment Target ============

        // 10. Deploy MockERC20
        testToken = new MockERC20("TestToken", "TEST");

        // 11. Register alignment target
        IMasterRegistry.AlignmentAsset[] memory assets = new IMasterRegistry.AlignmentAsset[](1);
        assets[0] = IMasterRegistry.AlignmentAsset({
            token: address(testToken),
            symbol: "TEST",
            info: "Test alignment token for Sepolia",
            metadataURI: ""
        });
        alignmentTargetId = MasterRegistryV1(masterRegistry).registerAlignmentTarget(
            "Test Community",
            "Test alignment target for Sepolia",
            "",
            assets
        );

        // ============ Phase 4: Vault ============

        // 12. UltraAlignmentVault
        vault = new UltraAlignmentVault(
            weth,
            poolManager,
            v3Router,
            v2Router,
            v2Factory,
            v3Factory,
            address(testToken),
            deployer,       // factoryCreator
            100             // creatorYieldCutBps (1%)
        );

        // 13. Register vault
        MasterRegistryV1(masterRegistry).registerVault(
            address(vault),
            "Test Vault",
            "https://sepolia.ms2.fun/vault",
            alignmentTargetId
        );

        // ============ Phase 5: Factories ============

        // 14. ERC404Factory
        erc404Factory = new ERC404Factory(
            masterRegistry,
            address(0),     // instanceTemplate (not used for direct deploy)
            poolManager,
            weth,
            deployer,       // protocol
            deployer,       // creator
            500,            // creatorFeeBps (5%)
            100             // creatorGraduationFeeBps (1%)
        );
        erc404Factory.setProtocolTreasury(address(treasury));
        erc404Factory.setProfile(1, ERC404Factory.GraduationProfile({
            targetETH: 15 ether,
            unitPerNFT: 1_000_000,
            poolFee: 3000,
            tickSpacing: 60,
            liquidityReserveBps: 1000,
            active: true
        }));

        // 15. ERC1155Factory
        erc1155Factory = new ERC1155Factory(
            masterRegistry,
            address(0),     // instanceTemplate
            deployer,       // creator
            500             // creatorFeeBps (5%)
        );
        erc1155Factory.setProtocolTreasury(address(treasury));

        // 16. ERC721AuctionFactory
        erc721Factory = new ERC721AuctionFactory(
            masterRegistry,
            deployer,       // creator
            500             // creatorFeeBps (5%)
        );
        erc721Factory.setProtocolTreasury(address(treasury));

        // ============ Phase 6: Promotional ============

        // 17. PromotionBadges
        promotionBadges = new PromotionBadges(address(treasury));
        promotionBadges.setAuthorizedFactory(address(erc404Factory), true);
        promotionBadges.setAuthorizedFactory(address(erc1155Factory), true);
        promotionBadges.setAuthorizedFactory(address(erc721Factory), true);

        // ============ Phase 7: Wiring ============

        // 18-19. MasterRegistry wiring
        MasterRegistryV1(masterRegistry).setGlobalMessageRegistry(address(globalMessageRegistry));
        MasterRegistryV1(masterRegistry).setFeaturedQueueManager(address(queueManager));

        // 20. QueueManager treasury
        queueManager.setProtocolTreasury(address(treasury));

        // 21. Factory wiring (promotionBadges + featuredQueueManager)
        erc404Factory.setPromotionBadges(address(promotionBadges));
        erc404Factory.setFeaturedQueueManager(address(queueManager));
        erc1155Factory.setPromotionBadges(address(promotionBadges));
        erc1155Factory.setFeaturedQueueManager(address(queueManager));
        erc721Factory.setPromotionBadges(address(promotionBadges));
        erc721Factory.setFeaturedQueueManager(address(queueManager));

        // 22-24. Register factories in MasterRegistry
        MasterRegistryV1(masterRegistry).registerFactory(
            address(erc404Factory), "ERC404", "ERC404-Bonding", "ERC404 Bonding Factory", "https://sepolia.ms2.fun/factory/erc404"
        );
        MasterRegistryV1(masterRegistry).registerFactory(
            address(erc1155Factory), "ERC1155", "ERC1155-Editions", "ERC1155 Edition Factory", "https://sepolia.ms2.fun/factory/erc1155"
        );
        MasterRegistryV1(masterRegistry).registerFactory(
            address(erc721Factory), "ERC721", "ERC721-Auction", "ERC721 Auction Factory", "https://sepolia.ms2.fun/factory/erc721"
        );
    }

    function _logAddresses() internal view {
        console.log("=== DEPLOYED ADDRESSES ===");
        console.log("MasterRegistry (proxy):", masterRegistry);
        console.log("MasterRegistry (impl):", address(masterRegistryImpl));
        console.log("ProtocolTreasury:", address(treasury));
        console.log("FeaturedQueueManager:", address(queueManager));
        console.log("GlobalMessageRegistry:", address(globalMessageRegistry));
        console.log("GrandCentral (DAO):", address(dao));
        console.log("ShareOffering:", address(shareOffering));
        console.log("StipendConductor:", address(stipendConductor));
        console.log("MockSafe/Safe:", safe);
        console.log("TestToken (ERC20):", address(testToken));
        console.log("UltraAlignmentVault:", address(vault));
        console.log("ERC404Factory:", address(erc404Factory));
        console.log("ERC1155Factory:", address(erc1155Factory));
        console.log("ERC721AuctionFactory:", address(erc721Factory));
        console.log("PromotionBadges:", address(promotionBadges));
        console.log("");
        console.log("=== POST-DEPLOY CHECKLIST ===");
        console.log("1. In Safe UI: Settings > Modules > Add Module >", address(dao));
        console.log("2. Register conductors via DAO proposal (ShareOffering + StipendConductor)");
        console.log("3. Fund Safe with ETH for stipend payouts");
        console.log("4. Alignment target ID:", alignmentTargetId);
    }
}
