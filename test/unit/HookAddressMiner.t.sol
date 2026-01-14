// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {HookAddressMiner} from "../fork/helpers/HookAddressMiner.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

/**
 * @title HookAddressMinerTest
 * @notice Unit tests for the HookAddressMiner library
 * @dev These tests verify salt mining logic WITHOUT requiring a fork
 */
contract HookAddressMinerTest is Test {
    // Mock deployer address (factory)
    address constant MOCK_DEPLOYER = address(0x1234567890123456789012345678901234567890);

    // Mock init code hash (doesn't matter for logic testing)
    bytes32 constant MOCK_INIT_CODE_HASH = keccak256("mock init code");

    // Required flags for UltraAlignmentV4Hook
    uint160 constant REQUIRED_FLAGS = uint160(
        Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    ); // = 0x44

    // All hook flags
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

    uint160 constant FORBIDDEN_FLAGS = ALL_HOOK_FLAGS ^ REQUIRED_FLAGS; // = 0x3FBB

    // ========== Flag Constant Tests ==========

    function test_flagConstants_areCorrect() public pure {
        // Verify our understanding of the flag values
        assertEq(uint160(Hooks.AFTER_SWAP_FLAG), 1 << 6, "AFTER_SWAP_FLAG should be 1<<6");
        assertEq(uint160(Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG), 1 << 2, "AFTER_SWAP_RETURNS_DELTA_FLAG should be 1<<2");

        // Combined required flags
        assertEq(REQUIRED_FLAGS, 0x44, "Required flags should be 0x44");

        // All flags should cover bits 0-13
        assertEq(ALL_HOOK_FLAGS, 0x3FFF, "All flags should be 0x3FFF");

        // Forbidden flags
        assertEq(FORBIDDEN_FLAGS, 0x3FBB, "Forbidden flags should be 0x3FBB");
    }

    // ========== Address Validation Tests ==========

    function test_hasExactFlags_validAddress() public pure {
        // An address ending in 0x44 has exactly the right flags
        address validAddr = address(uint160(0x1234567890123456789012345678901234560044));

        assertTrue(
            HookAddressMiner.hasExactFlags(validAddr, REQUIRED_FLAGS, FORBIDDEN_FLAGS),
            "Address ending in 0x44 should be valid"
        );
    }

    function test_hasExactFlags_invalidAddress_extraFlags() public pure {
        // An address ending in 0xDEce has extra flags set
        // Using keccak to generate a deterministic address to avoid checksum issues
        address invalidAddr = address(uint160(uint256(keccak256("extraflags")) | 0xDEce));

        assertFalse(
            HookAddressMiner.hasExactFlags(invalidAddr, REQUIRED_FLAGS, FORBIDDEN_FLAGS),
            "Address with extra flags should be invalid"
        );
    }

    function test_hasExactFlags_invalidAddress_missingFlags() public pure {
        // An address ending in 0x04 only has afterSwapReturnDelta, missing afterSwap
        address invalidAddr = address(uint160(0x1234567890123456789012345678901234560004));

        assertFalse(
            HookAddressMiner.hasExactFlags(invalidAddr, REQUIRED_FLAGS, FORBIDDEN_FLAGS),
            "Address missing required flags should be invalid"
        );
    }

    function test_hasExactFlags_invalidAddress_noFlags() public pure {
        // An address ending in 0x00 has no flags
        address invalidAddr = address(uint160(0x1234567890123456789012345678901234560000));

        assertFalse(
            HookAddressMiner.hasExactFlags(invalidAddr, REQUIRED_FLAGS, FORBIDDEN_FLAGS),
            "Address with no flags should be invalid"
        );
    }

    function test_isValidUltraAlignmentHookAddress_valid() public pure {
        // Test addresses that end in exactly 0x44 (bits 0-13 = 0x0044)
        // Generate addresses with various upper bits but last 14 bits exactly 0x44
        address[] memory validAddrs = new address[](3);

        // Clear last 14 bits and set to exactly 0x44
        validAddrs[0] = address(uint160(0x44)); // Simple case
        validAddrs[1] = address(uint160((uint256(keccak256("test1")) & ~uint256(ALL_HOOK_FLAGS)) | REQUIRED_FLAGS));
        validAddrs[2] = address(uint160((uint256(keccak256("test2")) & ~uint256(ALL_HOOK_FLAGS)) | REQUIRED_FLAGS));

        for (uint i = 0; i < validAddrs.length; i++) {
            assertTrue(
                HookAddressMiner.isValidUltraAlignmentHookAddress(validAddrs[i]),
                "Should be valid"
            );
        }
    }

    function test_isValidUltraAlignmentHookAddress_invalid() public pure {
        // Test various invalid addresses
        address[] memory invalidAddrs = new address[](5);
        invalidAddrs[0] = address(uint160(0x0000)); // No flags
        invalidAddrs[1] = address(uint160(0x0040)); // Only afterSwap (missing afterSwapReturnDelta)
        invalidAddrs[2] = address(uint160(0x0004)); // Only afterSwapReturnDelta (missing afterSwap)
        invalidAddrs[3] = address(uint160(0x00C4)); // Extra beforeSwap flag (0x80) + required flags
        invalidAddrs[4] = address(uint160(0x3FFF)); // All flags set

        for (uint i = 0; i < invalidAddrs.length; i++) {
            assertFalse(
                HookAddressMiner.isValidUltraAlignmentHookAddress(invalidAddrs[i]),
                "Should be invalid"
            );
        }
    }

    // ========== CREATE2 Address Computation Tests ==========

    function test_computeAddress_deterministic() public pure {
        bytes32 salt1 = bytes32(uint256(1));
        bytes32 salt2 = bytes32(uint256(2));

        address addr1a = HookAddressMiner.computeAddress(MOCK_DEPLOYER, salt1, MOCK_INIT_CODE_HASH);
        address addr1b = HookAddressMiner.computeAddress(MOCK_DEPLOYER, salt1, MOCK_INIT_CODE_HASH);
        address addr2 = HookAddressMiner.computeAddress(MOCK_DEPLOYER, salt2, MOCK_INIT_CODE_HASH);

        // Same inputs should produce same output
        assertEq(addr1a, addr1b, "Same inputs should produce same address");

        // Different salt should produce different address
        assertTrue(addr1a != addr2, "Different salts should produce different addresses");
    }

    function test_computeAddress_matchesCREATE2Formula() public pure {
        address deployer = address(0xBEEF);
        bytes32 salt = bytes32(uint256(42));
        bytes32 initCodeHash = keccak256("test");

        // Manual CREATE2 computation
        address expected = address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),
            deployer,
            salt,
            initCodeHash
        )))));

        address actual = HookAddressMiner.computeAddress(deployer, salt, initCodeHash);

        assertEq(actual, expected, "Should match CREATE2 formula");
    }

    // ========== Salt Mining Tests ==========

    function test_mineSalt_findsValidSalt() public {
        // Use a simple init code hash
        bytes32 initCodeHash = keccak256("test init code for mining");

        // Mine a salt
        (bytes32 salt, address predictedAddr) = HookAddressMiner.mineSaltForUltraAlignmentHook(
            MOCK_DEPLOYER,
            initCodeHash
        );

        emit log_named_bytes32("Found salt", salt);
        emit log_named_address("Predicted address", predictedAddr);
        emit log_named_uint("Last 14 bits (hex)", uint160(predictedAddr) & ALL_HOOK_FLAGS);

        // Verify the address has exactly the right flags
        assertTrue(
            HookAddressMiner.isValidUltraAlignmentHookAddress(predictedAddr),
            "Mined address should be valid"
        );

        // Verify required flags are set
        assertEq(
            uint160(predictedAddr) & REQUIRED_FLAGS,
            REQUIRED_FLAGS,
            "Required flags must be set"
        );

        // Verify forbidden flags are NOT set
        assertEq(
            uint160(predictedAddr) & FORBIDDEN_FLAGS,
            0,
            "Forbidden flags must not be set"
        );

        // Verify the computed address matches
        address computed = HookAddressMiner.computeAddress(MOCK_DEPLOYER, salt, initCodeHash);
        assertEq(computed, predictedAddr, "Computed address should match predicted");
    }

    function test_mineSalt_differentInputsProduceDifferentSalts() public {
        bytes32 initCodeHash1 = keccak256("init code 1");
        bytes32 initCodeHash2 = keccak256("init code 2");

        (bytes32 salt1, address addr1) = HookAddressMiner.mineSaltForUltraAlignmentHook(
            MOCK_DEPLOYER,
            initCodeHash1
        );

        (bytes32 salt2, address addr2) = HookAddressMiner.mineSaltForUltraAlignmentHook(
            MOCK_DEPLOYER,
            initCodeHash2
        );

        emit log_named_bytes32("Salt 1", salt1);
        emit log_named_bytes32("Salt 2", salt2);
        emit log_named_address("Address 1", addr1);
        emit log_named_address("Address 2", addr2);

        // Both should be valid
        assertTrue(HookAddressMiner.isValidUltraAlignmentHookAddress(addr1), "addr1 should be valid");
        assertTrue(HookAddressMiner.isValidUltraAlignmentHookAddress(addr2), "addr2 should be valid");

        // Addresses should be different (different init codes)
        assertTrue(addr1 != addr2, "Different init codes should produce different addresses");
    }

    // ========== Flag Decoding Tests ==========

    function test_decodeFlags_correctlyIdentifiesFlags() public pure {
        // Address with afterSwap and afterSwapReturnDelta
        address validAddr = address(uint160(0x44));
        Hooks.Permissions memory perms = HookAddressMiner.decodeFlags(validAddr);

        assertTrue(perms.afterSwap, "afterSwap should be true");
        assertTrue(perms.afterSwapReturnDelta, "afterSwapReturnDelta should be true");
        assertFalse(perms.beforeSwap, "beforeSwap should be false");
        assertFalse(perms.beforeInitialize, "beforeInitialize should be false");
        assertFalse(perms.afterInitialize, "afterInitialize should be false");
    }

    function test_decodeFlags_allFlagsSet() public pure {
        // Address with all flags
        address allFlagsAddr = address(uint160(0x3FFF));
        Hooks.Permissions memory perms = HookAddressMiner.decodeFlags(allFlagsAddr);

        assertTrue(perms.beforeInitialize, "beforeInitialize should be true");
        assertTrue(perms.afterInitialize, "afterInitialize should be true");
        assertTrue(perms.beforeAddLiquidity, "beforeAddLiquidity should be true");
        assertTrue(perms.afterAddLiquidity, "afterAddLiquidity should be true");
        assertTrue(perms.beforeRemoveLiquidity, "beforeRemoveLiquidity should be true");
        assertTrue(perms.afterRemoveLiquidity, "afterRemoveLiquidity should be true");
        assertTrue(perms.beforeSwap, "beforeSwap should be true");
        assertTrue(perms.afterSwap, "afterSwap should be true");
        assertTrue(perms.beforeDonate, "beforeDonate should be true");
        assertTrue(perms.afterDonate, "afterDonate should be true");
        assertTrue(perms.beforeSwapReturnDelta, "beforeSwapReturnDelta should be true");
        assertTrue(perms.afterSwapReturnDelta, "afterSwapReturnDelta should be true");
        assertTrue(perms.afterAddLiquidityReturnDelta, "afterAddLiquidityReturnDelta should be true");
        assertTrue(perms.afterRemoveLiquidityReturnDelta, "afterRemoveLiquidityReturnDelta should be true");
    }
}
