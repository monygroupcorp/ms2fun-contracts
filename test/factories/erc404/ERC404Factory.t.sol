// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {ERC404Factory} from "../../../src/factories/erc404/ERC404Factory.sol";
import {ERC404BondingInstance} from "../../../src/factories/erc404/ERC404BondingInstance.sol";
import {ERC404StakingModule} from "../../../src/factories/erc404/ERC404StakingModule.sol";
import {LaunchManager} from "../../../src/factories/erc404/LaunchManager.sol";
import {CurveParamsComputer} from "../../../src/factories/erc404/CurveParamsComputer.sol";
import {MockMasterRegistry} from "../../mocks/MockMasterRegistry.sol";
import {PromotionBadges} from "../../../src/promotion/PromotionBadges.sol";
import {BondingCurveMath} from "../../../src/factories/erc404/libraries/BondingCurveMath.sol";

contract MockVault {
    address public owner;
    constructor() { owner = msg.sender; }
    receive() external payable {}
}

contract MockHook {}

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

    ERC404BondingInstance.TierConfig defaultTierConfig;

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
        mockVault = new MockVault();
        mockHook = new MockHook();
        stakingRegistry = new MockMasterRegistryForStakingF();
        stakingModule = new ERC404StakingModule(address(stakingRegistry));
        launchMgr = new LaunchManager(protocolAdmin);
        curveComp = new CurveParamsComputer(protocolAdmin);

        ERC404BondingInstance impl = new ERC404BondingInstance();
        factory = new ERC404Factory(
            address(impl),
            address(mockRegistry),
            mockInstanceTemplate,
            mockV4PoolManager,
            mockWETH,
            protocolAdmin,
            address(0xC1EA),
            2000,
            40,
            address(stakingModule),
            address(0x600),
            mockGMR,
            address(launchMgr),
            address(curveComp)
        );

        factory.setProfile(DEFAULT_PROFILE_ID, ERC404Factory.GraduationProfile({
            targetETH: 15 ether,
            unitPerNFT: 1e6,
            poolFee: 3000,
            tickSpacing: 60,
            liquidityReserveBps: 2000,
            active: true
        }));

        bytes32[] memory passwordHashes = new bytes32[](2);
        passwordHashes[0] = keccak256("password1");
        passwordHashes[1] = keccak256("password2");
        uint256[] memory volumeCaps = new uint256[](2);
        volumeCaps[0] = 1000 * 1e18;
        volumeCaps[1] = 10000 * 1e18;

        defaultTierConfig = ERC404BondingInstance.TierConfig({
            tierType: ERC404BondingInstance.TierType.VOLUME_CAP,
            passwordHashes: passwordHashes,
            volumeCaps: volumeCaps,
            tierUnlockTimes: new uint256[](0)
        });

        vm.stopPrank();
    }

    // ========================
    // Instance Creation Tests
    // ========================

    function test_createInstance_successfulCreation() public {
        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);
        address instance = factory.createInstance{value: INSTANCE_CREATION_FEE}(
            "TestToken", "TEST", "ipfs://metadata",
            DEFAULT_NFT_COUNT, DEFAULT_PROFILE_ID, defaultTierConfig,
            creator1, address(mockVault), address(mockHook), ""
        );
        assertTrue(instance != address(0), "Instance should be created");
        vm.stopPrank();
    }

    function test_createInstance_withVaultAndHook() public {
        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);
        address instance = factory.createInstance{value: INSTANCE_CREATION_FEE}(
            "TestToken", "TEST", "ipfs://metadata",
            DEFAULT_NFT_COUNT, DEFAULT_PROFILE_ID, defaultTierConfig,
            creator1, address(mockVault), address(mockHook), ""
        );
        assertTrue(instance != address(0));
        vm.stopPrank();
    }

    function test_createInstance_vaultRequired() public {
        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);
        vm.expectRevert("Vault required for ultraalignment");
        factory.createInstance{value: INSTANCE_CREATION_FEE}(
            "TestToken", "TEST", "ipfs://metadata",
            DEFAULT_NFT_COUNT, DEFAULT_PROFILE_ID, defaultTierConfig,
            creator1, address(0), address(mockHook), ""
        );
        vm.stopPrank();
    }

    function test_createInstance_hookRequired() public {
        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);
        vm.expectRevert("Hook required for ultraalignment");
        factory.createInstance{value: INSTANCE_CREATION_FEE}(
            "TestToken", "TEST", "ipfs://metadata",
            DEFAULT_NFT_COUNT, DEFAULT_PROFILE_ID, defaultTierConfig,
            creator1, address(mockVault), address(0), ""
        );
        vm.stopPrank();
    }

    function test_createInstance_insufficientFee() public {
        vm.deal(creator1, 0.001 ether);
        vm.startPrank(creator1);
        vm.expectRevert("Insufficient fee");
        factory.createInstance{value: 0.001 ether}(
            "TestToken", "TEST", "ipfs://metadata",
            DEFAULT_NFT_COUNT, DEFAULT_PROFILE_ID, defaultTierConfig,
            creator1, address(mockVault), address(mockHook), ""
        );
        vm.stopPrank();
    }

    function test_createInstance_invalidName() public {
        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);
        vm.expectRevert("Invalid name");
        factory.createInstance{value: INSTANCE_CREATION_FEE}(
            "", "TEST", "ipfs://metadata",
            DEFAULT_NFT_COUNT, DEFAULT_PROFILE_ID, defaultTierConfig,
            creator1, address(mockVault), address(mockHook), ""
        );
        vm.stopPrank();
    }

    function test_createInstance_invalidSymbol() public {
        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);
        vm.expectRevert("Invalid symbol");
        factory.createInstance{value: INSTANCE_CREATION_FEE}(
            "TestToken", "", "ipfs://metadata",
            DEFAULT_NFT_COUNT, DEFAULT_PROFILE_ID, defaultTierConfig,
            creator1, address(mockVault), address(mockHook), ""
        );
        vm.stopPrank();
    }

    function test_createInstance_invalidNftCount() public {
        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);
        vm.expectRevert("Invalid NFT count");
        factory.createInstance{value: INSTANCE_CREATION_FEE}(
            "TestToken", "TEST", "ipfs://metadata",
            0, DEFAULT_PROFILE_ID, defaultTierConfig,
            creator1, address(mockVault), address(mockHook), ""
        );
        vm.stopPrank();
    }

    function test_createInstance_invalidCreator() public {
        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);
        vm.expectRevert("Invalid creator");
        factory.createInstance{value: INSTANCE_CREATION_FEE}(
            "TestToken", "TEST", "ipfs://metadata",
            DEFAULT_NFT_COUNT, DEFAULT_PROFILE_ID, defaultTierConfig,
            address(0), address(mockVault), address(mockHook), ""
        );
        vm.stopPrank();
    }

    function test_createInstance_v4PoolManagerNotSet() public {
        vm.startPrank(protocolAdmin);
        ERC404BondingInstance implBadPM = new ERC404BondingInstance();
        ERC404Factory factoryBadPoolManager = new ERC404Factory(
            address(implBadPM), address(mockRegistry), mockInstanceTemplate, address(0), mockWETH,
            protocolAdmin, address(0xC1EA), 2000, 40,
            address(stakingModule), address(0x600), mockGMR, address(launchMgr), address(curveComp)
        );
        vm.stopPrank();

        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);
        vm.expectRevert("V4 pool manager not set");
        factoryBadPoolManager.createInstance{value: INSTANCE_CREATION_FEE}(
            "TestToken", "TEST", "ipfs://metadata",
            DEFAULT_NFT_COUNT, DEFAULT_PROFILE_ID, defaultTierConfig,
            creator1, address(mockVault), address(mockHook), ""
        );
        vm.stopPrank();
    }

    function test_createInstance_wethNotSet() public {
        vm.startPrank(protocolAdmin);
        ERC404BondingInstance implBadWeth = new ERC404BondingInstance();
        ERC404Factory factoryBadWeth = new ERC404Factory(
            address(implBadWeth), address(mockRegistry), mockInstanceTemplate, mockV4PoolManager, address(0),
            protocolAdmin, address(0xC1EA), 2000, 40,
            address(stakingModule), address(0x600), mockGMR, address(launchMgr), address(curveComp)
        );
        vm.stopPrank();

        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);
        vm.expectRevert("WETH not set");
        factoryBadWeth.createInstance{value: INSTANCE_CREATION_FEE}(
            "TestToken", "TEST", "ipfs://metadata",
            DEFAULT_NFT_COUNT, DEFAULT_PROFILE_ID, defaultTierConfig,
            creator1, address(mockVault), address(mockHook), ""
        );
        vm.stopPrank();
    }

    // ========================
    // Fee Management Tests
    // ========================

    function test_instanceCreationFee_defaultValue() public view {
        assertEq(factory.instanceCreationFee(), INSTANCE_CREATION_FEE);
    }

    function test_setInstanceCreationFee_ownerOnly() public {
        vm.startPrank(protocolAdmin);
        factory.setInstanceCreationFee(0.02 ether);
        assertEq(factory.instanceCreationFee(), 0.02 ether);
        vm.stopPrank();
    }

    function test_setInstanceCreationFee_nonOwnerFails() public {
        vm.startPrank(nonOwner);
        vm.expectRevert();
        factory.setInstanceCreationFee(0.02 ether);
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
    // Excess Fee Refund Tests
    // ========================

    function test_createInstance_excessFeeRefund() public {
        uint256 totalSent = INSTANCE_CREATION_FEE + 0.5 ether;
        vm.deal(creator1, totalSent);
        uint256 balanceBefore = creator1.balance;

        vm.startPrank(creator1);
        factory.createInstance{value: totalSent}(
            "TestToken", "TEST", "ipfs://metadata",
            DEFAULT_NFT_COUNT, DEFAULT_PROFILE_ID, defaultTierConfig,
            creator1, address(mockVault), address(mockHook), ""
        );
        vm.stopPrank();

        assertEq(creator1.balance, balanceBefore - INSTANCE_CREATION_FEE, "Excess should be refunded");
    }

    // ========================
    // Multiple Instances Tests
    // ========================

    function test_createInstance_multipleSequential() public {
        vm.deal(creator1, 1 ether);
        vm.deal(creator2, 1 ether);

        vm.startPrank(creator1);
        address instance1 = factory.createInstance{value: INSTANCE_CREATION_FEE}(
            "Token1", "TK1", "ipfs://metadata1",
            DEFAULT_NFT_COUNT, DEFAULT_PROFILE_ID, defaultTierConfig,
            creator1, address(mockVault), address(mockHook), ""
        );
        vm.stopPrank();

        vm.startPrank(creator2);
        address instance2 = factory.createInstance{value: INSTANCE_CREATION_FEE}(
            "Token2", "TK2", "ipfs://metadata2",
            DEFAULT_NFT_COUNT, DEFAULT_PROFILE_ID, defaultTierConfig,
            creator2, address(mockVault), address(mockHook), ""
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
            "EventToken", "EVT", "ipfs://metadata",
            DEFAULT_NFT_COUNT, DEFAULT_PROFILE_ID, defaultTierConfig,
            creator1, address(mockVault), address(mockHook), ""
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
            "Token1", "TK1", "ipfs://metadata1",
            DEFAULT_NFT_COUNT, DEFAULT_PROFILE_ID, defaultTierConfig,
            creator1, address(mockVault), address(mockHook), ""
        );
        assertTrue(instance1 != address(0));

        address instance2 = factory.createInstance{value: INSTANCE_CREATION_FEE}(
            "Token2", "TK2", "ipfs://metadata2",
            DEFAULT_NFT_COUNT, DEFAULT_PROFILE_ID, defaultTierConfig,
            creator1, address(mockVault), address(mockHook), ""
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
            "TestToken", "TEST", "ipfs://metadata",
            DEFAULT_NFT_COUNT, DEFAULT_PROFILE_ID, defaultTierConfig,
            creator2, address(mockVault), address(mockHook), ""
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
            "FeeToken", "FEE", "ipfs://metadata",
            DEFAULT_NFT_COUNT, DEFAULT_PROFILE_ID, defaultTierConfig,
            creator1, address(mockVault), address(mockHook), ""
        );
        vm.stopPrank();

        address treasury = address(0xBEEF);
        vm.startPrank(protocolAdmin);
        factory.setProtocolTreasury(treasury);
        assertEq(address(factory).balance, INSTANCE_CREATION_FEE);
        uint256 expectedProtocolFees = (INSTANCE_CREATION_FEE * 8000) / 10000;
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
    // Graduation Fee BPS Tests
    // ========================

    function test_GraduationFeeBps_DefaultValue() public view {
        assertEq(factory.graduationFeeBps(), 200);
    }

    function test_SetGraduationFeeBps() public {
        vm.startPrank(protocolAdmin);
        factory.setGraduationFeeBps(300);
        assertEq(factory.graduationFeeBps(), 300);
        vm.stopPrank();
    }

    function test_SetGraduationFeeBps_EmitsEvent() public {
        vm.startPrank(protocolAdmin);
        vm.expectEmit(false, false, false, true);
        emit ERC404Factory.GraduationFeeUpdated(400);
        factory.setGraduationFeeBps(400);
        vm.stopPrank();
    }

    function test_SetGraduationFeeBps_RevertExceedsCap() public {
        vm.startPrank(protocolAdmin);
        vm.expectRevert("Max 5%");
        factory.setGraduationFeeBps(501);
        vm.stopPrank();
    }

    function test_SetGraduationFeeBps_BoundaryAt500() public {
        vm.startPrank(protocolAdmin);
        factory.setGraduationFeeBps(500);
        assertEq(factory.graduationFeeBps(), 500);
        vm.stopPrank();
    }

    function test_SetGraduationFeeBps_ZeroAllowed() public {
        vm.startPrank(protocolAdmin);
        factory.setGraduationFeeBps(0);
        assertEq(factory.graduationFeeBps(), 0);
        vm.stopPrank();
    }

    function test_SetGraduationFeeBps_RevertNonOwner() public {
        vm.startPrank(nonOwner);
        vm.expectRevert();
        factory.setGraduationFeeBps(300);
        vm.stopPrank();
    }

    function test_GraduationFeeBps_PassedToInstance() public {
        vm.startPrank(protocolAdmin);
        factory.setGraduationFeeBps(350);
        vm.stopPrank();

        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);
        address instance = factory.createInstance{value: INSTANCE_CREATION_FEE}(
            "GradFeeToken", "GFT", "ipfs://metadata",
            DEFAULT_NFT_COUNT, DEFAULT_PROFILE_ID, defaultTierConfig,
            creator1, address(mockVault), address(mockHook), ""
        );
        vm.stopPrank();
        assertEq(ERC404BondingInstance(payable(instance)).graduationFeeBps(), 350);
    }

    // ========================
    // POL BPS Tests
    // ========================

    function test_PolBps_DefaultValue() public view {
        assertEq(factory.polBps(), 100);
    }

    function test_SetPolBps() public {
        vm.startPrank(protocolAdmin);
        factory.setPolBps(200);
        assertEq(factory.polBps(), 200);
        vm.stopPrank();
    }

    function test_SetPolBps_EmitsEvent() public {
        vm.startPrank(protocolAdmin);
        vm.expectEmit(false, false, false, true);
        emit ERC404Factory.POLConfigUpdated(250);
        factory.setPolBps(250);
        vm.stopPrank();
    }

    function test_SetPolBps_RevertExceedsCap() public {
        vm.startPrank(protocolAdmin);
        vm.expectRevert("Max 3%");
        factory.setPolBps(301);
        vm.stopPrank();
    }

    function test_SetPolBps_BoundaryAt300() public {
        vm.startPrank(protocolAdmin);
        factory.setPolBps(300);
        assertEq(factory.polBps(), 300);
        vm.stopPrank();
    }

    function test_SetPolBps_ZeroAllowed() public {
        vm.startPrank(protocolAdmin);
        factory.setPolBps(0);
        assertEq(factory.polBps(), 0);
        vm.stopPrank();
    }

    function test_SetPolBps_RevertNonOwner() public {
        vm.startPrank(nonOwner);
        vm.expectRevert();
        factory.setPolBps(200);
        vm.stopPrank();
    }

    function test_PolBps_PassedToInstance() public {
        vm.startPrank(protocolAdmin);
        factory.setPolBps(250);
        vm.stopPrank();

        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);
        address instance = factory.createInstance{value: INSTANCE_CREATION_FEE}(
            "POLToken", "POL", "ipfs://metadata",
            DEFAULT_NFT_COUNT, DEFAULT_PROFILE_ID, defaultTierConfig,
            creator1, address(mockVault), address(mockHook), ""
        );
        vm.stopPrank();
        assertEq(ERC404BondingInstance(payable(instance)).polBps(), 250);
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
            "StandardToken", "STD", "ipfs://metadata",
            DEFAULT_NFT_COUNT, DEFAULT_PROFILE_ID, defaultTierConfig,
            creator1, address(mockVault), address(mockHook), ""
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
            "PremiumToken", "PREM", "ipfs://metadata",
            DEFAULT_NFT_COUNT, DEFAULT_PROFILE_ID, defaultTierConfig,
            creator1, address(mockVault), address(mockHook), "",
            ERC404Factory.CreationTier.PREMIUM
        );
        assertTrue(instance != address(0));
        assertEq(address(factory).balance, 0.05 ether);
        vm.stopPrank();
    }

    function test_createInstance_premiumTier_insufficientFee() public {
        vm.startPrank(protocolAdmin);
        launchMgr.setTierConfig(LaunchManager.CreationTier.PREMIUM, LaunchManager.TierConfig({
            fee: 0.05 ether, featuredDuration: 0, featuredRankBoost: 0,
            badge: PromotionBadges.BadgeType.NONE, badgeDuration: 0
        }));
        vm.stopPrank();

        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);
        vm.expectRevert("Insufficient fee");
        factory.createInstance{value: 0.01 ether}(
            "PremiumToken", "PREM", "ipfs://metadata",
            DEFAULT_NFT_COUNT, DEFAULT_PROFILE_ID, defaultTierConfig,
            creator1, address(mockVault), address(mockHook), "",
            ERC404Factory.CreationTier.PREMIUM
        );
        vm.stopPrank();
    }

    function test_createInstance_tierNotConfigured() public {
        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);
        vm.expectRevert("Tier not configured");
        factory.createInstance{value: 0.1 ether}(
            "LaunchToken", "LNCH", "ipfs://metadata",
            DEFAULT_NFT_COUNT, DEFAULT_PROFILE_ID, defaultTierConfig,
            creator1, address(mockVault), address(mockHook), "",
            ERC404Factory.CreationTier.LAUNCH
        );
        vm.stopPrank();
    }

    function test_createInstance_premiumTier_refundsExcess() public {
        vm.startPrank(protocolAdmin);
        launchMgr.setTierConfig(LaunchManager.CreationTier.PREMIUM, LaunchManager.TierConfig({
            fee: 0.05 ether, featuredDuration: 0, featuredRankBoost: 0,
            badge: PromotionBadges.BadgeType.NONE, badgeDuration: 0
        }));
        vm.stopPrank();

        uint256 sent = 0.5 ether;
        vm.deal(creator1, sent);
        uint256 balanceBefore = creator1.balance;
        vm.startPrank(creator1);
        factory.createInstance{value: sent}(
            "RefundToken", "RFND", "ipfs://metadata",
            DEFAULT_NFT_COUNT, DEFAULT_PROFILE_ID, defaultTierConfig,
            creator1, address(mockVault), address(mockHook), "",
            ERC404Factory.CreationTier.PREMIUM
        );
        vm.stopPrank();
        assertEq(creator1.balance, balanceBefore - 0.05 ether);
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
            "LaunchToken", "LNCH", "ipfs://metadata",
            DEFAULT_NFT_COUNT, DEFAULT_PROFILE_ID, defaultTierConfig,
            creator1, address(mockVault), address(mockHook), "",
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
            "BadgeToken", "BDG", "ipfs://metadata",
            DEFAULT_NFT_COUNT, DEFAULT_PROFILE_ID, defaultTierConfig,
            creator1, address(mockVault), address(mockHook), "",
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

    function test_creatorRole_cannotSetBondingFee() public {
        vm.startPrank(address(0xC1EA));
        vm.expectRevert();
        factory.setBondingFeeBps(200);
        vm.stopPrank();
    }

    function test_creatorRole_canWithdrawCreatorFees() public {
        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);
        factory.createInstance{value: INSTANCE_CREATION_FEE}(
            "FeeToken", "FEE", "ipfs://metadata",
            DEFAULT_NFT_COUNT, DEFAULT_PROFILE_ID, defaultTierConfig,
            creator1, address(mockVault), address(mockHook), ""
        );
        vm.stopPrank();
        vm.startPrank(address(0xC1EA));
        factory.withdrawCreatorFees();
        vm.stopPrank();
    }

    function test_nonRole_cannotWithdrawCreatorFees() public {
        vm.startPrank(nonOwner);
        vm.expectRevert();
        factory.withdrawCreatorFees();
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
            "TestToken", "TEST", "ipfs://metadata",
            100, 1, defaultTierConfig,
            creator1, address(mockVault), address(mockHook), ""
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
            "TestToken", "TEST", "ipfs://metadata",
            100, 5, defaultTierConfig,
            creator1, address(mockVault), address(mockHook), ""
        );
        vm.stopPrank();
    }

    function test_createInstance_zeroNftCountReverts() public {
        _setupStandardProfile();
        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);
        vm.expectRevert("Invalid NFT count");
        factory.createInstance{value: INSTANCE_CREATION_FEE}(
            "TestToken", "TEST", "ipfs://metadata",
            0, 1, defaultTierConfig,
            creator1, address(mockVault), address(mockHook), ""
        );
        vm.stopPrank();
    }
}
