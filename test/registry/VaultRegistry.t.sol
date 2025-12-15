// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {VaultRegistry} from "../../src/registry/VaultRegistry.sol";

/**
 * @title VaultRegistryTest
 * @notice Comprehensive unit tests for VaultRegistry.sol
 * @dev Tests all 18 public/external functions with happy path and error conditions
 */
contract VaultRegistryTest is Test {
    VaultRegistry public registry;

    // Test accounts
    address public owner;
    address public user1;
    address public user2;

    // Mock contracts (need actual bytecode to pass contract checks)
    MockVault public mockVault1;
    MockVault public mockVault2;
    MockHook public mockHook1;
    MockHook public mockHook2;
    MockAnalytics public mockAnalytics;

    // Constants
    uint256 constant VAULT_FEE = 0.05 ether;
    uint256 constant HOOK_FEE = 0.02 ether;

    // Events to test
    event VaultRegistered(address indexed vault, address indexed creator, string name, uint256 fee);
    event HookRegistered(address indexed hook, address indexed creator, address indexed vault, string name, uint256 fee);
    event VaultDeactivated(address indexed vault);
    event HookDeactivated(address indexed hook);
    event AnalyticsModuleSet(address indexed newModule);
    event VaultFeeUpdated(uint256 newFee);
    event HookFeeUpdated(uint256 newFee);

    function setUp() public {
        owner = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        // Deploy registry
        registry = new VaultRegistry();

        // Deploy mock contracts
        mockVault1 = new MockVault();
        mockVault2 = new MockVault();
        mockHook1 = new MockHook();
        mockHook2 = new MockHook();
        mockAnalytics = new MockAnalytics();

        // Fund test accounts
        vm.deal(user1, 10 ether);
        vm.deal(user2, 10 ether);
    }

    // ============ Constructor & Initialization Tests ============

    function test_Constructor_InitializesOwner() public view {
        assertEq(registry.owner(), owner);
    }

    function test_Constructor_InitializesFees() public view {
        assertEq(registry.vaultRegistrationFee(), VAULT_FEE);
        assertEq(registry.hookRegistrationFee(), HOOK_FEE);
    }

    function test_Constructor_InitializesConstants() public view {
        assertEq(registry.VAULT_REGISTRATION_FEE(), VAULT_FEE);
        assertEq(registry.HOOK_REGISTRATION_FEE(), HOOK_FEE);
    }

    // ============ registerVault Tests ============

    function test_RegisterVault_Success() public {
        vm.prank(user1);
        vm.expectEmit(true, true, false, true);
        emit VaultRegistered(address(mockVault1), user1, "Test Vault", VAULT_FEE);

        registry.registerVault{value: VAULT_FEE}(
            address(mockVault1),
            "Test Vault",
            "https://metadata.uri"
        );

        // Verify registration
        assertTrue(registry.registeredVaults(address(mockVault1)));

        VaultRegistry.VaultInfo memory info = registry.getVaultInfo(address(mockVault1));
        assertEq(info.vault, address(mockVault1));
        assertEq(info.creator, user1);
        assertEq(info.name, "Test Vault");
        assertEq(info.metadataURI, "https://metadata.uri");
        assertTrue(info.active);
        assertEq(info.registeredAt, block.timestamp);
        assertEq(info.instanceCount, 0);
    }

    function test_RegisterVault_WithExcessFeeRefund() public {
        uint256 initialBalance = user1.balance;
        uint256 excessFee = VAULT_FEE + 0.1 ether;

        vm.prank(user1);
        registry.registerVault{value: excessFee}(
            address(mockVault1),
            "Test Vault",
            "https://metadata.uri"
        );

        // Verify refund
        assertEq(user1.balance, initialBalance - VAULT_FEE);
    }

    function test_RegisterVault_RevertsOnZeroAddress() public {
        vm.prank(user1);
        vm.expectRevert("Invalid vault address");
        registry.registerVault{value: VAULT_FEE}(
            address(0),
            "Test Vault",
            "https://metadata.uri"
        );
    }

    function test_RegisterVault_RevertsOnEmptyName() public {
        vm.prank(user1);
        vm.expectRevert("Invalid name");
        registry.registerVault{value: VAULT_FEE}(
            address(mockVault1),
            "",
            "https://metadata.uri"
        );
    }

    function test_RegisterVault_RevertsOnNameTooLong() public {
        string memory longName = new string(257);

        vm.prank(user1);
        vm.expectRevert("Invalid name");
        registry.registerVault{value: VAULT_FEE}(
            address(mockVault1),
            longName,
            "https://metadata.uri"
        );
    }

    function test_RegisterVault_RevertsOnInsufficientFee() public {
        vm.prank(user1);
        vm.expectRevert("Insufficient registration fee");
        registry.registerVault{value: VAULT_FEE - 1}(
            address(mockVault1),
            "Test Vault",
            "https://metadata.uri"
        );
    }

    function test_RegisterVault_RevertsOnDuplicateRegistration() public {
        vm.startPrank(user1);
        registry.registerVault{value: VAULT_FEE}(
            address(mockVault1),
            "Test Vault",
            "https://metadata.uri"
        );

        vm.expectRevert("Vault already registered");
        registry.registerVault{value: VAULT_FEE}(
            address(mockVault1),
            "Test Vault 2",
            "https://metadata.uri"
        );
        vm.stopPrank();
    }

    function test_RegisterVault_RevertsOnEmptyMetadataURI() public {
        vm.prank(user1);
        vm.expectRevert("Invalid metadata URI");
        registry.registerVault{value: VAULT_FEE}(
            address(mockVault1),
            "Test Vault",
            ""
        );
    }

    function test_RegisterVault_RevertsOnMetadataURITooLong() public {
        string memory longURI = new string(2049);

        vm.prank(user1);
        vm.expectRevert("Invalid metadata URI");
        registry.registerVault{value: VAULT_FEE}(
            address(mockVault1),
            "Test Vault",
            longURI
        );
    }

    function test_RegisterVault_RevertsOnNonContract() public {
        address notContract = makeAddr("notContract");

        vm.prank(user1);
        vm.expectRevert("Vault must be a contract");
        registry.registerVault{value: VAULT_FEE}(
            notContract,
            "Test Vault",
            "https://metadata.uri"
        );
    }

    function test_RegisterVault_UpdatesVaultList() public {
        vm.prank(user1);
        registry.registerVault{value: VAULT_FEE}(
            address(mockVault1),
            "Test Vault",
            "https://metadata.uri"
        );

        address[] memory vaultList = registry.getVaultList();
        assertEq(vaultList.length, 1);
        assertEq(vaultList[0], address(mockVault1));
    }

    // ============ registerHook Tests ============

    function test_RegisterHook_Success() public {
        // First register vault
        vm.prank(user1);
        registry.registerVault{value: VAULT_FEE}(
            address(mockVault1),
            "Test Vault",
            "https://vault.metadata.uri"
        );

        // Then register hook
        vm.prank(user2);
        vm.expectEmit(true, true, true, true);
        emit HookRegistered(address(mockHook1), user2, address(mockVault1), "Test Hook", HOOK_FEE);

        registry.registerHook{value: HOOK_FEE}(
            address(mockHook1),
            address(mockVault1),
            "Test Hook",
            "https://hook.metadata.uri"
        );

        // Verify registration
        assertTrue(registry.registeredHooks(address(mockHook1)));

        VaultRegistry.HookInfo memory info = registry.getHookInfo(address(mockHook1));
        assertEq(info.hook, address(mockHook1));
        assertEq(info.creator, user2);
        assertEq(info.vault, address(mockVault1));
        assertEq(info.name, "Test Hook");
        assertEq(info.metadataURI, "https://hook.metadata.uri");
        assertTrue(info.active);
        assertEq(info.registeredAt, block.timestamp);
        assertEq(info.instanceCount, 0);
    }

    function test_RegisterHook_WithExcessFeeRefund() public {
        // First register vault
        vm.prank(user1);
        registry.registerVault{value: VAULT_FEE}(
            address(mockVault1),
            "Test Vault",
            "https://vault.metadata.uri"
        );

        uint256 initialBalance = user2.balance;
        uint256 excessFee = HOOK_FEE + 0.05 ether;

        vm.prank(user2);
        registry.registerHook{value: excessFee}(
            address(mockHook1),
            address(mockVault1),
            "Test Hook",
            "https://hook.metadata.uri"
        );

        // Verify refund
        assertEq(user2.balance, initialBalance - HOOK_FEE);
    }

    function test_RegisterHook_RevertsOnZeroHookAddress() public {
        vm.prank(user1);
        registry.registerVault{value: VAULT_FEE}(
            address(mockVault1),
            "Test Vault",
            "https://vault.metadata.uri"
        );

        vm.prank(user2);
        vm.expectRevert("Invalid hook address");
        registry.registerHook{value: HOOK_FEE}(
            address(0),
            address(mockVault1),
            "Test Hook",
            "https://hook.metadata.uri"
        );
    }

    function test_RegisterHook_RevertsOnZeroVaultAddress() public {
        vm.prank(user2);
        vm.expectRevert("Invalid vault address");
        registry.registerHook{value: HOOK_FEE}(
            address(mockHook1),
            address(0),
            "Test Hook",
            "https://hook.metadata.uri"
        );
    }

    function test_RegisterHook_RevertsOnUnregisteredVault() public {
        vm.prank(user2);
        vm.expectRevert("Vault must be registered");
        registry.registerHook{value: HOOK_FEE}(
            address(mockHook1),
            address(mockVault1),
            "Test Hook",
            "https://hook.metadata.uri"
        );
    }

    function test_RegisterHook_RevertsOnEmptyName() public {
        vm.prank(user1);
        registry.registerVault{value: VAULT_FEE}(
            address(mockVault1),
            "Test Vault",
            "https://vault.metadata.uri"
        );

        vm.prank(user2);
        vm.expectRevert("Invalid name");
        registry.registerHook{value: HOOK_FEE}(
            address(mockHook1),
            address(mockVault1),
            "",
            "https://hook.metadata.uri"
        );
    }

    function test_RegisterHook_RevertsOnInsufficientFee() public {
        vm.prank(user1);
        registry.registerVault{value: VAULT_FEE}(
            address(mockVault1),
            "Test Vault",
            "https://vault.metadata.uri"
        );

        vm.prank(user2);
        vm.expectRevert("Insufficient registration fee");
        registry.registerHook{value: HOOK_FEE - 1}(
            address(mockHook1),
            address(mockVault1),
            "Test Hook",
            "https://hook.metadata.uri"
        );
    }

    function test_RegisterHook_RevertsOnDuplicateRegistration() public {
        vm.prank(user1);
        registry.registerVault{value: VAULT_FEE}(
            address(mockVault1),
            "Test Vault",
            "https://vault.metadata.uri"
        );

        vm.startPrank(user2);
        registry.registerHook{value: HOOK_FEE}(
            address(mockHook1),
            address(mockVault1),
            "Test Hook",
            "https://hook.metadata.uri"
        );

        vm.expectRevert("Hook already registered");
        registry.registerHook{value: HOOK_FEE}(
            address(mockHook1),
            address(mockVault1),
            "Test Hook 2",
            "https://hook.metadata.uri"
        );
        vm.stopPrank();
    }

    function test_RegisterHook_RevertsOnEmptyMetadataURI() public {
        vm.prank(user1);
        registry.registerVault{value: VAULT_FEE}(
            address(mockVault1),
            "Test Vault",
            "https://vault.metadata.uri"
        );

        vm.prank(user2);
        vm.expectRevert("Invalid metadata URI");
        registry.registerHook{value: HOOK_FEE}(
            address(mockHook1),
            address(mockVault1),
            "Test Hook",
            ""
        );
    }

    function test_RegisterHook_RevertsOnNonContract() public {
        vm.prank(user1);
        registry.registerVault{value: VAULT_FEE}(
            address(mockVault1),
            "Test Vault",
            "https://vault.metadata.uri"
        );

        address notContract = makeAddr("notContract");

        vm.prank(user2);
        vm.expectRevert("Hook must be a contract");
        registry.registerHook{value: HOOK_FEE}(
            notContract,
            address(mockVault1),
            "Test Hook",
            "https://hook.metadata.uri"
        );
    }

    function test_RegisterHook_UpdatesHookList() public {
        vm.prank(user1);
        registry.registerVault{value: VAULT_FEE}(
            address(mockVault1),
            "Test Vault",
            "https://vault.metadata.uri"
        );

        vm.prank(user2);
        registry.registerHook{value: HOOK_FEE}(
            address(mockHook1),
            address(mockVault1),
            "Test Hook",
            "https://hook.metadata.uri"
        );

        address[] memory hookList = registry.getHookList();
        assertEq(hookList.length, 1);
        assertEq(hookList[0], address(mockHook1));
    }

    function test_RegisterHook_UpdatesHooksByVault() public {
        vm.prank(user1);
        registry.registerVault{value: VAULT_FEE}(
            address(mockVault1),
            "Test Vault",
            "https://vault.metadata.uri"
        );

        vm.prank(user2);
        registry.registerHook{value: HOOK_FEE}(
            address(mockHook1),
            address(mockVault1),
            "Test Hook",
            "https://hook.metadata.uri"
        );

        address[] memory vaultHooks = registry.getHooksByVault(address(mockVault1));
        assertEq(vaultHooks.length, 1);
        assertEq(vaultHooks[0], address(mockHook1));
    }

    // ============ deactivateVault Tests ============

    function test_DeactivateVault_Success() public {
        vm.prank(user1);
        registry.registerVault{value: VAULT_FEE}(
            address(mockVault1),
            "Test Vault",
            "https://metadata.uri"
        );

        vm.expectEmit(true, false, false, false);
        emit VaultDeactivated(address(mockVault1));

        registry.deactivateVault(address(mockVault1));

        assertFalse(registry.isVaultRegistered(address(mockVault1)));
        VaultRegistry.VaultInfo memory info = registry.getVaultInfo(address(mockVault1));
        assertFalse(info.active);
    }

    function test_DeactivateVault_RevertsOnNonOwner() public {
        vm.prank(user1);
        registry.registerVault{value: VAULT_FEE}(
            address(mockVault1),
            "Test Vault",
            "https://metadata.uri"
        );

        vm.prank(user2);
        vm.expectRevert();
        registry.deactivateVault(address(mockVault1));
    }

    function test_DeactivateVault_RevertsOnUnregisteredVault() public {
        vm.expectRevert("Vault not registered");
        registry.deactivateVault(address(mockVault1));
    }

    // ============ deactivateHook Tests ============

    function test_DeactivateHook_Success() public {
        vm.prank(user1);
        registry.registerVault{value: VAULT_FEE}(
            address(mockVault1),
            "Test Vault",
            "https://vault.metadata.uri"
        );

        vm.prank(user2);
        registry.registerHook{value: HOOK_FEE}(
            address(mockHook1),
            address(mockVault1),
            "Test Hook",
            "https://hook.metadata.uri"
        );

        vm.expectEmit(true, false, false, false);
        emit HookDeactivated(address(mockHook1));

        registry.deactivateHook(address(mockHook1));

        assertFalse(registry.isHookRegistered(address(mockHook1)));
        VaultRegistry.HookInfo memory info = registry.getHookInfo(address(mockHook1));
        assertFalse(info.active);
    }

    function test_DeactivateHook_RevertsOnNonOwner() public {
        vm.prank(user1);
        registry.registerVault{value: VAULT_FEE}(
            address(mockVault1),
            "Test Vault",
            "https://vault.metadata.uri"
        );

        vm.prank(user2);
        registry.registerHook{value: HOOK_FEE}(
            address(mockHook1),
            address(mockVault1),
            "Test Hook",
            "https://hook.metadata.uri"
        );

        vm.prank(user1);
        vm.expectRevert();
        registry.deactivateHook(address(mockHook1));
    }

    function test_DeactivateHook_RevertsOnUnregisteredHook() public {
        vm.expectRevert("Hook not registered");
        registry.deactivateHook(address(mockHook1));
    }

    // ============ getVaultInfo Tests ============

    function test_GetVaultInfo_Success() public {
        vm.prank(user1);
        registry.registerVault{value: VAULT_FEE}(
            address(mockVault1),
            "Test Vault",
            "https://metadata.uri"
        );

        VaultRegistry.VaultInfo memory info = registry.getVaultInfo(address(mockVault1));
        assertEq(info.vault, address(mockVault1));
        assertEq(info.creator, user1);
        assertEq(info.name, "Test Vault");
        assertEq(info.metadataURI, "https://metadata.uri");
        assertTrue(info.active);
        assertEq(info.instanceCount, 0);
    }

    function test_GetVaultInfo_RevertsOnUnregisteredVault() public {
        vm.expectRevert("Vault not registered");
        registry.getVaultInfo(address(mockVault1));
    }

    // ============ getHookInfo Tests ============

    function test_GetHookInfo_Success() public {
        vm.prank(user1);
        registry.registerVault{value: VAULT_FEE}(
            address(mockVault1),
            "Test Vault",
            "https://vault.metadata.uri"
        );

        vm.prank(user2);
        registry.registerHook{value: HOOK_FEE}(
            address(mockHook1),
            address(mockVault1),
            "Test Hook",
            "https://hook.metadata.uri"
        );

        VaultRegistry.HookInfo memory info = registry.getHookInfo(address(mockHook1));
        assertEq(info.hook, address(mockHook1));
        assertEq(info.creator, user2);
        assertEq(info.vault, address(mockVault1));
        assertEq(info.name, "Test Hook");
        assertEq(info.metadataURI, "https://hook.metadata.uri");
        assertTrue(info.active);
        assertEq(info.instanceCount, 0);
    }

    function test_GetHookInfo_RevertsOnUnregisteredHook() public {
        vm.expectRevert("Hook not registered");
        registry.getHookInfo(address(mockHook1));
    }

    // ============ getVaultList Tests ============

    function test_GetVaultList_EmptyInitially() public view {
        address[] memory vaultList = registry.getVaultList();
        assertEq(vaultList.length, 0);
    }

    function test_GetVaultList_MultipleVaults() public {
        vm.prank(user1);
        registry.registerVault{value: VAULT_FEE}(
            address(mockVault1),
            "Test Vault 1",
            "https://metadata1.uri"
        );

        vm.prank(user2);
        registry.registerVault{value: VAULT_FEE}(
            address(mockVault2),
            "Test Vault 2",
            "https://metadata2.uri"
        );

        address[] memory vaultList = registry.getVaultList();
        assertEq(vaultList.length, 2);
        assertEq(vaultList[0], address(mockVault1));
        assertEq(vaultList[1], address(mockVault2));
    }

    // ============ getHookList Tests ============

    function test_GetHookList_EmptyInitially() public view {
        address[] memory hookList = registry.getHookList();
        assertEq(hookList.length, 0);
    }

    function test_GetHookList_MultipleHooks() public {
        vm.prank(user1);
        registry.registerVault{value: VAULT_FEE}(
            address(mockVault1),
            "Test Vault",
            "https://vault.metadata.uri"
        );

        vm.prank(user2);
        registry.registerHook{value: HOOK_FEE}(
            address(mockHook1),
            address(mockVault1),
            "Test Hook 1",
            "https://hook1.metadata.uri"
        );

        registry.registerHook{value: HOOK_FEE}(
            address(mockHook2),
            address(mockVault1),
            "Test Hook 2",
            "https://hook2.metadata.uri"
        );

        address[] memory hookList = registry.getHookList();
        assertEq(hookList.length, 2);
        assertEq(hookList[0], address(mockHook1));
        assertEq(hookList[1], address(mockHook2));
    }

    // ============ getHooksByVault Tests ============

    function test_GetHooksByVault_EmptyForNewVault() public {
        vm.prank(user1);
        registry.registerVault{value: VAULT_FEE}(
            address(mockVault1),
            "Test Vault",
            "https://vault.metadata.uri"
        );

        address[] memory vaultHooks = registry.getHooksByVault(address(mockVault1));
        assertEq(vaultHooks.length, 0);
    }

    function test_GetHooksByVault_MultipleHooks() public {
        vm.prank(user1);
        registry.registerVault{value: VAULT_FEE}(
            address(mockVault1),
            "Test Vault",
            "https://vault.metadata.uri"
        );

        vm.prank(user2);
        registry.registerHook{value: HOOK_FEE}(
            address(mockHook1),
            address(mockVault1),
            "Test Hook 1",
            "https://hook1.metadata.uri"
        );

        registry.registerHook{value: HOOK_FEE}(
            address(mockHook2),
            address(mockVault1),
            "Test Hook 2",
            "https://hook2.metadata.uri"
        );

        address[] memory vaultHooks = registry.getHooksByVault(address(mockVault1));
        assertEq(vaultHooks.length, 2);
        assertEq(vaultHooks[0], address(mockHook1));
        assertEq(vaultHooks[1], address(mockHook2));
    }

    function test_GetHooksByVault_RevertsOnUnregisteredVault() public {
        vm.expectRevert("Vault not registered");
        registry.getHooksByVault(address(mockVault1));
    }

    // ============ isVaultRegistered Tests ============

    function test_IsVaultRegistered_FalseForUnregistered() public view {
        assertFalse(registry.isVaultRegistered(address(mockVault1)));
    }

    function test_IsVaultRegistered_TrueAfterRegistration() public {
        vm.prank(user1);
        registry.registerVault{value: VAULT_FEE}(
            address(mockVault1),
            "Test Vault",
            "https://metadata.uri"
        );

        assertTrue(registry.isVaultRegistered(address(mockVault1)));
    }

    function test_IsVaultRegistered_FalseAfterDeactivation() public {
        vm.prank(user1);
        registry.registerVault{value: VAULT_FEE}(
            address(mockVault1),
            "Test Vault",
            "https://metadata.uri"
        );

        registry.deactivateVault(address(mockVault1));

        assertFalse(registry.isVaultRegistered(address(mockVault1)));
    }

    // ============ isHookRegistered Tests ============

    function test_IsHookRegistered_FalseForUnregistered() public view {
        assertFalse(registry.isHookRegistered(address(mockHook1)));
    }

    function test_IsHookRegistered_TrueAfterRegistration() public {
        vm.prank(user1);
        registry.registerVault{value: VAULT_FEE}(
            address(mockVault1),
            "Test Vault",
            "https://vault.metadata.uri"
        );

        vm.prank(user2);
        registry.registerHook{value: HOOK_FEE}(
            address(mockHook1),
            address(mockVault1),
            "Test Hook",
            "https://hook.metadata.uri"
        );

        assertTrue(registry.isHookRegistered(address(mockHook1)));
    }

    function test_IsHookRegistered_FalseAfterDeactivation() public {
        vm.prank(user1);
        registry.registerVault{value: VAULT_FEE}(
            address(mockVault1),
            "Test Vault",
            "https://vault.metadata.uri"
        );

        vm.prank(user2);
        registry.registerHook{value: HOOK_FEE}(
            address(mockHook1),
            address(mockVault1),
            "Test Hook",
            "https://hook.metadata.uri"
        );

        registry.deactivateHook(address(mockHook1));

        assertFalse(registry.isHookRegistered(address(mockHook1)));
    }

    // ============ incrementVaultInstanceCount Tests ============

    function test_IncrementVaultInstanceCount_Success() public {
        vm.prank(user1);
        registry.registerVault{value: VAULT_FEE}(
            address(mockVault1),
            "Test Vault",
            "https://metadata.uri"
        );

        registry.incrementVaultInstanceCount(address(mockVault1));

        VaultRegistry.VaultInfo memory info = registry.getVaultInfo(address(mockVault1));
        assertEq(info.instanceCount, 1);
    }

    function test_IncrementVaultInstanceCount_MultipleIncrements() public {
        vm.prank(user1);
        registry.registerVault{value: VAULT_FEE}(
            address(mockVault1),
            "Test Vault",
            "https://metadata.uri"
        );

        registry.incrementVaultInstanceCount(address(mockVault1));
        registry.incrementVaultInstanceCount(address(mockVault1));
        registry.incrementVaultInstanceCount(address(mockVault1));

        VaultRegistry.VaultInfo memory info = registry.getVaultInfo(address(mockVault1));
        assertEq(info.instanceCount, 3);
    }

    function test_IncrementVaultInstanceCount_RevertsOnUnregistered() public {
        vm.expectRevert("Vault not registered");
        registry.incrementVaultInstanceCount(address(mockVault1));
    }

    // ============ incrementHookInstanceCount Tests ============

    function test_IncrementHookInstanceCount_Success() public {
        vm.prank(user1);
        registry.registerVault{value: VAULT_FEE}(
            address(mockVault1),
            "Test Vault",
            "https://vault.metadata.uri"
        );

        vm.prank(user2);
        registry.registerHook{value: HOOK_FEE}(
            address(mockHook1),
            address(mockVault1),
            "Test Hook",
            "https://hook.metadata.uri"
        );

        registry.incrementHookInstanceCount(address(mockHook1));

        VaultRegistry.HookInfo memory info = registry.getHookInfo(address(mockHook1));
        assertEq(info.instanceCount, 1);
    }

    function test_IncrementHookInstanceCount_MultipleIncrements() public {
        vm.prank(user1);
        registry.registerVault{value: VAULT_FEE}(
            address(mockVault1),
            "Test Vault",
            "https://vault.metadata.uri"
        );

        vm.prank(user2);
        registry.registerHook{value: HOOK_FEE}(
            address(mockHook1),
            address(mockVault1),
            "Test Hook",
            "https://hook.metadata.uri"
        );

        registry.incrementHookInstanceCount(address(mockHook1));
        registry.incrementHookInstanceCount(address(mockHook1));

        VaultRegistry.HookInfo memory info = registry.getHookInfo(address(mockHook1));
        assertEq(info.instanceCount, 2);
    }

    function test_IncrementHookInstanceCount_RevertsOnUnregistered() public {
        vm.expectRevert("Hook not registered");
        registry.incrementHookInstanceCount(address(mockHook1));
    }

    // ============ setVaultRegistrationFee Tests ============

    function test_SetVaultRegistrationFee_Success() public {
        uint256 newFee = 0.1 ether;

        vm.expectEmit(false, false, false, true);
        emit VaultFeeUpdated(newFee);

        registry.setVaultRegistrationFee(newFee);

        assertEq(registry.vaultRegistrationFee(), newFee);
    }

    function test_SetVaultRegistrationFee_RevertsOnNonOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        registry.setVaultRegistrationFee(0.1 ether);
    }

    function test_SetVaultRegistrationFee_RevertsOnZeroFee() public {
        vm.expectRevert("Fee must be positive");
        registry.setVaultRegistrationFee(0);
    }

    // ============ setHookRegistrationFee Tests ============

    function test_SetHookRegistrationFee_Success() public {
        uint256 newFee = 0.05 ether;

        vm.expectEmit(false, false, false, true);
        emit HookFeeUpdated(newFee);

        registry.setHookRegistrationFee(newFee);

        assertEq(registry.hookRegistrationFee(), newFee);
    }

    function test_SetHookRegistrationFee_RevertsOnNonOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        registry.setHookRegistrationFee(0.05 ether);
    }

    function test_SetHookRegistrationFee_RevertsOnZeroFee() public {
        vm.expectRevert("Fee must be positive");
        registry.setHookRegistrationFee(0);
    }

    // ============ setAnalyticsModule Tests ============

    function test_SetAnalyticsModule_Success() public {
        vm.expectEmit(true, false, false, false);
        emit AnalyticsModuleSet(address(mockAnalytics));

        registry.setAnalyticsModule(address(mockAnalytics));

        assertEq(registry.analyticsModule(), address(mockAnalytics));
    }

    function test_SetAnalyticsModule_CanSetToZero() public {
        registry.setAnalyticsModule(address(mockAnalytics));

        vm.expectEmit(true, false, false, false);
        emit AnalyticsModuleSet(address(0));

        registry.setAnalyticsModule(address(0));

        assertEq(registry.analyticsModule(), address(0));
    }

    function test_SetAnalyticsModule_RevertsOnNonOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        registry.setAnalyticsModule(address(mockAnalytics));
    }

    function test_SetAnalyticsModule_RevertsOnNonContract() public {
        address notContract = makeAddr("notContract");

        vm.expectRevert("Invalid module");
        registry.setAnalyticsModule(notContract);
    }

    // ============ getVaultCount Tests ============

    function test_GetVaultCount_ZeroInitially() public view {
        assertEq(registry.getVaultCount(), 0);
    }

    function test_GetVaultCount_IncrementsWithRegistration() public {
        vm.prank(user1);
        registry.registerVault{value: VAULT_FEE}(
            address(mockVault1),
            "Test Vault 1",
            "https://metadata1.uri"
        );

        assertEq(registry.getVaultCount(), 1);

        vm.prank(user2);
        registry.registerVault{value: VAULT_FEE}(
            address(mockVault2),
            "Test Vault 2",
            "https://metadata2.uri"
        );

        assertEq(registry.getVaultCount(), 2);
    }

    // ============ getHookCount Tests ============

    function test_GetHookCount_ZeroInitially() public view {
        assertEq(registry.getHookCount(), 0);
    }

    function test_GetHookCount_IncrementsWithRegistration() public {
        vm.prank(user1);
        registry.registerVault{value: VAULT_FEE}(
            address(mockVault1),
            "Test Vault",
            "https://vault.metadata.uri"
        );

        vm.prank(user2);
        registry.registerHook{value: HOOK_FEE}(
            address(mockHook1),
            address(mockVault1),
            "Test Hook 1",
            "https://hook1.metadata.uri"
        );

        assertEq(registry.getHookCount(), 1);

        registry.registerHook{value: HOOK_FEE}(
            address(mockHook2),
            address(mockVault1),
            "Test Hook 2",
            "https://hook2.metadata.uri"
        );

        assertEq(registry.getHookCount(), 2);
    }
}

// ============ Mock Contracts ============

/**
 * @notice Mock vault contract for testing
 */
contract MockVault {
    string public name = "Mock Vault";
}

/**
 * @notice Mock hook contract for testing
 */
contract MockHook {
    string public name = "Mock Hook";
}

/**
 * @notice Mock analytics contract for testing
 */
contract MockAnalytics {
    string public name = "Mock Analytics";
}
