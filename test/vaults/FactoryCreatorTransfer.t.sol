// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

/// @notice Lightweight mock that isolates the factoryCreator two-step transfer logic.
/// Avoids pulling in UltraAlignmentVault's full constructor dependency tree
/// (PoolManager, V3Router, V2Router, etc.) so the test stays fast and focused.
contract MockFactoryCreatorVault {
    address public factoryCreator;
    address public pendingFactoryCreator;
    uint256 public accumulatedCreatorFees;

    event FactoryCreatorFeesWithdrawn(uint256 amount);
    event FactoryCreatorTransferInitiated(address indexed current, address indexed pending);
    event FactoryCreatorTransferAccepted(address indexed oldCreator, address indexed newCreator);

    constructor(address _factoryCreator) {
        factoryCreator = _factoryCreator;
    }

    function withdrawCreatorFees() external {
        require(msg.sender == factoryCreator, "Only factory creator");
        uint256 amount = accumulatedCreatorFees;
        require(amount > 0, "No creator fees");
        accumulatedCreatorFees = 0;
        (bool success, ) = payable(factoryCreator).call{value: amount}("");
        require(success, "ETH transfer failed");
        emit FactoryCreatorFeesWithdrawn(amount);
    }

    function transferFactoryCreator(address newCreator) external {
        require(msg.sender == factoryCreator, "Only factory creator");
        require(newCreator != address(0), "Invalid address");
        require(newCreator != factoryCreator, "Already creator");
        pendingFactoryCreator = newCreator;
        emit FactoryCreatorTransferInitiated(factoryCreator, newCreator);
    }

    function acceptFactoryCreator() external {
        require(msg.sender == pendingFactoryCreator, "Only pending creator");
        address old = factoryCreator;
        factoryCreator = pendingFactoryCreator;
        pendingFactoryCreator = address(0);
        emit FactoryCreatorTransferAccepted(old, factoryCreator);
    }

    function creator() external view returns (address) {
        return factoryCreator;
    }

    /// @dev Helper to simulate fee accrual for testing withdrawals
    function simulateCreatorFeeAccrual(uint256 amount) external payable {
        require(msg.value == amount, "Must send exact ETH");
        accumulatedCreatorFees += amount;
    }

    receive() external payable {}
}

contract FactoryCreatorTransferTest is Test {
    MockFactoryCreatorVault public vault;

    address public originalCreator = address(0xC1EA);
    address public newCreator = address(0xC2EA);
    address public randomUser = address(0xBEEF);

    function setUp() public {
        vault = new MockFactoryCreatorVault(originalCreator);
        vm.deal(address(vault), 100 ether);
    }

    // ========== Two-Step Transfer Tests ==========

    function test_TransferFactoryCreator_TwoStep() public {
        // Step 1: Original creator initiates transfer
        vm.prank(originalCreator);
        vault.transferFactoryCreator(newCreator);

        // Verify pending state
        assertEq(vault.pendingFactoryCreator(), newCreator);
        assertEq(vault.factoryCreator(), originalCreator); // Still original

        // Step 2: New creator accepts
        vm.prank(newCreator);
        vault.acceptFactoryCreator();

        // Verify final state
        assertEq(vault.factoryCreator(), newCreator);
        assertEq(vault.pendingFactoryCreator(), address(0));
        assertEq(vault.creator(), newCreator);
    }

    function test_TransferFactoryCreator_RevertIfNotCreator() public {
        // Random user cannot initiate transfer
        vm.prank(randomUser);
        vm.expectRevert("Only factory creator");
        vault.transferFactoryCreator(newCreator);
    }

    function test_AcceptFactoryCreator_RevertIfNotPending() public {
        // Initiate transfer first
        vm.prank(originalCreator);
        vault.transferFactoryCreator(newCreator);

        // Random user cannot accept
        vm.prank(randomUser);
        vm.expectRevert("Only pending creator");
        vault.acceptFactoryCreator();

        // Original creator cannot accept either
        vm.prank(originalCreator);
        vm.expectRevert("Only pending creator");
        vault.acceptFactoryCreator();
    }

    function test_NewCreator_CanWithdrawFees() public {
        // Accrue some creator fees
        vault.simulateCreatorFeeAccrual{value: 1 ether}(1 ether);

        // Transfer creator role
        vm.prank(originalCreator);
        vault.transferFactoryCreator(newCreator);
        vm.prank(newCreator);
        vault.acceptFactoryCreator();

        // New creator can withdraw
        uint256 balBefore = newCreator.balance;
        vm.prank(newCreator);
        vault.withdrawCreatorFees();
        assertEq(newCreator.balance - balBefore, 1 ether);
    }

    function test_OldCreator_CannotWithdrawAfterTransfer() public {
        // Accrue some creator fees
        vault.simulateCreatorFeeAccrual{value: 1 ether}(1 ether);

        // Transfer creator role
        vm.prank(originalCreator);
        vault.transferFactoryCreator(newCreator);
        vm.prank(newCreator);
        vault.acceptFactoryCreator();

        // Old creator cannot withdraw
        vm.prank(originalCreator);
        vm.expectRevert("Only factory creator");
        vault.withdrawCreatorFees();
    }

    // ========== Edge Cases ==========

    function test_TransferFactoryCreator_RevertIfZeroAddress() public {
        vm.prank(originalCreator);
        vm.expectRevert("Invalid address");
        vault.transferFactoryCreator(address(0));
    }

    function test_TransferFactoryCreator_RevertIfSameCreator() public {
        vm.prank(originalCreator);
        vm.expectRevert("Already creator");
        vault.transferFactoryCreator(originalCreator);
    }

    function test_AcceptFactoryCreator_RevertIfNoPending() public {
        // No transfer initiated, pendingFactoryCreator is address(0)
        vm.prank(randomUser);
        vm.expectRevert("Only pending creator");
        vault.acceptFactoryCreator();
    }

    function test_TransferFactoryCreator_EmitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit MockFactoryCreatorVault.FactoryCreatorTransferInitiated(originalCreator, newCreator);

        vm.prank(originalCreator);
        vault.transferFactoryCreator(newCreator);
    }

    function test_AcceptFactoryCreator_EmitsEvent() public {
        vm.prank(originalCreator);
        vault.transferFactoryCreator(newCreator);

        vm.expectEmit(true, true, false, false);
        emit MockFactoryCreatorVault.FactoryCreatorTransferAccepted(originalCreator, newCreator);

        vm.prank(newCreator);
        vault.acceptFactoryCreator();
    }
}
