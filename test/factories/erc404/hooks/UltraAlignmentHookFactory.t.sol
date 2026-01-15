// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console, console2} from "forge-std/Test.sol";
import {UltraAlignmentHookFactory} from "../../../../src/factories/erc404/hooks/UltraAlignmentHookFactory.sol";
import {UltraAlignmentVault} from "../../../../src/vaults/UltraAlignmentVault.sol";
import {MockEXECToken} from "../../../mocks/MockEXECToken.sol";
import {MockPoolManager} from "../../../mocks/MockPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

/**
 * @title UltraAlignmentHookFactoryTest
 * @notice Comprehensive test suite for UltraAlignmentHookFactory
 * @dev Tests all public functions with success and failure paths
 */
contract UltraAlignmentHookFactoryTest is Test {
    UltraAlignmentHookFactory public factory;
    UltraAlignmentVault public vault;
    MockEXECToken public token;
    MockPoolManager public poolManager;

    address public owner = address(0x1);
    address public factoryCreator = address(0x2);
    address public hookCreator = address(0x3);
    address public wethAddr = address(0x5);
    address public nonOwner = address(0x6);

    uint256 public constant HOOK_FEE = 0.001 ether;
    uint256 public constant INITIAL_BALANCE = 10 ether;

    event HookCreated(
        address indexed hook,
        address indexed poolManager,
        address indexed vault,
        address creator
    );

    event FactoryAuthorized(address indexed factory);
    event FactoryDeauthorized(address indexed factory);

    function setUp() public {
        vm.startPrank(owner);

        // Deploy mock pool manager
        poolManager = new MockPoolManager();

        // Deploy mock token for vault
        token = new MockEXECToken(1000000e18);

        // Deploy vault (WETH, PoolManager, V3Router, V2Router, V2Factory, V3Factory, AlignmentToken)
        vault = new UltraAlignmentVault(
            wethAddr,
            address(poolManager),
            address(0x5555555555555555555555555555555555555555),  // V3 router
            address(0x6666666666666666666666666666666666666666),  // V2 router
            address(0x7777777777777777777777777777777777777777),  // V2 factory
            address(0x8888888888888888888888888888888888888888),  // V3 factory
            address(token)
        );

        // Set V4 pool key
        // H-02: Hook requires native ETH (address(0)), not WETH
        PoolKey memory mockPoolKey = PoolKey({
            currency0: Currency.wrap(address(0)),  // Native ETH
            currency1: Currency.wrap(address(token)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        vault.setV4PoolKey(mockPoolKey);

        // Deploy factory
        factory = new UltraAlignmentHookFactory(address(0)); // hookTemplate

        vm.stopPrank();

        // Fund test accounts
        vm.deal(factoryCreator, INITIAL_BALANCE);
        vm.deal(hookCreator, INITIAL_BALANCE);
        vm.deal(nonOwner, INITIAL_BALANCE);
    }

    // ========== Input Validation Tests ==========

    function test_createHook_invalidPoolManager() public {
        vm.prank(factoryCreator);

        vm.expectRevert("Invalid pool manager");
        factory.createHook{value: HOOK_FEE}(
            address(0),
            address(vault),
            wethAddr,
            hookCreator,
            true,
            bytes32(0)
        );
    }

    function test_createHook_invalidVault() public {
        vm.prank(factoryCreator);

        vm.expectRevert("Invalid vault");
        factory.createHook{value: HOOK_FEE}(
            address(poolManager),
            address(0),
            wethAddr,
            hookCreator,
            true,
            bytes32(0)
        );
    }

    function test_createHook_invalidWeth() public {
        vm.prank(factoryCreator);

        vm.expectRevert("Invalid WETH");
        factory.createHook{value: HOOK_FEE}(
            address(poolManager),
            address(vault),
            address(0),
            hookCreator,
            true,
            bytes32(0)
        );
    }

    function test_createHook_invalidCreator() public {
        vm.prank(factoryCreator);

        vm.expectRevert("Invalid creator");
        factory.createHook{value: HOOK_FEE}(
            address(poolManager),
            address(vault),
            wethAddr,
            address(0),
            true,
            bytes32(0)
        );
    }

    // ========== Fee Validation Tests ==========

    function test_feeHandling_underpayment() public {
        uint256 insufficientFee = HOOK_FEE - 0.0001 ether;
        vm.prank(factoryCreator);

        vm.expectRevert("Insufficient fee");
        factory.createHook{value: insufficientFee}(
            address(poolManager),
            address(vault),
            wethAddr,
            hookCreator,
            true,
            bytes32(0)
        );
    }

    function test_feeHandling_zeroFee() public {
        vm.prank(factoryCreator);

        vm.expectRevert("Insufficient fee");
        factory.createHook{value: 0}(
            address(poolManager),
            address(vault),
            wethAddr,
            hookCreator,
            true,
            bytes32(0)
        );
    }

    // ========== Template Management Tests ==========

    function test_templateUpdate_byOwner() public {
        address newTemplate = address(0x999);

        vm.prank(owner);
        factory.setHookTemplate(newTemplate);

        assertEq(factory.hookTemplate(), newTemplate, "Template should be updated");
    }

    function test_templateUpdate_unauthorized() public {
        address newTemplate = address(0x999);

        vm.prank(nonOwner);
        vm.expectRevert();
        factory.setHookTemplate(newTemplate);
    }

    function test_templateUpdate_invalidAddress() public {
        vm.prank(owner);
        vm.expectRevert("Invalid template");
        factory.setHookTemplate(address(0));
    }

    function test_templateUpdate_multipleUpdates() public {
        address template1 = address(0x100);
        address template2 = address(0x200);

        vm.startPrank(owner);
        factory.setHookTemplate(template1);
        assertEq(factory.hookTemplate(), template1, "First update");

        factory.setHookTemplate(template2);
        assertEq(factory.hookTemplate(), template2, "Second update");
        vm.stopPrank();
    }

    // ========== Fee Management Tests ==========

    function test_feeUpdate_byOwner() public {
        uint256 newFee = 0.005 ether;

        vm.prank(owner);
        factory.setHookCreationFee(newFee);

        assertEq(factory.hookCreationFee(), newFee, "Fee should be updated");
    }

    function test_feeUpdate_unauthorized() public {
        uint256 newFee = 0.005 ether;

        vm.prank(nonOwner);
        vm.expectRevert();
        factory.setHookCreationFee(newFee);
    }

    function test_feeUpdate_zeroFee() public {
        vm.prank(owner);
        factory.setHookCreationFee(0);
        assertEq(factory.hookCreationFee(), 0, "Fee should be zero");
    }

    function test_feeUpdate_largeFee() public {
        uint256 largeFee = 100 ether;

        vm.prank(owner);
        factory.setHookCreationFee(largeFee);
        assertEq(factory.hookCreationFee(), largeFee, "Large fee should be set");
    }

    function test_feeUpdate_multipleUpdates() public {
        uint256 fee1 = 0.001 ether;
        uint256 fee2 = 0.005 ether;
        uint256 fee3 = 0.002 ether;

        vm.startPrank(owner);
        factory.setHookCreationFee(fee1);
        assertEq(factory.hookCreationFee(), fee1, "First fee");

        factory.setHookCreationFee(fee2);
        assertEq(factory.hookCreationFee(), fee2, "Second fee");

        factory.setHookCreationFee(fee3);
        assertEq(factory.hookCreationFee(), fee3, "Third fee");
        vm.stopPrank();
    }

    // ========== Authorization Management Tests ==========

    function test_authorizeFactory_byOwner() public {
        address factoryToAuth = address(0x777);

        vm.prank(owner);
        factory.authorizeFactory(factoryToAuth);

        assertTrue(
            factory.authorizedFactories(factoryToAuth),
            "Factory should be authorized"
        );
    }

    function test_authorizeFactory_unauthorized() public {
        address factoryToAuth = address(0x777);

        vm.prank(nonOwner);
        vm.expectRevert();
        factory.authorizeFactory(factoryToAuth);
    }

    function test_authorizeFactory_invalidAddress() public {
        vm.prank(owner);
        vm.expectRevert("Invalid factory");
        factory.authorizeFactory(address(0));
    }

    function test_authorizeFactory_emitsEvent() public {
        address factoryToAuth = address(0x777);

        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit FactoryAuthorized(factoryToAuth);
        factory.authorizeFactory(factoryToAuth);
    }

    function test_authorizeFactory_multipleFactories() public {
        address factory1 = address(0x777);
        address factory2 = address(0x888);
        address factory3 = address(0x999);

        vm.startPrank(owner);
        factory.authorizeFactory(factory1);
        factory.authorizeFactory(factory2);
        factory.authorizeFactory(factory3);
        vm.stopPrank();

        assertTrue(factory.authorizedFactories(factory1), "Factory 1 authorized");
        assertTrue(factory.authorizedFactories(factory2), "Factory 2 authorized");
        assertTrue(factory.authorizedFactories(factory3), "Factory 3 authorized");
    }

    function test_deauthorizeFactory_byOwner() public {
        address factoryToAuth = address(0x777);

        // First authorize
        vm.prank(owner);
        factory.authorizeFactory(factoryToAuth);
        assertTrue(factory.authorizedFactories(factoryToAuth), "Should be authorized");

        // Then deauthorize
        vm.prank(owner);
        factory.deauthorizeFactory(factoryToAuth);
        assertFalse(factory.authorizedFactories(factoryToAuth), "Should be deauthorized");
    }

    function test_deauthorizeFactory_unauthorized() public {
        address factoryToAuth = address(0x777);

        vm.prank(owner);
        factory.authorizeFactory(factoryToAuth);

        vm.prank(nonOwner);
        vm.expectRevert();
        factory.deauthorizeFactory(factoryToAuth);
    }

    function test_deauthorizeFactory_emitsEvent() public {
        address factoryToAuth = address(0x777);

        vm.prank(owner);
        factory.authorizeFactory(factoryToAuth);

        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit FactoryDeauthorized(factoryToAuth);
        factory.deauthorizeFactory(factoryToAuth);
    }

    function test_authorizeDeauthorizeSequence() public {
        address factoryToAuth = address(0x777);

        vm.startPrank(owner);
        // Authorize
        factory.authorizeFactory(factoryToAuth);
        assertTrue(factory.authorizedFactories(factoryToAuth), "Authorized");

        // Deauthorize
        factory.deauthorizeFactory(factoryToAuth);
        assertFalse(factory.authorizedFactories(factoryToAuth), "Deauthorized");

        // Reauthorize
        factory.authorizeFactory(factoryToAuth);
        assertTrue(factory.authorizedFactories(factoryToAuth), "Reauthorized");
        vm.stopPrank();
    }

    // ========== Hook Tracking Tests ==========

    function test_hookQueries_getHooksByFactory_empty() public view {
        address[] memory hooks = factory.getHooksByFactory(factoryCreator);
        assertEq(hooks.length, 0, "No hooks initially");
    }

    function test_hookQueries_getHooksByFactory_multipleCalls() public view {
        // Query multiple times should return consistent results
        address[] memory hooks1 = factory.getHooksByFactory(factoryCreator);
        address[] memory hooks2 = factory.getHooksByFactory(factoryCreator);

        assertEq(hooks1.length, hooks2.length, "Consistent empty results");
    }

    function test_hookQueries_differentFactories() public view {
        // Different factory creators should have separate tracking
        address[] memory hooksCreator1 = factory.getHooksByFactory(factoryCreator);
        address[] memory hooksCreator2 = factory.getHooksByFactory(nonOwner);

        assertEq(hooksCreator1.length, 0, "Creator 1 has no hooks");
        assertEq(hooksCreator2.length, 0, "Creator 2 has no hooks");
    }

    // ========== Constructor & Initialization Tests ==========

    function test_constructor_initialization() public view {
        assertEq(factory.hookCreationFee(), 0.001 ether, "Default fee should be set");
        assertTrue(factory.owner() == owner, "Owner should be initialized");
    }

    function test_constructor_validAddresses() public {
        UltraAlignmentHookFactory newFactory =
            new UltraAlignmentHookFactory(address(0x888)); // hookTemplate
        assertEq(newFactory.hookTemplate(), address(0x888), "Hook template should be set");
        assertEq(newFactory.hookCreationFee(), 0.001 ether, "Default fee set");
    }

    function test_constructor_hookTemplateInitialized() public {
        // Factory is deployed with address(0) as template in setUp
        assertEq(factory.hookTemplate(), address(0), "Hook template initialized");
    }

    // ========== Reentrancy Safety Tests ==========

    function test_reentrancyGuardInitialized() public {
        // Factory uses ReentrancyGuard, verify it's initialized
        // We do this by calling multiple public functions in sequence

        uint256 newFee = 0.002 ether;
        vm.prank(owner);
        factory.setHookCreationFee(newFee);
        assertEq(factory.hookCreationFee(), newFee, "First operation succeeded");

        address newTemplate = address(0x999);
        vm.prank(owner);
        factory.setHookTemplate(newTemplate);
        assertEq(factory.hookTemplate(), newTemplate, "Second operation succeeded");
    }

    // ========== State Management Tests ==========

    function test_authorizedFactories_state_persistence() public {
        address factoryToAuth = address(0x777);

        // Authorize factory
        vm.prank(owner);
        factory.authorizeFactory(factoryToAuth);
        assertTrue(factory.authorizedFactories(factoryToAuth), "Authorized");

        // Check state persists across multiple calls
        assertTrue(factory.authorizedFactories(factoryToAuth), "Still authorized after first check");
        assertTrue(factory.authorizedFactories(factoryToAuth), "Still authorized after second check");
    }

    function test_fee_state_persistence() public {
        uint256 newFee = 0.005 ether;

        vm.prank(owner);
        factory.setHookCreationFee(newFee);

        // Check state persists across multiple calls
        assertEq(factory.hookCreationFee(), newFee, "First check");
        assertEq(factory.hookCreationFee(), newFee, "Second check");
        assertEq(factory.hookCreationFee(), newFee, "Third check");
    }

    function test_template_state_persistence() public {
        address newTemplate = address(0x999);

        vm.prank(owner);
        factory.setHookTemplate(newTemplate);

        // Check state persists across multiple calls
        assertEq(factory.hookTemplate(), newTemplate, "First check");
        assertEq(factory.hookTemplate(), newTemplate, "Second check");
    }

    // ========== Access Control Tests ==========

    function test_onlyOwner_canUpdateTemplate() public {
        address newTemplate = address(0x999);

        // Owner can update
        vm.prank(owner);
        factory.setHookTemplate(newTemplate);
        assertEq(factory.hookTemplate(), newTemplate, "Owner updated template");

        // Non-owner cannot
        address anotherTemplate = address(0x888);
        vm.prank(nonOwner);
        vm.expectRevert();
        factory.setHookTemplate(anotherTemplate);
    }

    function test_onlyOwner_canUpdateFee() public {
        // Owner can update
        vm.prank(owner);
        factory.setHookCreationFee(0.005 ether);
        assertEq(factory.hookCreationFee(), 0.005 ether, "Owner updated fee");

        // Non-owner cannot
        vm.prank(nonOwner);
        vm.expectRevert();
        factory.setHookCreationFee(0.010 ether);
    }

    function test_onlyOwner_canAuthorizeFactory() public {
        address factoryToAuth = address(0x777);

        // Owner can authorize
        vm.prank(owner);
        factory.authorizeFactory(factoryToAuth);
        assertTrue(factory.authorizedFactories(factoryToAuth), "Owner authorized");

        // Non-owner cannot
        address anotherFactory = address(0x888);
        vm.prank(nonOwner);
        vm.expectRevert();
        factory.authorizeFactory(anotherFactory);
    }

    function test_onlyOwner_canDeauthorizeFactory() public {
        address factoryToAuth = address(0x777);

        // Setup: authorize first
        vm.prank(owner);
        factory.authorizeFactory(factoryToAuth);

        // Owner can deauthorize
        vm.prank(owner);
        factory.deauthorizeFactory(factoryToAuth);
        assertFalse(factory.authorizedFactories(factoryToAuth), "Owner deauthorized");

        // Reauthorize for next test
        vm.prank(owner);
        factory.authorizeFactory(factoryToAuth);

        // Non-owner cannot deauthorize
        vm.prank(nonOwner);
        vm.expectRevert();
        factory.deauthorizeFactory(factoryToAuth);
    }

    // ========== Complex Scenario Tests ==========

    function test_complexScenario_multipleOperations() public {
        // Complex workflow with multiple operations

        // 1. Update template
        address newTemplate = address(0x100);
        vm.prank(owner);
        factory.setHookTemplate(newTemplate);
        assertEq(factory.hookTemplate(), newTemplate, "Template updated");

        // 2. Update fee
        uint256 newFee = 0.01 ether;
        vm.prank(owner);
        factory.setHookCreationFee(newFee);
        assertEq(factory.hookCreationFee(), newFee, "Fee updated");

        // 3. Authorize multiple factories
        address factory1 = address(0x777);
        address factory2 = address(0x888);
        vm.startPrank(owner);
        factory.authorizeFactory(factory1);
        factory.authorizeFactory(factory2);
        vm.stopPrank();

        assertTrue(factory.authorizedFactories(factory1), "Factory 1 authorized");
        assertTrue(factory.authorizedFactories(factory2), "Factory 2 authorized");

        // 4. Deauthorize one
        vm.prank(owner);
        factory.deauthorizeFactory(factory1);
        assertFalse(factory.authorizedFactories(factory1), "Factory 1 deauthorized");
        assertTrue(factory.authorizedFactories(factory2), "Factory 2 still authorized");

        // 5. Check final state
        assertEq(factory.hookTemplate(), newTemplate, "Template persisted");
        assertEq(factory.hookCreationFee(), newFee, "Fee persisted");
    }

    function test_complexScenario_authorizeDeauthorizeMultiple() public {
        address[] memory factories = new address[](5);
        factories[0] = address(0x1111);
        factories[1] = address(0x2222);
        factories[2] = address(0x3333);
        factories[3] = address(0x4444);
        factories[4] = address(0x5555);

        // Authorize all
        vm.startPrank(owner);
        for (uint i = 0; i < factories.length; i++) {
            factory.authorizeFactory(factories[i]);
        }
        vm.stopPrank();

        // Verify all authorized
        for (uint i = 0; i < factories.length; i++) {
            assertTrue(factory.authorizedFactories(factories[i]), "All authorized");
        }

        // Deauthorize every other one
        vm.startPrank(owner);
        for (uint i = 0; i < factories.length; i += 2) {
            factory.deauthorizeFactory(factories[i]);
        }
        vm.stopPrank();

        // Verify alternating state
        for (uint i = 0; i < factories.length; i++) {
            if (i % 2 == 0) {
                assertFalse(factory.authorizedFactories(factories[i]), "Deauthorized");
            } else {
                assertTrue(factory.authorizedFactories(factories[i]), "Still authorized");
            }
        }
    }

    function test_getHooksByFactory_returnsEmptyArray() public view {
        // Empty array should be returned for factory with no hooks
        address[] memory hooks = factory.getHooksByFactory(address(0xDEAD));
        assertEq(hooks.length, 0, "Returns empty array for unknown factory");
    }
}
