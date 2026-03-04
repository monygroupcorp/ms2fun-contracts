// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RevenueSplitLib} from "../../src/shared/libraries/RevenueSplitLib.sol";

/// @title RevenueSplitInvariantTest
/// @notice Fuzz-based invariant: protocolCut + vaultCut + remainder == input (no wei leak or creation)
contract RevenueSplitInvariantTest is Test {
    // amount * 19 must not overflow; cap at type(uint256).max / 19
    uint256 constant MAX_AMOUNT = type(uint256).max / 19;

    function testFuzz_splitSumsToInput(uint256 amount) external pure {
        amount = bound(amount, 0, MAX_AMOUNT);
        RevenueSplitLib.Split memory s = RevenueSplitLib.split(amount);
        assertEq(
            s.protocolCut + s.vaultCut + s.remainder,
            amount,
            "split leaks or creates wei"
        );
    }

    function testFuzz_protocolCutIsOnePercFloor(uint256 amount) external pure {
        amount = bound(amount, 0, MAX_AMOUNT);
        RevenueSplitLib.Split memory s = RevenueSplitLib.split(amount);
        assertEq(s.protocolCut, amount / 100, "protocolCut != floor(amount/100)");
    }

    function testFuzz_vaultCutIsNineteenPercFloor(uint256 amount) external pure {
        amount = bound(amount, 0, MAX_AMOUNT);
        RevenueSplitLib.Split memory s = RevenueSplitLib.split(amount);
        assertEq(s.vaultCut, (amount * 19) / 100, "vaultCut != floor(amount*19/100)");
    }

    function testFuzz_remainderAbsorbsDust(uint256 amount) external pure {
        amount = bound(amount, 0, MAX_AMOUNT);
        RevenueSplitLib.Split memory s = RevenueSplitLib.split(amount);
        uint256 expected = amount - (amount / 100) - ((amount * 19) / 100);
        assertEq(s.remainder, expected, "remainder doesn't absorb rounding dust");
    }

    function testFuzz_remainderGteEightyPercent(uint256 amount) external pure {
        amount = bound(amount, 100, MAX_AMOUNT);
        RevenueSplitLib.Split memory s = RevenueSplitLib.split(amount);
        // remainder >= 80% floor: remainder absorbs dust so it's always >= floor(80%)
        assertGe(s.remainder, amount / 100 * 80, "remainder below 80%");
    }

    function test_splitZero() external pure {
        RevenueSplitLib.Split memory s = RevenueSplitLib.split(0);
        assertEq(s.protocolCut, 0);
        assertEq(s.vaultCut, 0);
        assertEq(s.remainder, 0);
    }

    function test_splitOne() external pure {
        RevenueSplitLib.Split memory s = RevenueSplitLib.split(1);
        assertEq(s.protocolCut, 0);
        assertEq(s.vaultCut, 0);
        assertEq(s.remainder, 1);
    }

    function test_splitHundred() external pure {
        RevenueSplitLib.Split memory s = RevenueSplitLib.split(100);
        assertEq(s.protocolCut, 1);
        assertEq(s.vaultCut, 19);
        assertEq(s.remainder, 80);
    }

    function test_splitNinetyNine() external pure {
        RevenueSplitLib.Split memory s = RevenueSplitLib.split(99);
        assertEq(s.protocolCut, 0);
        assertEq(s.vaultCut, 18);
        assertEq(s.remainder, 81);
    }

    function test_splitOneEther() external pure {
        RevenueSplitLib.Split memory s = RevenueSplitLib.split(1 ether);
        assertEq(s.protocolCut, 0.01 ether);
        assertEq(s.vaultCut, 0.19 ether);
        assertEq(s.remainder, 0.80 ether);
    }

    function testFuzz_SplitSumsToTotal(uint256 amount) external pure {
        amount = bound(amount, 0, MAX_AMOUNT);
        RevenueSplitLib.Split memory s = RevenueSplitLib.split(amount);
        assertEq(
            s.protocolCut + s.vaultCut + s.remainder,
            amount,
            "protocol + vault + remainder != amount"
        );
    }

    function testFuzz_ProtocolNeverExceedsOnePercent(uint256 amount) external pure {
        amount = bound(amount, 0, MAX_AMOUNT);
        RevenueSplitLib.Split memory s = RevenueSplitLib.split(amount);
        assertLe(s.protocolCut, amount / 100, "protocol exceeds 1%");
    }

    function testFuzz_VaultNeverExceedsNineteenPercent(uint256 amount) external pure {
        amount = bound(amount, 0, MAX_AMOUNT);
        RevenueSplitLib.Split memory s = RevenueSplitLib.split(amount);
        assertLe(s.vaultCut, (amount * 19) / 100, "vault exceeds 19%");
    }
}
