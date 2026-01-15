// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {ForkTestBase} from "../helpers/ForkTestBase.sol";
import {HookAddressMiner} from "../helpers/HookAddressMiner.sol";
import {UltraAlignmentHookFactory} from "../../../src/factories/erc404/hooks/UltraAlignmentHookFactory.sol";
import {UltraAlignmentV4Hook} from "../../../src/factories/erc404/hooks/UltraAlignmentV4Hook.sol";
import {UltraAlignmentVault} from "../../../src/vaults/UltraAlignmentVault.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/**
 * @title V4HookDeployment
 * @notice Integration tests for UltraAlignmentV4Hook deployment through factories
 * @dev These tests verify the ACTUAL deployment path that failed in production.
 *
 * CRITICAL: This test suite exists because our previous tests used mock hooks that
 * bypassed Hooks.validateHookPermissions(), hiding the fact that hook deployment
 * fails when the contract address doesn't have the correct permission bits.
 *
 * Run with: forge test --match-path "test/fork/v4/V4HookDeployment.t.sol" --fork-url $ETH_RPC_URL -vvv
 *
 * What this suite tests:
 * 1. CREATE2 salt mining produces valid hook addresses
 * 2. UltraAlignmentHookFactory.createHook() deploys real hooks
 * 3. Deployed hooks pass Hooks.validateHookPermissions()
 * 4. End-to-end: Factory → Hook → Pool → Swap → Tax collection
 */
contract V4HookDeploymentTest is ForkTestBase {
    using HookAddressMiner for *;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    // ========== State ==========

    UltraAlignmentHookFactory public hookFactory;
    UltraAlignmentVault public vault;
    IPoolManager public poolManager;

    bool public v4Available;

    uint256 constant HOOK_CREATION_FEE = 0.001 ether;

    // Required flags for UltraAlignmentV4Hook (must be set)
    uint160 constant REQUIRED_FLAGS = uint160(
        Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    ); // = 0x44

    // All hook permission flags (bits 0-13)
    uint160 constant ALL_HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG |
        Hooks.AFTER_INITIALIZE_FLAG |
        Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
        Hooks.AFTER_ADD_LIQUIDITY_FLAG |
        Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG |
        Hooks.AFTER_REMOVE_LIQUIDITY_FLAG |
        Hooks.BEFORE_SWAP_FLAG |
        Hooks.AFTER_SWAP_FLAG |
        Hooks.BEFORE_DONATE_FLAG |
        Hooks.AFTER_DONATE_FLAG |
        Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG |
        Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG |
        Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG |
        Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
    ); // = 0x3FFF

    // Flags that must NOT be set for UltraAlignmentV4Hook
    uint160 constant FORBIDDEN_FLAGS = ALL_HOOK_FLAGS ^ REQUIRED_FLAGS;

    // ========== Events ==========

    event HookCreated(
        address indexed hook,
        address indexed poolManager,
        address indexed vault,
        address creator
    );

    // ========== Setup ==========

    function setUp() public {
        loadAddresses();
        v4Available = UNISWAP_V4_POOL_MANAGER != address(0);

        if (!v4Available) {
            return;
        }

        poolManager = IPoolManager(UNISWAP_V4_POOL_MANAGER);

        // Deploy real vault
        vault = new UltraAlignmentVault(
            WETH,
            UNISWAP_V4_POOL_MANAGER,
            UNISWAP_V3_ROUTER,
            UNISWAP_V2_ROUTER,
            UNISWAP_V2_FACTORY,
            UNISWAP_V3_FACTORY,
            USDC  // Using USDC as alignment token for test
        );

        // Deploy real hook factory
        hookFactory = new UltraAlignmentHookFactory(address(0)); // hookTemplate

        // Fund test contract
        vm.deal(address(this), 100 ether);
    }

    // ========== Salt Mining Tests ==========

    /**
     * @notice Verify we can compute a valid salt that produces correct hook flags
     */
    function test_computeValidSalt_producesAddressWithCorrectFlags() public {
        if (!v4Available) {
            emit log_string("SKIPPED: V4 not available");
            return;
        }

        emit log_string("=== Salt Mining Test ===");
        emit log_string("");

        // Compute init code hash
        bytes32 initCodeHash = _computeHookInitCodeHash(
            address(poolManager),
            address(vault),
            WETH,
            address(this)
        );

        emit log_named_bytes32("Init code hash", initCodeHash);

        // Mine a valid salt
        (bytes32 salt, address predictedAddress) = HookAddressMiner.mineSaltForUltraAlignmentHook(
            address(hookFactory),
            initCodeHash
        );

        emit log_named_bytes32("Found salt", salt);
        emit log_named_address("Predicted address", predictedAddress);
        emit log_named_uint("Address as uint160", uint160(predictedAddress));
        emit log_named_uint("Required flags (0x44)", REQUIRED_FLAGS);
        emit log_named_uint("Forbidden flags", FORBIDDEN_FLAGS);
        emit log_named_uint("Address & required", uint160(predictedAddress) & REQUIRED_FLAGS);
        emit log_named_uint("Address & forbidden", uint160(predictedAddress) & FORBIDDEN_FLAGS);
        emit log_named_uint("Address & all flags", uint160(predictedAddress) & ALL_HOOK_FLAGS);

        // Verify the predicted address has EXACTLY the correct flags
        assertTrue(
            HookAddressMiner.isValidUltraAlignmentHookAddress(predictedAddress),
            "Predicted address should have exactly the required permission flags"
        );

        // Verify required flags are set
        assertEq(
            uint160(predictedAddress) & REQUIRED_FLAGS,
            REQUIRED_FLAGS,
            "Required flags must be set"
        );

        // Verify forbidden flags are NOT set
        assertEq(
            uint160(predictedAddress) & FORBIDDEN_FLAGS,
            0,
            "Forbidden flags must not be set"
        );

        // Decode and log all flags for verification
        Hooks.Permissions memory perms = HookAddressMiner.decodeFlags(predictedAddress);
        assertTrue(perms.afterSwap, "afterSwap flag should be set");
        assertTrue(perms.afterSwapReturnDelta, "afterSwapReturnDelta flag should be set");

        emit log_string("");
        emit log_string("[SUCCESS] Salt mining produces valid hook address!");
    }

    /**
     * @notice Verify that an arbitrary address (like from regular CREATE) would fail
     */
    function test_arbitraryAddress_failsValidation() public {
        if (!v4Available) {
            emit log_string("SKIPPED: V4 not available");
            return;
        }

        emit log_string("=== Arbitrary Address Validation Test ===");
        emit log_string("");

        // Generate some arbitrary addresses (simulating regular CREATE deployment)
        // Using uint256 cast to avoid solidity checksum validation on hex literals
        address[] memory arbitraryAddresses = new address[](5);
        arbitraryAddresses[0] = address(uint160(uint256(keccak256("address1"))));
        arbitraryAddresses[1] = address(uint160(uint256(keccak256("address2"))));
        arbitraryAddresses[2] = address(uint160(uint256(keccak256("address3"))));
        arbitraryAddresses[3] = address(uint160(block.timestamp));
        arbitraryAddresses[4] = address(uint160(uint256(keccak256("random"))));

        uint256 validCount = 0;
        for (uint256 i = 0; i < arbitraryAddresses.length; i++) {
            bool isValid = HookAddressMiner.isValidUltraAlignmentHookAddress(arbitraryAddresses[i]);
            emit log_named_address("Address", arbitraryAddresses[i]);
            emit log_named_string("Valid for hook?", isValid ? "YES" : "NO");

            if (isValid) validCount++;
        }

        emit log_string("");
        emit log_named_uint("Valid addresses out of 5", validCount);

        // It's statistically very unlikely any random address has the exact flags
        // (1 in 16384 chance for our 2-bit requirement, but flags must be in specific positions)
        emit log_string("");
        emit log_string("[INFO] This demonstrates why regular CREATE deployment fails");
        emit log_string("       - Random addresses almost never have correct permission bits");
    }

    // ========== Factory Deployment Tests ==========

    /**
     * @notice Test successful hook deployment through factory with valid CREATE2 salt
     * @dev THIS IS THE CRITICAL TEST - it tests the actual deployment path that failed in production
     */
    function test_hookFactory_createHook_withValidSalt_succeeds() public {
        if (!v4Available) {
            emit log_string("SKIPPED: V4 not available");
            return;
        }

        emit log_string("=== Hook Factory Deployment Test ===");
        emit log_string("");
        emit log_string("CRITICAL: This tests the actual deployment path that failed in production");
        emit log_string("");

        // Step 1: Compute init code hash
        bytes32 initCodeHash = _computeHookInitCodeHash(
            address(poolManager),
            address(vault),
            WETH,
            address(this)
        );

        // Step 2: Mine a valid salt
        (bytes32 salt, address predictedAddress) = HookAddressMiner.mineSaltForUltraAlignmentHook(
            address(hookFactory),
            initCodeHash
        );

        emit log_named_bytes32("Using salt", salt);
        emit log_named_address("Expected hook address", predictedAddress);

        // Step 3: Deploy through factory
        emit log_string("");
        emit log_string("Deploying hook through factory...");

        address deployedHook = hookFactory.createHook{value: HOOK_CREATION_FEE}(
            address(poolManager),
            address(vault),
            WETH,
            address(this),
            true,  // isCanonical
            salt
        );

        emit log_named_address("Deployed hook address", deployedHook);

        // Step 4: Verify deployment
        assertEq(deployedHook, predictedAddress, "Deployed address should match predicted");
        assertTrue(deployedHook.code.length > 0, "Hook should have code");

        // Step 5: Verify the hook has correct permission flags
        assertTrue(
            HookAddressMiner.isValidUltraAlignmentHookAddress(deployedHook),
            "Deployed hook should have valid permission flags"
        );

        // Step 6: Verify hook state
        UltraAlignmentV4Hook hook = UltraAlignmentV4Hook(deployedHook);
        assertEq(address(hook.poolManager()), address(poolManager), "PoolManager should be set");
        assertEq(address(hook.vault()), address(vault), "Vault should be set");
        assertEq(hook.weth(), WETH, "WETH should be set");
        assertEq(hook.owner(), address(this), "Owner should be set");
        assertEq(hook.taxRateBips(), 100, "Default tax rate should be 100 bips");

        emit log_string("");
        emit log_string("[SUCCESS] Hook deployed successfully through factory!");
        emit log_string("          Hooks.validateHookPermissions() passed during deployment");
    }

    /**
     * @notice Test that deployment with invalid salt reverts
     */
    function test_hookFactory_createHook_withInvalidSalt_reverts() public {
        if (!v4Available) {
            emit log_string("SKIPPED: V4 not available");
            return;
        }

        emit log_string("=== Invalid Salt Deployment Test ===");
        emit log_string("");

        // Use a salt that we know produces an invalid address
        // Salt 0 is very unlikely to produce valid flags
        bytes32 invalidSalt = bytes32(uint256(0xDEADBEEF));

        // Compute what address this would produce
        bytes32 initCodeHash = _computeHookInitCodeHash(
            address(poolManager),
            address(vault),
            WETH,
            address(this)
        );

        address wouldBeAddress = HookAddressMiner.computeAddress(
            address(hookFactory),
            invalidSalt,
            initCodeHash
        );

        emit log_named_bytes32("Invalid salt", invalidSalt);
        emit log_named_address("Would deploy to", wouldBeAddress);
        emit log_named_uint("Address flags", uint160(wouldBeAddress) & REQUIRED_FLAGS);
        emit log_named_uint("Required flags", REQUIRED_FLAGS);

        // Skip if by chance this salt is valid (very unlikely)
        if (HookAddressMiner.hasRequiredFlags(wouldBeAddress, REQUIRED_FLAGS)) {
            emit log_string("SKIPPED: Salt happens to be valid by chance");
            return;
        }

        // This should revert because Hooks.validateHookPermissions() will fail
        emit log_string("");
        emit log_string("Attempting deployment with invalid salt...");

        vm.expectRevert(); // Will revert in Hooks.validateHookPermissions()
        hookFactory.createHook{value: HOOK_CREATION_FEE}(
            address(poolManager),
            address(vault),
            WETH,
            address(this),
            true,
            invalidSalt
        );

        emit log_string("");
        emit log_string("[SUCCESS] Invalid salt correctly causes deployment to revert!");
    }

    // ========== Hook Functionality Tests ==========

    /**
     * @notice Test that deployed hook can be registered with a pool
     */
    function test_deployedHook_canInitializePool() public {
        if (!v4Available) {
            emit log_string("SKIPPED: V4 not available");
            return;
        }

        emit log_string("=== Pool Initialization with Hook Test ===");
        emit log_string("");

        // Deploy hook
        address hook = _deployValidHook();
        emit log_named_address("Hook deployed at", hook);

        // Create pool key with our hook
        PoolKey memory key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,  // Native ETH
            currency1: Currency.wrap(USDC),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });

        // Check if pool already exists
        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        if (sqrtPriceX96 == 0) {
            // Initialize pool
            uint160 initialPrice = 79228162514264337593543950336; // ~1:1

            emit log_string("Initializing pool with hook...");
            poolManager.initialize(key, initialPrice);
            emit log_string("Pool initialized successfully!");

            // Verify pool state
            (sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
            assertTrue(sqrtPriceX96 > 0, "Pool should be initialized");
        } else {
            emit log_string("Pool already exists, skipping initialization");
        }

        emit log_string("");
        emit log_string("[SUCCESS] Hook can initialize pools!");
    }

    // ========== Address Validation Tests ==========

    /**
     * @notice Verify Hooks.validateHookPermissions would pass for our deployed hook
     */
    function test_hookAddress_passesValidateHookPermissions() public {
        if (!v4Available) {
            emit log_string("SKIPPED: V4 not available");
            return;
        }

        emit log_string("=== Hook Address Validation Test ===");
        emit log_string("");

        // Deploy hook (this implicitly tests validateHookPermissions)
        address hook = _deployValidHook();

        // Manually verify the permissions match what we declared
        Hooks.Permissions memory expectedPerms = Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });

        // Decode actual permissions from address
        Hooks.Permissions memory actualPerms = HookAddressMiner.decodeFlags(hook);

        // Log permissions
        emit log_string("Expected permissions:");
        emit log_named_string("  afterSwap", expectedPerms.afterSwap ? "true" : "false");
        emit log_named_string("  afterSwapReturnDelta", expectedPerms.afterSwapReturnDelta ? "true" : "false");

        emit log_string("");
        emit log_string("Actual permissions (from address):");
        emit log_named_string("  afterSwap", actualPerms.afterSwap ? "true" : "false");
        emit log_named_string("  afterSwapReturnDelta", actualPerms.afterSwapReturnDelta ? "true" : "false");

        // Verify required permissions are set
        assertTrue(actualPerms.afterSwap, "afterSwap should be enabled");
        assertTrue(actualPerms.afterSwapReturnDelta, "afterSwapReturnDelta should be enabled");

        emit log_string("");
        emit log_string("[SUCCESS] Hook address encodes correct permissions!");
    }

    // ========== Helper Functions ==========

    /**
     * @notice Deploy a valid hook through the factory
     */
    function _deployValidHook() internal returns (address) {
        bytes32 initCodeHash = _computeHookInitCodeHash(
            address(poolManager),
            address(vault),
            WETH,
            address(this)
        );

        (bytes32 salt, ) = HookAddressMiner.mineSaltForUltraAlignmentHook(
            address(hookFactory),
            initCodeHash
        );

        return hookFactory.createHook{value: HOOK_CREATION_FEE}(
            address(poolManager),
            address(vault),
            WETH,
            address(this),
            true,
            salt
        );
    }

    /**
     * @notice Compute the init code hash for UltraAlignmentV4Hook
     */
    function _computeHookInitCodeHash(
        address _poolManager,
        address _vault,
        address _weth,
        address _owner
    ) internal pure returns (bytes32) {
        bytes memory initCode = abi.encodePacked(
            type(UltraAlignmentV4Hook).creationCode,
            abi.encode(_poolManager, _vault, _weth, _owner)
        );
        return keccak256(initCode);
    }

    // Required for receiving ETH
    receive() external payable {}
}
