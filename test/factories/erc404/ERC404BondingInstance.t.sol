// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {ERC404BondingInstance} from "../../../src/factories/erc404/ERC404BondingInstance.sol";
import {ERC404Factory} from "../../../src/factories/erc404/ERC404Factory.sol";

/**
 * @title ERC404BondingInstanceTest
 * @notice Comprehensive test suite for ERC404BondingInstance
 * @dev Tests bonding curve, password-protected tiers, messages, and V4 liquidity
 */
contract ERC404BondingInstanceTest is Test {
    ERC404BondingInstance public instance;
    ERC404Factory public factory;
    
    address public owner = address(0x1);
    address public user1 = address(0x2);
    address public user2 = address(0x3);
    
    // Test parameters
    uint256 constant MAX_SUPPLY = 10_000_000 * 1e18;
    uint256 constant LIQUIDITY_RESERVE_PERCENT = 10;
    
    ERC404BondingInstance.BondingCurveParams curveParams;
    ERC404BondingInstance.TierConfig tierConfig;
    
    bytes32 public passwordHash1;
    bytes32 public passwordHash2;
    
    // Mock addresses (would need proper mocks in full implementation)
    address public mockV4PoolManager = address(0x100);
    address public mockV4Hook = address(0x200);
    address public mockWETH = address(0x300);
    address public mockMasterRegistry = address(0x400);
    address public mockHookFactory = address(0x500);

    function setUp() public {
        vm.startPrank(owner);
        
        // Set up password hashes
        passwordHash1 = keccak256("password1");
        passwordHash2 = keccak256("password2");
        
        // Set up bonding curve parameters (matching CULTEXEC404 defaults)
        curveParams = ERC404BondingInstance.BondingCurveParams({
            initialPrice: 0.025 ether,
            quarticCoeff: 3 gwei,        // 12/4 * 1 gwei
            cubicCoeff: 1333333333,       // 4/3 * 1 gwei  
            quadraticCoeff: 2 gwei,      // 4/2 * 1 gwei
            normalizationFactor: 1e7     // 10M tokens
        });
        
        // Set up tier config (volume cap mode)
        bytes32[] memory passwordHashes = new bytes32[](2);
        passwordHashes[0] = passwordHash1;
        passwordHashes[1] = passwordHash2;
        
        uint256[] memory volumeCaps = new uint256[](2);
        volumeCaps[0] = 1000 * 1e18;  // Tier 1: 1000 tokens
        volumeCaps[1] = 10000 * 1e18; // Tier 2: 10000 tokens
        
        tierConfig = ERC404BondingInstance.TierConfig({
            tierType: ERC404BondingInstance.TierType.VOLUME_CAP,
            passwordHashes: passwordHashes,
            volumeCaps: volumeCaps,
            tierUnlockTimes: new uint256[](0) // Not used in volume cap mode
        });
        
        // Deploy instance
        // Note: Factory must match msg.sender for DN404Mirror linking to work
        // Since we're pranked as 'owner', factory must be 'owner'
        instance = new ERC404BondingInstance(
            "Test Token",
            "TEST",
            MAX_SUPPLY,
            LIQUIDITY_RESERVE_PERCENT,
            curveParams,
            tierConfig,
            mockV4PoolManager,
            address(0), // Hook set later
            mockWETH,
            owner, // Factory must match msg.sender (pranked as owner)
            mockMasterRegistry, // MasterRegistry
            owner,
            "" // styleUri
        );
        
        vm.stopPrank();
    }

    function test_Deployment() public {
        assertEq(instance.MAX_SUPPLY(), MAX_SUPPLY);
        assertEq(instance.LIQUIDITY_RESERVE(), MAX_SUPPLY * LIQUIDITY_RESERVE_PERCENT / 100);
        assertEq(address(instance.v4PoolManager()), mockV4PoolManager);
        assertEq(address(instance.weth()), mockWETH);
    }

    function test_SetBondingOpenTime() public {
        vm.startPrank(owner);
        uint256 futureTime = block.timestamp + 1 days;
        instance.setBondingOpenTime(futureTime);
        assertEq(instance.bondingOpenTime(), futureTime);
        vm.stopPrank();
    }

    function test_SetBondingOpenTime_RevertIfNotOwner() public {
        vm.startPrank(user1);
        vm.expectRevert();
        instance.setBondingOpenTime(block.timestamp + 1 days);
        vm.stopPrank();
    }

    function test_SetBondingActive() public {
        vm.startPrank(owner);
        uint256 futureTime = block.timestamp + 1 days;
        instance.setBondingOpenTime(futureTime);
        instance.setV4Hook(mockV4Hook);
        instance.setBondingActive(true);
        assertTrue(instance.bondingActive());
        vm.stopPrank();
    }

    function test_TierPasswordVerification() public {
        // Test that password verification happens inline during buyBonding
        // Previously users had to call unlockTier() first, now it's checked at purchase
        vm.startPrank(owner);
        uint256 futureTime = block.timestamp + 1 days;
        instance.setBondingOpenTime(futureTime);
        instance.setV4Hook(mockV4Hook);
        instance.setBondingActive(true);
        vm.stopPrank();

        vm.warp(futureTime);
        vm.deal(user1, 10 ether);

        vm.startPrank(user1);
        uint256 buyAmount = 1000 * 1e18;
        uint256 cost = instance.calculateCost(buyAmount);
        // Should succeed with valid password (inlined verification)
        instance.buyBonding{value: cost}(buyAmount, cost, false, passwordHash1, "");
        vm.stopPrank();
    }

    function test_CalculateCost() public {
        uint256 amount = 1000 * 1e18;
        uint256 cost = instance.calculateCost(amount);
        assertGt(cost, 0);
    }

    function test_CalculateRefund() public {
        // First buy some tokens
        vm.startPrank(owner);
        uint256 futureTime = block.timestamp + 1 days;
        instance.setBondingOpenTime(futureTime);
        instance.setV4Hook(mockV4Hook);
        instance.setBondingActive(true);
        vm.stopPrank();
        
        vm.warp(futureTime);
        vm.deal(user1, 10 ether);
        
        vm.startPrank(user1);
        uint256 buyAmount = 1000 * 1e18;
        uint256 cost = instance.calculateCost(buyAmount);
        instance.buyBonding{value: cost}(buyAmount, cost, false, bytes32(0), "");
        vm.stopPrank();
        
        // Now calculate refund
        uint256 refund = instance.calculateRefund(buyAmount);
        assertGt(refund, 0);
        // In a symmetric bonding curve without fees, refund equals cost
        assertEq(refund, cost);
    }

    // Note: Full implementation would require:
    // - Mock DN404 implementation
    // - Mock V4 PoolManager
    // - Mock V4 Hook
    // - Proper liquidity deployment tests
    // - Message system tests
    // - Balance mint tests
    // - Time-based tier tests
    // - Volume cap enforcement tests
}

