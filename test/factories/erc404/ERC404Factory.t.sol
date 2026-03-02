// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {ERC404Factory} from "../../../src/factories/erc404/ERC404Factory.sol";
import {ERC404BondingInstance, InvalidPoolManager, InvalidWETH} from "../../../src/factories/erc404/ERC404BondingInstance.sol";
import {ERC404StakingModule} from "../../../src/factories/erc404/ERC404StakingModule.sol";
import {LaunchManager} from "../../../src/factories/erc404/LaunchManager.sol";
import {CurveParamsComputer} from "../../../src/factories/erc404/CurveParamsComputer.sol";
import {MockMasterRegistry} from "../../mocks/MockMasterRegistry.sol";
import {PromotionBadges} from "../../../src/promotion/PromotionBadges.sol";
import {BondingCurveMath} from "../../../src/factories/erc404/libraries/BondingCurveMath.sol";
import {IdentityParams} from "../../../src/interfaces/IFactoryTypes.sol";
import {ComponentRegistry} from "../../../src/registry/ComponentRegistry.sol";
import {PasswordTierGatingModule} from "../../../src/gating/PasswordTierGatingModule.sol";
import {LibClone} from "solady/utils/LibClone.sol";

contract MockHook {}

contract MockVault {
    address private _hook;
    constructor(address hookAddr) { _hook = hookAddr; }
    function hook() external view returns (address) { return _hook; }
    function supportsCapability(bytes32) external pure returns (bool) { return true; }
    receive() external payable {}
}

/// @dev Vault that reports no hook — for testing "Vault hook required" revert
contract MockVaultNoHook {
    function hook() external pure returns (address) { return address(0); }
    function supportsCapability(bytes32) external pure returns (bool) { return true; }
    receive() external payable {}
}

contract MockMasterRegistryForStakingF {
    mapping(address => bool) public instances;
    function setInstance(address a, bool v) external { instances[a] = v; }
    function isRegisteredInstance(address a) external view returns (bool) { return instances[a]; }
}

contract ERC404FactoryTest is Test {
    ERC404Factory public factory;
    LaunchManager public launchMgr;
    CurveParamsComputer public curveComp;
    MockMasterRegistry public mockRegistry;
    MockVault public mockVault;
    MockHook public mockHook;
    MockMasterRegistryForStakingF public stakingRegistry;
    ERC404StakingModule public stakingModule;
    ComponentRegistry public componentRegistry;

    address public protocolAdmin = address(0x9);
    address public creator1 = address(0x2);
    address public creator2 = address(0x3);
    address public nonOwner = address(0x5);

    address public mockV4PoolManager = address(0x1111111111111111111111111111111111111111);
    address public mockWETH = address(0x2222222222222222222222222222222222222222);
    address public mockInstanceTemplate = address(0x4444444444444444444444444444444444444444);
    address public mockGMR = address(0x5555555555555555555555555555555555555555);

    uint256 constant INSTANCE_CREATION_FEE = 0.01 ether;
    uint256 constant DEFAULT_NFT_COUNT = 10;
    uint256 constant DEFAULT_PROFILE_ID = 1;

    event InstanceCreated(
        address indexed instance,
        address indexed creator,
        string name,
        string symbol,
        address indexed vault,
        address hook
    );

    function setUp() public {
        vm.startPrank(protocolAdmin);

        mockRegistry = new MockMasterRegistry();
        mockHook = new MockHook();
        mockVault = new MockVault(address(mockHook));
        stakingRegistry = new MockMasterRegistryForStakingF();
        stakingModule = new ERC404StakingModule(address(stakingRegistry));
        launchMgr = new LaunchManager(protocolAdmin);
        curveComp = new CurveParamsComputer(protocolAdmin);

        ComponentRegistry compRegImpl = new ComponentRegistry();
        address compRegProxy = LibClone.deployERC1967(address(compRegImpl));
        componentRegistry = ComponentRegistry(compRegProxy);
        componentRegistry.initialize(protocolAdmin);

        ERC404BondingInstance impl = new ERC404BondingInstance();
        factory = new ERC404Factory(
            ERC404Factory.CoreConfig({
                implementation: address(impl),
                masterRegistry: address(mockRegistry),
                instanceTemplate: mockInstanceTemplate,
                v4PoolManager: mockV4PoolManager,
                weth: mockWETH,
                protocol: protocolAdmin
            }),
            ERC404Factory.ModuleConfig({
                stakingModule: address(stakingModule),
                liquidityDeployer: address(0x600),
                globalMessageRegistry: mockGMR,
                launchManager: address(launchMgr),
                curveComputer: address(curveComp),
                tierGatingModule: address(0),
                componentRegistry: address(componentRegistry)
            })
        );

        factory.setProfile(DEFAULT_PROFILE_ID, ERC404Factory.GraduationProfile({
            targetETH: 15 ether,
            unitPerNFT: 1e6,
            poolFee: 3000,
            tickSpacing: 60,
            liquidityReserveBps: 2000,
            active: true
        }));

        vm.stopPrank();
    }

    // ========================
    // Helper: build default IdentityParams
    // ========================

    function _identity(
        string memory name_,
        string memory symbol_,
        address owner_
    ) internal view returns (IdentityParams memory) {
        return IdentityParams({
            owner: owner_,
            nftCount: DEFAULT_NFT_COUNT,
            profileId: uint8(DEFAULT_PROFILE_ID),
            vault: address(mockVault),
            name: name_,
            symbol: symbol_,
            styleUri: ""
        });
    }

    // ========================
    // Instance Creation Tests
    // ========================

    function test_createInstance_successfulCreation() public {
        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);
        address instance = factory.createInstance{value: INSTANCE_CREATION_FEE}(
            _identity("TestToken", "TEST", creator1),
            "ipfs://metadata",
            ERC404Factory.CreationTier.STANDARD
        );
        assertTrue(instance != address(0), "Instance should be created");
        vm.stopPrank();
    }

    function test_createInstance_withVaultAndHook() public {
        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);
        address instance = factory.createInstance{value: INSTANCE_CREATION_FEE}(
            _identity("TestToken", "TEST", creator1),
            "ipfs://metadata",
            ERC404Factory.CreationTier.STANDARD
        );
        assertTrue(instance != address(0));
        vm.stopPrank();
    }

    function test_createInstance_vaultRequired() public {
        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);
        vm.expectRevert("Vault required");
        factory.createInstance{value: INSTANCE_CREATION_FEE}(
            IdentityParams({
                owner: creator1,
                nftCount: DEFAULT_NFT_COUNT,
                profileId: uint8(DEFAULT_PROFILE_ID),
                vault: address(0), // no vault
                name: "TestToken",
                symbol: "TEST",
                styleUri: ""
            }),
            "ipfs://metadata",
            ERC404Factory.CreationTier.STANDARD
        );
        vm.stopPrank();
    }

    function test_createInstance_hookRequired() public {
        MockVaultNoHook noHookVault = new MockVaultNoHook();
        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);
        vm.expectRevert("Vault hook required");
        factory.createInstance{value: INSTANCE_CREATION_FEE}(
            IdentityParams({
                owner: creator1,
                nftCount: DEFAULT_NFT_COUNT,
                profileId: uint8(DEFAULT_PROFILE_ID),
                vault: address(noHookVault), // vault returns hook = address(0)
                name: "TestToken",
                symbol: "TEST",
                styleUri: ""
            }),
            "ipfs://metadata",
            ERC404Factory.CreationTier.STANDARD
        );
        vm.stopPrank();
    }

    function test_createInstance_invalidName() public {
        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);
        vm.expectRevert("Invalid name");
        factory.createInstance{value: INSTANCE_CREATION_FEE}(
            _identity("", "TEST", creator1),
            "ipfs://metadata",
            ERC404Factory.CreationTier.STANDARD
        );
        vm.stopPrank();
    }

    function test_createInstance_invalidSymbol() public {
        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);
        vm.expectRevert("Invalid symbol");
        factory.createInstance{value: INSTANCE_CREATION_FEE}(
            _identity("TestToken", "", creator1),
            "ipfs://metadata",
            ERC404Factory.CreationTier.STANDARD
        );
        vm.stopPrank();
    }

    function test_createInstance_invalidNftCount() public {
        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);
        vm.expectRevert("Invalid NFT count");
        factory.createInstance{value: INSTANCE_CREATION_FEE}(
            IdentityParams({
                owner: creator1,
                nftCount: 0, // invalid
                profileId: uint8(DEFAULT_PROFILE_ID),
                vault: address(mockVault),
                name: "TestToken",
                symbol: "TEST",
                styleUri: ""
            }),
            "ipfs://metadata",
            ERC404Factory.CreationTier.STANDARD
        );
        vm.stopPrank();
    }

    function test_createInstance_invalidCreator() public {
        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);
        vm.expectRevert("Invalid owner");
        factory.createInstance{value: INSTANCE_CREATION_FEE}(
            IdentityParams({
                owner: address(0), // invalid
                nftCount: DEFAULT_NFT_COUNT,
                profileId: uint8(DEFAULT_PROFILE_ID),
                vault: address(mockVault),
                name: "TestToken",
                symbol: "TEST",
                styleUri: ""
            }),
            "ipfs://metadata",
            ERC404Factory.CreationTier.STANDARD
        );
        vm.stopPrank();
    }

    function test_createInstance_v4PoolManagerNotSet() public {
        vm.startPrank(protocolAdmin);
        ERC404BondingInstance implBadPM = new ERC404BondingInstance();
        ERC404Factory factoryBadPoolManager = new ERC404Factory(
            ERC404Factory.CoreConfig({
                implementation: address(implBadPM),
                masterRegistry: address(mockRegistry),
                instanceTemplate: mockInstanceTemplate,
                v4PoolManager: address(0), // missing
                weth: mockWETH,
                protocol: protocolAdmin
            }),
            ERC404Factory.ModuleConfig({
                stakingModule: address(stakingModule),
                liquidityDeployer: address(0x600),
                globalMessageRegistry: mockGMR,
                launchManager: address(launchMgr),
                curveComputer: address(curveComp),
                tierGatingModule: address(0),
                componentRegistry: address(0)
            })
        );
        factoryBadPoolManager.setProfile(DEFAULT_PROFILE_ID, ERC404Factory.GraduationProfile({
            targetETH: 15 ether, unitPerNFT: 1e6, poolFee: 3000,
            tickSpacing: 60, liquidityReserveBps: 2000, active: true
        }));
        vm.stopPrank();

        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);
        vm.expectRevert(InvalidPoolManager.selector);
        factoryBadPoolManager.createInstance{value: INSTANCE_CREATION_FEE}(
            _identity("TestToken", "TEST", creator1),
            "ipfs://metadata",
            ERC404Factory.CreationTier.STANDARD
        );
        vm.stopPrank();
    }

    function test_createInstance_wethNotSet() public {
        vm.startPrank(protocolAdmin);
        ERC404BondingInstance implBadWeth = new ERC404BondingInstance();
        ERC404Factory factoryBadWeth = new ERC404Factory(
            ERC404Factory.CoreConfig({
                implementation: address(implBadWeth),
                masterRegistry: address(mockRegistry),
                instanceTemplate: mockInstanceTemplate,
                v4PoolManager: mockV4PoolManager,
                weth: address(0), // missing
                protocol: protocolAdmin
            }),
            ERC404Factory.ModuleConfig({
                stakingModule: address(stakingModule),
                liquidityDeployer: address(0x600),
                globalMessageRegistry: mockGMR,
                launchManager: address(launchMgr),
                curveComputer: address(curveComp),
                tierGatingModule: address(0),
                componentRegistry: address(0)
            })
        );
        factoryBadWeth.setProfile(DEFAULT_PROFILE_ID, ERC404Factory.GraduationProfile({
            targetETH: 15 ether, unitPerNFT: 1e6, poolFee: 3000,
            tickSpacing: 60, liquidityReserveBps: 2000, active: true
        }));
        vm.stopPrank();

        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);
        vm.expectRevert(InvalidWETH.selector);
        factoryBadWeth.createInstance{value: INSTANCE_CREATION_FEE}(
            _identity("TestToken", "TEST", creator1),
            "ipfs://metadata",
            ERC404Factory.CreationTier.STANDARD
        );
        vm.stopPrank();
    }

    // ========================
    // Infrastructure Tests
    // ========================

    function test_masterRegistry_initialization() public view {
        assertEq(address(factory.masterRegistry()), address(mockRegistry));
    }

    function test_v4PoolManager_initialization() public view {
        assertEq(factory.v4PoolManager(), mockV4PoolManager);
    }

    function test_weth_initialization() public view {
        assertEq(factory.weth(), mockWETH);
    }

    function test_getFeatures() public view {
        bytes32[] memory factoryFeatures = factory.getFeatures();
        assertTrue(factoryFeatures.length > 0, "Factory should have features");
    }

    // ========================
    // Multiple Instances Tests
    // ========================

    function test_createInstance_multipleSequential() public {
        vm.deal(creator1, 1 ether);
        vm.deal(creator2, 1 ether);

        vm.startPrank(creator1);
        address instance1 = factory.createInstance{value: INSTANCE_CREATION_FEE}(
            _identity("Token1", "TK1", creator1),
            "ipfs://metadata1",
            ERC404Factory.CreationTier.STANDARD
        );
        vm.stopPrank();

        vm.startPrank(creator2);
        address instance2 = factory.createInstance{value: INSTANCE_CREATION_FEE}(
            _identity("Token2", "TK2", creator2),
            "ipfs://metadata2",
            ERC404Factory.CreationTier.STANDARD
        );
        vm.stopPrank();

        assertTrue(instance1 != address(0));
        assertTrue(instance2 != address(0));
        assertTrue(instance1 != instance2);
    }

    function test_createInstance_eventEmission() public {
        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);
        vm.expectEmit(false, true, true, false);
        emit InstanceCreated(address(0), creator1, "EventToken", "EVT", address(mockVault), address(mockHook));
        factory.createInstance{value: INSTANCE_CREATION_FEE}(
            _identity("EventToken", "EVT", creator1),
            "ipfs://metadata",
            ERC404Factory.CreationTier.STANDARD
        );
        vm.stopPrank();
    }

    // ========================
    // Reentrancy Tests
    // ========================

    function test_createInstance_nonReentrant() public {
        vm.deal(creator1, 2 ether);
        vm.startPrank(creator1);

        address instance1 = factory.createInstance{value: INSTANCE_CREATION_FEE}(
            _identity("Token1", "TK1", creator1),
            "ipfs://metadata1",
            ERC404Factory.CreationTier.STANDARD
        );
        assertTrue(instance1 != address(0));

        address instance2 = factory.createInstance{value: INSTANCE_CREATION_FEE}(
            _identity("Token2", "TK2", creator1),
            "ipfs://metadata2",
            ERC404Factory.CreationTier.STANDARD
        );
        assertTrue(instance2 != address(0));
        vm.stopPrank();
    }

    function test_instanceTemplate_initialization() public view {
        assertEq(factory.instanceTemplate(), mockInstanceTemplate);
    }

    function test_createInstance_differentCreator() public {
        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);
        address instance = factory.createInstance{value: INSTANCE_CREATION_FEE}(
            _identity("TestToken", "TEST", creator2), // owner = creator2, sender = creator1
            "ipfs://metadata",
            ERC404Factory.CreationTier.STANDARD
        );
        assertTrue(instance != address(0));
        vm.stopPrank();
    }

    // ========================
    // Protocol Treasury Tests
    // ========================

    function test_SetProtocolTreasury() public {
        vm.startPrank(protocolAdmin);
        factory.setProtocolTreasury(address(0xBEEF));
        assertEq(factory.protocolTreasury(), address(0xBEEF));
        vm.stopPrank();
    }

    function test_SetProtocolTreasury_RevertNonOwner() public {
        vm.startPrank(nonOwner);
        vm.expectRevert();
        factory.setProtocolTreasury(address(0xBEEF));
        vm.stopPrank();
    }

    function test_SetProtocolTreasury_RevertZeroAddress() public {
        vm.startPrank(protocolAdmin);
        vm.expectRevert("Invalid treasury");
        factory.setProtocolTreasury(address(0));
        vm.stopPrank();
    }

    function test_WithdrawProtocolFees() public {
        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);
        factory.createInstance{value: INSTANCE_CREATION_FEE}(
            _identity("FeeToken", "FEE", creator1),
            "ipfs://metadata",
            ERC404Factory.CreationTier.STANDARD
        );
        vm.stopPrank();

        address treasury = address(0xBEEF);
        vm.startPrank(protocolAdmin);
        factory.setProtocolTreasury(treasury);
        assertEq(address(factory).balance, INSTANCE_CREATION_FEE);
        // All ETH goes to protocol (no creator split)
        uint256 expectedProtocolFees = INSTANCE_CREATION_FEE;
        factory.withdrawProtocolFees();
        assertEq(factory.accumulatedProtocolFees(), 0);
        assertEq(treasury.balance, expectedProtocolFees);
        vm.stopPrank();
    }

    function test_WithdrawProtocolFees_RevertNoTreasury() public {
        vm.startPrank(protocolAdmin);
        vm.expectRevert("Treasury not set");
        factory.withdrawProtocolFees();
        vm.stopPrank();
    }

    function test_WithdrawProtocolFees_RevertNoBalance() public {
        vm.startPrank(protocolAdmin);
        factory.setProtocolTreasury(address(0xBEEF));
        vm.expectRevert("No protocol fees");
        factory.withdrawProtocolFees();
        vm.stopPrank();
    }

    // ========================
    // Bonding Fee BPS Tests
    // ========================

    function test_SetBondingFeeBps() public {
        vm.startPrank(protocolAdmin);
        factory.setBondingFeeBps(200);
        assertEq(factory.bondingFeeBps(), 200);
        vm.stopPrank();
    }

    function test_SetBondingFeeBps_RevertExceedsCap() public {
        vm.startPrank(protocolAdmin);
        vm.expectRevert("Max 3%");
        factory.setBondingFeeBps(301);
        vm.stopPrank();
    }

    function test_SetBondingFeeBps_RevertNonOwner() public {
        vm.startPrank(nonOwner);
        vm.expectRevert();
        factory.setBondingFeeBps(200);
        vm.stopPrank();
    }

    function test_BondingFeeBps_DefaultValue() public view {
        assertEq(factory.bondingFeeBps(), 100);
    }

    // ========================
    // Tiered Creation Tests (via LaunchManager)
    // ========================

    function test_setTierConfig() public {
        vm.startPrank(protocolAdmin);
        LaunchManager.TierConfig memory config = LaunchManager.TierConfig({
            fee: 0.05 ether, featuredDuration: 7 days, featuredRankBoost: 10,
            badge: PromotionBadges.BadgeType.NONE, badgeDuration: 0
        });
        launchMgr.setTierConfig(LaunchManager.CreationTier.PREMIUM, config);

        (uint256 fee, uint256 featuredDuration, uint256 featuredRankBoost, PromotionBadges.BadgeType badge, uint256 badgeDuration) =
            launchMgr.tierConfigs(LaunchManager.CreationTier.PREMIUM);
        assertEq(fee, 0.05 ether);
        assertEq(featuredDuration, 7 days);
        assertEq(featuredRankBoost, 10);
        assertEq(uint256(badge), uint256(PromotionBadges.BadgeType.NONE));
        assertEq(badgeDuration, 0);
        vm.stopPrank();
    }

    function test_setTierConfig_revertZeroFee() public {
        vm.startPrank(protocolAdmin);
        LaunchManager.TierConfig memory config = LaunchManager.TierConfig({
            fee: 0, featuredDuration: 0, featuredRankBoost: 0,
            badge: PromotionBadges.BadgeType.NONE, badgeDuration: 0
        });
        vm.expectRevert("Fee must be positive");
        launchMgr.setTierConfig(LaunchManager.CreationTier.PREMIUM, config);
        vm.stopPrank();
    }

    function test_setTierConfig_revertNonOwner() public {
        vm.startPrank(nonOwner);
        LaunchManager.TierConfig memory config = LaunchManager.TierConfig({
            fee: 0.05 ether, featuredDuration: 0, featuredRankBoost: 0,
            badge: PromotionBadges.BadgeType.NONE, badgeDuration: 0
        });
        vm.expectRevert();
        launchMgr.setTierConfig(LaunchManager.CreationTier.PREMIUM, config);
        vm.stopPrank();
    }

    function test_createInstance_standardTierBackwardCompat() public {
        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);
        address instance = factory.createInstance{value: INSTANCE_CREATION_FEE}(
            _identity("StandardToken", "STD", creator1),
            "ipfs://metadata",
            ERC404Factory.CreationTier.STANDARD
        );
        assertTrue(instance != address(0));
        vm.stopPrank();
    }

    function test_createInstance_premiumTier() public {
        vm.startPrank(protocolAdmin);
        launchMgr.setTierConfig(LaunchManager.CreationTier.PREMIUM, LaunchManager.TierConfig({
            fee: 0.05 ether, featuredDuration: 0, featuredRankBoost: 0,
            badge: PromotionBadges.BadgeType.NONE, badgeDuration: 0
        }));
        vm.stopPrank();

        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);
        address instance = factory.createInstance{value: 0.05 ether}(
            _identity("PremiumToken", "PREM", creator1),
            "ipfs://metadata",
            ERC404Factory.CreationTier.PREMIUM
        );
        assertTrue(instance != address(0));
        assertEq(address(factory).balance, 0.05 ether);
        vm.stopPrank();
    }

    function test_createInstance_gracefulDegradation_noQueueOrBadges() public {
        vm.startPrank(protocolAdmin);
        launchMgr.setTierConfig(LaunchManager.CreationTier.LAUNCH, LaunchManager.TierConfig({
            fee: 0.1 ether, featuredDuration: 14 days, featuredRankBoost: 5,
            badge: PromotionBadges.BadgeType.HIGHLIGHT, badgeDuration: 14 days
        }));
        vm.stopPrank();

        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);
        address instance = factory.createInstance{value: 0.1 ether}(
            _identity("LaunchToken", "LNCH", creator1),
            "ipfs://metadata",
            ERC404Factory.CreationTier.LAUNCH
        );
        assertTrue(instance != address(0));
        vm.stopPrank();
    }

    function test_createInstance_launchTier_withBadgeAssignment() public {
        vm.startPrank(protocolAdmin);
        PromotionBadges badges = new PromotionBadges(address(0xBEEF));
        badges.setAuthorizedFactory(address(launchMgr), true);
        launchMgr.setPromotionBadges(address(badges));
        launchMgr.setTierConfig(LaunchManager.CreationTier.LAUNCH, LaunchManager.TierConfig({
            fee: 0.1 ether, featuredDuration: 0, featuredRankBoost: 0,
            badge: PromotionBadges.BadgeType.HIGHLIGHT, badgeDuration: 14 days
        }));
        vm.stopPrank();

        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);
        address instance = factory.createInstance{value: 0.1 ether}(
            _identity("BadgeToken", "BDG", creator1),
            "ipfs://metadata",
            ERC404Factory.CreationTier.LAUNCH
        );
        vm.stopPrank();

        (PromotionBadges.BadgeType badgeType, uint256 expiresAt) = badges.getActiveBadge(instance);
        assertEq(uint256(badgeType), uint256(PromotionBadges.BadgeType.HIGHLIGHT));
        assertEq(expiresAt, block.timestamp + 14 days);
    }

    // ========================
    // Role-Based Access Tests
    // ========================

    function test_protocolRole_canSetBondingFee() public {
        vm.startPrank(protocolAdmin);
        factory.setBondingFeeBps(200);
        assertEq(factory.bondingFeeBps(), 200);
        vm.stopPrank();
    }

    // ========================
    // Graduation Profile Tests
    // ========================

    function test_setProfile_protocolOnly() public {
        vm.startPrank(protocolAdmin);
        factory.setProfile(1, ERC404Factory.GraduationProfile({
            targetETH: 15 ether, unitPerNFT: 1e6, poolFee: 3000,
            tickSpacing: 60, liquidityReserveBps: 2000, active: true
        }));
        (uint256 targetETH, uint256 unitPerNFT, uint24 poolFee, int24 tickSpacing, uint256 liquidityReserveBps, bool active) = factory.profiles(1);
        assertEq(targetETH, 15 ether);
        assertEq(unitPerNFT, 1e6);
        assertEq(poolFee, 3000);
        assertEq(tickSpacing, 60);
        assertEq(liquidityReserveBps, 2000);
        assertTrue(active);
        vm.stopPrank();
    }

    function test_setProfile_creatorCannotSet() public {
        vm.startPrank(address(0xC1EA));
        vm.expectRevert();
        factory.setProfile(1, ERC404Factory.GraduationProfile({
            targetETH: 15 ether, unitPerNFT: 1e6, poolFee: 3000,
            tickSpacing: 60, liquidityReserveBps: 2000, active: true
        }));
        vm.stopPrank();
    }

    function test_setProfile_allThreeProfiles() public {
        vm.startPrank(protocolAdmin);
        factory.setProfile(0, ERC404Factory.GraduationProfile({
            targetETH: 5 ether, unitPerNFT: 1e9, poolFee: 10000,
            tickSpacing: 200, liquidityReserveBps: 2000, active: true
        }));
        factory.setProfile(1, ERC404Factory.GraduationProfile({
            targetETH: 15 ether, unitPerNFT: 1e6, poolFee: 3000,
            tickSpacing: 60, liquidityReserveBps: 2000, active: true
        }));
        factory.setProfile(2, ERC404Factory.GraduationProfile({
            targetETH: 30 ether, unitPerNFT: 1e3, poolFee: 3000,
            tickSpacing: 60, liquidityReserveBps: 2000, active: true
        }));
        (uint256 t0,,,,, bool a0) = factory.profiles(0);
        (uint256 t1,,,,, bool a1) = factory.profiles(1);
        (uint256 t2,,,,, bool a2) = factory.profiles(2);
        assertEq(t0, 5 ether);
        assertEq(t1, 15 ether);
        assertEq(t2, 30 ether);
        assertTrue(a0 && a1 && a2);
        vm.stopPrank();
    }

    // ========================
    // Curve Params Tests (now on CurveParamsComputer)
    // ========================

    function test_computeCurveParams_standardProfile() public view {
        uint256 nftCount = 100;
        BondingCurveMath.Params memory params = curveComp.computeCurveParams(nftCount, 15 ether, 1e6, 2000);
        uint256 totalSupply = nftCount * 1e6 * 1e18;
        uint256 maxBondingSupply = totalSupply - (totalSupply * 2000) / 10000;
        uint256 totalCost = BondingCurveMath.calculateCost(params, 0, maxBondingSupply);
        assertApproxEqRel(totalCost, 15 ether, 0.01e18);
    }

    function test_computeCurveParams_nicheProfile() public view {
        uint256 nftCount = 50;
        BondingCurveMath.Params memory params = curveComp.computeCurveParams(nftCount, 5 ether, 1e9, 2000);
        uint256 totalSupply = nftCount * 1e9 * 1e18;
        uint256 maxBondingSupply = totalSupply - (totalSupply * 2000) / 10000;
        uint256 totalCost = BondingCurveMath.calculateCost(params, 0, maxBondingSupply);
        assertApproxEqRel(totalCost, 5 ether, 0.01e18);
    }

    function test_computeCurveParams_ambitiousProfile() public view {
        uint256 nftCount = 500;
        BondingCurveMath.Params memory params = curveComp.computeCurveParams(nftCount, 30 ether, 1e3, 2000);
        uint256 totalSupply = nftCount * 1e3 * 1e18;
        uint256 maxBondingSupply = totalSupply - (totalSupply * 2000) / 10000;
        uint256 totalCost = BondingCurveMath.calculateCost(params, 0, maxBondingSupply);
        assertApproxEqRel(totalCost, 30 ether, 0.01e18);
    }

    // ========================
    // createInstance with profile Tests
    // ========================

    function _setupStandardProfile() internal {
        vm.startPrank(protocolAdmin);
        factory.setProfile(1, ERC404Factory.GraduationProfile({
            targetETH: 15 ether, unitPerNFT: 1e6, poolFee: 3000,
            tickSpacing: 60, liquidityReserveBps: 2000, active: true
        }));
        vm.stopPrank();
    }

    function test_createInstance_withProfile() public {
        _setupStandardProfile();
        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);
        address instance = factory.createInstance{value: INSTANCE_CREATION_FEE}(
            IdentityParams({
                owner: creator1,
                nftCount: 100,
                profileId: uint8(1),
                vault: address(mockVault),
                name: "TestToken",
                symbol: "TEST",
                styleUri: ""
            }),
            "ipfs://metadata",
            ERC404Factory.CreationTier.STANDARD
        );
        assertTrue(instance != address(0));
        ERC404BondingInstance inst = ERC404BondingInstance(payable(instance));
        assertEq(inst.MAX_SUPPLY(), 100 * 1e6 * 1e18);
        assertEq(inst.UNIT(), 1e6 * 1e18);
        assertEq(inst.poolFee(), 3000);
        assertEq(inst.tickSpacing(), 60);
        vm.stopPrank();
    }

    function test_createInstance_inactiveProfileReverts() public {
        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);
        vm.expectRevert("Profile not active");
        factory.createInstance{value: INSTANCE_CREATION_FEE}(
            IdentityParams({
                owner: creator1,
                nftCount: 100,
                profileId: uint8(5), // inactive profile
                vault: address(mockVault),
                name: "TestToken",
                symbol: "TEST",
                styleUri: ""
            }),
            "ipfs://metadata",
            ERC404Factory.CreationTier.STANDARD
        );
        vm.stopPrank();
    }

    function test_createInstance_zeroNftCountReverts() public {
        _setupStandardProfile();
        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);
        vm.expectRevert("Invalid NFT count");
        factory.createInstance{value: INSTANCE_CREATION_FEE}(
            IdentityParams({
                owner: creator1,
                nftCount: 0, // invalid
                profileId: uint8(1),
                vault: address(mockVault),
                name: "TestToken",
                symbol: "TEST",
                styleUri: ""
            }),
            "ipfs://metadata",
            ERC404Factory.CreationTier.STANDARD
        );
        vm.stopPrank();
    }

    // ── ComponentRegistry validation ──────────────────────────────────────────

    function test_createInstanceWithGating_revertsOnUnapprovedModule() public {
        address unapprovedModule = address(0xBAD6A7);
        _setupStandardProfile();

        vm.deal(creator1, 1 ether);
        vm.prank(creator1);
        vm.expectRevert("Unapproved component");
        factory.createInstance{value: INSTANCE_CREATION_FEE}(
            _identity("TestToken", "TEST", creator1),
            "ipfs://Qmtest",
            unapprovedModule,
            ERC404Factory.CreationTier.STANDARD
        );
    }

    function test_createInstanceWithGating_succeedsWithApprovedModule() public {
        _setupStandardProfile();
        address gatingModule = address(new PasswordTierGatingModule());
        vm.prank(protocolAdmin);
        componentRegistry.approveComponent(gatingModule, keccak256("gating"), "PasswordTierGating");

        vm.deal(creator1, 1 ether);
        vm.prank(creator1);
        address instance = factory.createInstance{value: INSTANCE_CREATION_FEE}(
            _identity("GatedToken", "GATE", creator1),
            "ipfs://Qmtest",
            gatingModule,
            ERC404Factory.CreationTier.STANDARD
        );

        assertTrue(instance != address(0));
    }

    function test_createInstanceWithGating_zeroAddressSkipsValidation() public {
        _setupStandardProfile();

        vm.deal(creator1, 1 ether);
        vm.prank(creator1);
        address instance = factory.createInstance{value: INSTANCE_CREATION_FEE}(
            _identity("OpenToken", "OPEN", creator1),
            "ipfs://Qmtest",
            address(0),
            ERC404Factory.CreationTier.STANDARD
        );

        assertTrue(instance != address(0));
    }

    function test_createInstance_noGating_stillWorks() public {
        _setupStandardProfile();

        vm.deal(creator1, 1 ether);
        vm.prank(creator1);
        address instance = factory.createInstance{value: INSTANCE_CREATION_FEE}(
            _identity("OpenToken2", "OPEN2", creator1),
            "ipfs://Qmtest",
            ERC404Factory.CreationTier.STANDARD
        );

        assertTrue(instance != address(0));
    }
}
