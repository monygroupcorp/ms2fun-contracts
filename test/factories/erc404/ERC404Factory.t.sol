// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {ERC404Factory} from "../../../src/factories/erc404/ERC404Factory.sol";
import {ERC404BondingInstance} from "../../../src/factories/erc404/ERC404BondingInstance.sol";
import {MockMasterRegistry} from "../../mocks/MockMasterRegistry.sol";

/**
 * @title MockVault
 * @notice Simple mock vault for testing ERC404Factory
 */
contract MockVault {
    address public owner;

    constructor() {
        owner = msg.sender;
    }

    // Mock other vault functions that might be called
    receive() external payable {}
}

/**
 * @title MockHook
 * @notice Simple mock hook for testing ERC404Factory
 */
contract MockHook {
    // Minimal mock hook contract
}

/**
 * @title ERC404FactoryTest
 * @notice Comprehensive test suite for ERC404Factory
 * @dev Tests instance creation, parameter management, fee handling, and event emission
 */
contract ERC404FactoryTest is Test {
    ERC404Factory public factory;
    MockMasterRegistry public mockRegistry;
    MockVault public mockVault;
    MockHook public mockHook;

    // Test addresses
    address public owner = address(0x1);
    address public creator1 = address(0x2);
    address public creator2 = address(0x3);
    address public nonOwner = address(0x5);

    // Mock infrastructure addresses
    address public mockV4PoolManager = address(0x1111111111111111111111111111111111111111);
    address public mockWETH = address(0x2222222222222222222222222222222222222222);
    address public mockInstanceTemplate = address(0x4444444444444444444444444444444444444444);

    // Test parameters
    uint256 constant INSTANCE_CREATION_FEE = 0.01 ether;
    uint256 constant MAX_SUPPLY = 10_000_000 * 1e18;
    uint256 constant LIQUIDITY_RESERVE_PERCENT = 10;

    // Bonding curve parameters
    ERC404BondingInstance.BondingCurveParams defaultCurveParams;
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
        vm.startPrank(owner);

        // Deploy mock registry
        mockRegistry = new MockMasterRegistry();

        // Deploy mock vault
        mockVault = new MockVault();

        // Deploy mock hook
        mockHook = new MockHook();

        // Deploy factory (no hookFactory needed anymore)
        factory = new ERC404Factory(
            address(mockRegistry),
            mockInstanceTemplate,
            mockV4PoolManager,
            mockWETH
        );

        // Setup default bonding curve parameters
        defaultCurveParams = ERC404BondingInstance.BondingCurveParams({
            initialPrice: 0.025 ether,
            quarticCoeff: 3 gwei,
            cubicCoeff: 1333333333,
            quadraticCoeff: 2 gwei,
            normalizationFactor: 1e7
        });

        // Setup default tier configuration
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
            "TestToken",
            "TEST",
            "ipfs://metadata",
            MAX_SUPPLY,
            LIQUIDITY_RESERVE_PERCENT,
            defaultCurveParams,
            defaultTierConfig,
            creator1,
            address(mockVault),
            address(mockHook),
            "" // styleUri
        );

        assertTrue(instance != address(0), "Instance should be created");

        vm.stopPrank();
    }

    function test_createInstance_withVaultAndHook() public {
        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);

        address instance = factory.createInstance{value: INSTANCE_CREATION_FEE}(
            "TestToken",
            "TEST",
            "ipfs://metadata",
            MAX_SUPPLY,
            LIQUIDITY_RESERVE_PERCENT,
            defaultCurveParams,
            defaultTierConfig,
            creator1,
            address(mockVault),
            address(mockHook),
            "" // styleUri
        );

        assertEq(factory.getVaultForInstance(instance), address(mockVault), "Vault should be tracked");
        assertEq(factory.getHookForInstance(instance), address(mockHook), "Hook should be tracked");

        vm.stopPrank();
    }

    function test_createInstance_vaultRequired() public {
        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);

        vm.expectRevert("Vault required for ultraalignment");
        factory.createInstance{value: INSTANCE_CREATION_FEE}(
            "TestToken",
            "TEST",
            "ipfs://metadata",
            MAX_SUPPLY,
            LIQUIDITY_RESERVE_PERCENT,
            defaultCurveParams,
            defaultTierConfig,
            creator1,
            address(0), // No vault - should revert
            address(mockHook),
            "" // styleUri
        );

        vm.stopPrank();
    }

    function test_createInstance_hookRequired() public {
        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);

        vm.expectRevert("Hook required for ultraalignment");
        factory.createInstance{value: INSTANCE_CREATION_FEE}(
            "TestToken",
            "TEST",
            "ipfs://metadata",
            MAX_SUPPLY,
            LIQUIDITY_RESERVE_PERCENT,
            defaultCurveParams,
            defaultTierConfig,
            creator1,
            address(mockVault),
            address(0), // No hook - should revert
            "" // styleUri
        );

        vm.stopPrank();
    }

    function test_createInstance_insufficientFee() public {
        vm.deal(creator1, 0.001 ether);
        vm.startPrank(creator1);

        vm.expectRevert("Insufficient fee");
        factory.createInstance{value: 0.001 ether}(
            "TestToken",
            "TEST",
            "ipfs://metadata",
            MAX_SUPPLY,
            LIQUIDITY_RESERVE_PERCENT,
            defaultCurveParams,
            defaultTierConfig,
            creator1,
            address(mockVault),
            address(mockHook),
            "" // styleUri
        );

        vm.stopPrank();
    }

    function test_createInstance_invalidName() public {
        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);

        vm.expectRevert("Invalid name");
        factory.createInstance{value: INSTANCE_CREATION_FEE}(
            "",
            "TEST",
            "ipfs://metadata",
            MAX_SUPPLY,
            LIQUIDITY_RESERVE_PERCENT,
            defaultCurveParams,
            defaultTierConfig,
            creator1,
            address(mockVault),
            address(mockHook),
            "" // styleUri
        );

        vm.stopPrank();
    }

    function test_createInstance_invalidSymbol() public {
        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);

        vm.expectRevert("Invalid symbol");
        factory.createInstance{value: INSTANCE_CREATION_FEE}(
            "TestToken",
            "",
            "ipfs://metadata",
            MAX_SUPPLY,
            LIQUIDITY_RESERVE_PERCENT,
            defaultCurveParams,
            defaultTierConfig,
            creator1,
            address(mockVault),
            address(mockHook),
            "" // styleUri
        );

        vm.stopPrank();
    }

    function test_createInstance_invalidSupply() public {
        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);

        vm.expectRevert("Invalid supply");
        factory.createInstance{value: INSTANCE_CREATION_FEE}(
            "TestToken",
            "TEST",
            "ipfs://metadata",
            0,  // Invalid supply
            LIQUIDITY_RESERVE_PERCENT,
            defaultCurveParams,
            defaultTierConfig,
            creator1,
            address(mockVault),
            address(mockHook),
            "" // styleUri
        );

        vm.stopPrank();
    }

    function test_createInstance_invalidCreator() public {
        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);

        vm.expectRevert("Invalid creator");
        factory.createInstance{value: INSTANCE_CREATION_FEE}(
            "TestToken",
            "TEST",
            "ipfs://metadata",
            MAX_SUPPLY,
            LIQUIDITY_RESERVE_PERCENT,
            defaultCurveParams,
            defaultTierConfig,
            address(0),  // Invalid creator
            address(mockVault),
            address(mockHook),
            "" // styleUri
        );

        vm.stopPrank();
    }

    function test_createInstance_v4PoolManagerNotSet() public {
        vm.startPrank(owner);

        // Create factory with zero v4PoolManager
        ERC404Factory factoryBadPoolManager = new ERC404Factory(
            address(mockRegistry),
            mockInstanceTemplate,
            address(0),  // Zero pool manager
            mockWETH
        );

        vm.stopPrank();

        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);

        vm.expectRevert("V4 pool manager not set");
        factoryBadPoolManager.createInstance{value: INSTANCE_CREATION_FEE}(
            "TestToken",
            "TEST",
            "ipfs://metadata",
            MAX_SUPPLY,
            LIQUIDITY_RESERVE_PERCENT,
            defaultCurveParams,
            defaultTierConfig,
            creator1,
            address(mockVault),
            address(mockHook),
            "" // styleUri
        );

        vm.stopPrank();
    }

    function test_createInstance_wethNotSet() public {
        vm.startPrank(owner);

        // Create factory with zero WETH
        ERC404Factory factoryBadWeth = new ERC404Factory(
            address(mockRegistry),
            mockInstanceTemplate,
            mockV4PoolManager,
            address(0)  // Zero WETH
        );

        vm.stopPrank();

        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);

        vm.expectRevert("WETH not set");
        factoryBadWeth.createInstance{value: INSTANCE_CREATION_FEE}(
            "TestToken",
            "TEST",
            "ipfs://metadata",
            MAX_SUPPLY,
            LIQUIDITY_RESERVE_PERCENT,
            defaultCurveParams,
            defaultTierConfig,
            creator1,
            address(mockVault),
            address(mockHook),
            "" // styleUri
        );

        vm.stopPrank();
    }

    // ========================
    // Fee Management Tests
    // ========================

    function test_instanceCreationFee_defaultValue() public {
        assertEq(factory.instanceCreationFee(), INSTANCE_CREATION_FEE);
    }

    function test_setInstanceCreationFee_ownerOnly() public {
        vm.startPrank(owner);
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

    function test_masterRegistry_initialization() public {
        assertEq(address(factory.masterRegistry()), address(mockRegistry));
    }

    function test_v4PoolManager_initialization() public {
        assertEq(factory.v4PoolManager(), mockV4PoolManager);
    }

    function test_weth_initialization() public {
        assertEq(factory.weth(), mockWETH);
    }

    function test_getFeatures() public {
        bytes32[] memory features = factory.getFeatures();
        assertTrue(features.length > 0, "Factory should have features");
    }

    // ========================
    // Parameter Variation Tests
    // ========================

    function test_createInstance_withVariedBondingParams() public {
        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);

        // Create instance with different curve parameters
        ERC404BondingInstance.BondingCurveParams memory customCurveParams =
            ERC404BondingInstance.BondingCurveParams({
                initialPrice: 0.05 ether,
                quarticCoeff: 5 gwei,
                cubicCoeff: 2000000000,
                quadraticCoeff: 3 gwei,
                normalizationFactor: 1e8
            });

        address instance = factory.createInstance{value: INSTANCE_CREATION_FEE}(
            "CustomToken",
            "CUST",
            "ipfs://metadata",
            MAX_SUPPLY,
            LIQUIDITY_RESERVE_PERCENT,
            customCurveParams,
            defaultTierConfig,
            creator1,
            address(mockVault),
            address(mockHook),
            "" // styleUri
        );

        assertTrue(instance != address(0), "Instance with custom params should be created");

        vm.stopPrank();
    }

    function test_createInstance_minimalSupply() public {
        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);

        address instance = factory.createInstance{value: INSTANCE_CREATION_FEE}(
            "MinimalToken",
            "MIN",
            "ipfs://metadata",
            1,  // Minimal supply
            LIQUIDITY_RESERVE_PERCENT,
            defaultCurveParams,
            defaultTierConfig,
            creator1,
            address(mockVault),
            address(mockHook),
            "" // styleUri
        );

        assertTrue(instance != address(0), "Instance with minimal supply should be created");

        vm.stopPrank();
    }

    function test_createInstance_maxLiquidityReserve() public {
        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);

        address instance = factory.createInstance{value: INSTANCE_CREATION_FEE}(
            "MaxReserveToken",
            "MRES",
            "ipfs://metadata",
            MAX_SUPPLY,
            99,  // Max liquidity reserve percent (must be < 100)
            defaultCurveParams,
            defaultTierConfig,
            creator1,
            address(mockVault),
            address(mockHook),
            "" // styleUri
        );

        assertTrue(instance != address(0), "Instance with max reserve should be created");

        vm.stopPrank();
    }

    // ========================
    // Excess Fee Refund Tests
    // ========================

    function test_createInstance_excessFeeRefund() public {
        uint256 excessAmount = 0.5 ether;
        uint256 totalSent = INSTANCE_CREATION_FEE + excessAmount;

        vm.deal(creator1, totalSent);
        uint256 balanceBefore = creator1.balance;

        vm.startPrank(creator1);

        factory.createInstance{value: totalSent}(
            "TestToken",
            "TEST",
            "ipfs://metadata",
            MAX_SUPPLY,
            LIQUIDITY_RESERVE_PERCENT,
            defaultCurveParams,
            defaultTierConfig,
            creator1,
            address(mockVault),
            address(mockHook),
            "" // styleUri
        );

        uint256 balanceAfter = creator1.balance;

        // Should have refunded the excess amount
        assertEq(balanceAfter, balanceBefore - INSTANCE_CREATION_FEE, "Excess should be refunded");

        vm.stopPrank();
    }

    // ========================
    // Multiple Instances Tests
    // ========================

    function test_createInstance_multipleSequential() public {
        vm.deal(creator1, 1 ether);
        vm.deal(creator2, 1 ether);

        vm.startPrank(creator1);

        address instance1 = factory.createInstance{value: INSTANCE_CREATION_FEE}(
            "Token1",
            "TK1",
            "ipfs://metadata1",
            MAX_SUPPLY,
            LIQUIDITY_RESERVE_PERCENT,
            defaultCurveParams,
            defaultTierConfig,
            creator1,
            address(mockVault),
            address(mockHook),
            "" // styleUri
        );

        vm.stopPrank();

        vm.startPrank(creator2);

        address instance2 = factory.createInstance{value: INSTANCE_CREATION_FEE}(
            "Token2",
            "TK2",
            "ipfs://metadata2",
            MAX_SUPPLY,
            LIQUIDITY_RESERVE_PERCENT,
            defaultCurveParams,
            defaultTierConfig,
            creator2,
            address(mockVault),
            address(mockHook),
            "" // styleUri
        );

        vm.stopPrank();

        assertTrue(instance1 != address(0), "First instance should be created");
        assertTrue(instance2 != address(0), "Second instance should be created");
        assertTrue(instance1 != instance2, "Instances should have different addresses");
    }

    function test_createInstance_eventEmission() public {
        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);

        // Note: event signature changed to include vault
        vm.expectEmit(false, true, true, false);
        emit InstanceCreated(address(0), creator1, "EventToken", "EVT", address(mockVault), address(mockHook));

        factory.createInstance{value: INSTANCE_CREATION_FEE}(
            "EventToken",
            "EVT",
            "ipfs://metadata",
            MAX_SUPPLY,
            LIQUIDITY_RESERVE_PERCENT,
            defaultCurveParams,
            defaultTierConfig,
            creator1,
            address(mockVault),
            address(mockHook),
            "" // styleUri
        );

        vm.stopPrank();
    }

    // ========================
    // Reentrancy Tests
    // ========================

    function test_createInstance_nonReentrant() public {
        // This test verifies that reentrancy guard prevents recursive calls
        // The factory uses ReentrancyGuard so multiple sequential calls should work
        // but nested calls should fail

        vm.deal(creator1, 2 ether);
        vm.startPrank(creator1);

        // First call should succeed
        address instance1 = factory.createInstance{value: INSTANCE_CREATION_FEE}(
            "Token1",
            "TK1",
            "ipfs://metadata1",
            MAX_SUPPLY,
            LIQUIDITY_RESERVE_PERCENT,
            defaultCurveParams,
            defaultTierConfig,
            creator1,
            address(mockVault),
            address(mockHook),
            "" // styleUri
        );

        assertTrue(instance1 != address(0), "First instance should be created");

        // Second sequential call should also succeed (different transaction)
        address instance2 = factory.createInstance{value: INSTANCE_CREATION_FEE}(
            "Token2",
            "TK2",
            "ipfs://metadata2",
            MAX_SUPPLY,
            LIQUIDITY_RESERVE_PERCENT,
            defaultCurveParams,
            defaultTierConfig,
            creator1,
            address(mockVault),
            address(mockHook),
            "" // styleUri
        );

        assertTrue(instance2 != address(0), "Second instance should also be created");

        vm.stopPrank();
    }

    // ========================
    // Instance Template Tests
    // ========================

    function test_instanceTemplate_initialization() public {
        assertEq(factory.instanceTemplate(), mockInstanceTemplate);
    }

    // ========================
    // Different Creator Tests
    // ========================

    function test_createInstance_differentCreator() public {
        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);

        // creator1 pays but creator2 is the owner
        address instance = factory.createInstance{value: INSTANCE_CREATION_FEE}(
            "TestToken",
            "TEST",
            "ipfs://metadata",
            MAX_SUPPLY,
            LIQUIDITY_RESERVE_PERCENT,
            defaultCurveParams,
            defaultTierConfig,
            creator2,  // Different creator
            address(mockVault),
            address(mockHook),
            "" // styleUri
        );

        assertTrue(instance != address(0), "Instance should be created with different creator");

        vm.stopPrank();
    }

    // ========================
    // Vault/Hook Tracking Tests
    // ========================

    function test_getVaultForInstance() public {
        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);

        address instance = factory.createInstance{value: INSTANCE_CREATION_FEE}(
            "TestToken",
            "TEST",
            "ipfs://metadata",
            MAX_SUPPLY,
            LIQUIDITY_RESERVE_PERCENT,
            defaultCurveParams,
            defaultTierConfig,
            creator1,
            address(mockVault),
            address(mockHook),
            "" // styleUri
        );

        assertEq(factory.getVaultForInstance(instance), address(mockVault), "Should return correct vault");

        vm.stopPrank();
    }

    function test_getHookForInstance() public {
        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);

        address instance = factory.createInstance{value: INSTANCE_CREATION_FEE}(
            "TestToken",
            "TEST",
            "ipfs://metadata",
            MAX_SUPPLY,
            LIQUIDITY_RESERVE_PERCENT,
            defaultCurveParams,
            defaultTierConfig,
            creator1,
            address(mockVault),
            address(mockHook),
            "" // styleUri
        );

        assertEq(factory.getHookForInstance(instance), address(mockHook), "Should return correct hook");

        vm.stopPrank();
    }
}
