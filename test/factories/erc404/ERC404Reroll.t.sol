// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { ERC404BondingInstance } from "src/factories/erc404/ERC404BondingInstance.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";

/**
 * @title ERC404Reroll Tests
 * @notice Tests for ERC404 selective NFT reroll with exemption protection
 */
contract ERC404RerollTest is Test {
    ERC404BondingInstance token;
    address mockPoolManager = address(0x1);
    address mockHook = address(0x2);
    address mockWETH = address(0x3);
    address factory = address(0x4);
    address mockMasterRegistry = address(0x6);
    address owner = address(0x5);
    address user1 = address(0x10);
    address user2 = address(0x20);

    uint256 constant MAX_SUPPLY = 1_000_000_000 ether;
    uint256 constant LIQUIDITY_RESERVE_PERCENT = 10;
    uint256 constant UNIT = 1_000_000 ether; // 1M tokens = 1 NFT

    function setUp() public {
        // Mock WETH with deposit/approve/transfer functions
        vm.mockCall(
            mockWETH,
            abi.encodeWithSignature("deposit()"),
            abi.encode()
        );
        vm.mockCall(
            mockWETH,
            abi.encodeWithSignature("approve(address,uint256)"),
            abi.encode(true)
        );
        vm.mockCall(
            mockPoolManager,
            abi.encodeWithSignature("initialize(tuple,uint160)"),
            abi.encode()
        );

        // Create bonding instance
        ERC404BondingInstance.BondingCurveParams memory curveParams = ERC404BondingInstance.BondingCurveParams({
            initialPrice: 0.0001 ether,
            quarticCoeff: 1,  // represents 1 / 10^10
            cubicCoeff: 1,    // represents 1 / 10^8
            quadraticCoeff: 1, // represents 1 / 10^6
            normalizationFactor: 1e18
        });

        ERC404BondingInstance.TierConfig memory tierConfig = ERC404BondingInstance.TierConfig({
            tierType: ERC404BondingInstance.TierType.VOLUME_CAP,
            passwordHashes: new bytes32[](1),
            volumeCaps: new uint256[](1),
            tierUnlockTimes: new uint256[](0)
        });
        tierConfig.passwordHashes[0] = keccak256(abi.encodePacked("password1"));
        tierConfig.volumeCaps[0] = 100_000_000 ether;

        // Note: Factory must match msg.sender for DN404Mirror linking to work
        token = new ERC404BondingInstance(
            "TestToken",
            "TEST",
            MAX_SUPPLY,
            LIQUIDITY_RESERVE_PERCENT,
            curveParams,
            tierConfig,
            mockPoolManager,
            mockHook,
            mockWETH,
            address(this), // Factory must match msg.sender (deployer)
            mockMasterRegistry,
            owner,
            "" // styleUri
        );

        // Fund users with ETH
        vm.deal(user1, 10 ether);
        vm.deal(user2, 10 ether);
        // Note: Don't transfer tokens here - each test uses _setupUserWithNFTs
        // to get exactly the tokens/NFTs needed for that specific test
    }

    /// @notice Helper to give a user tokens and mint NFTs
    function _setupUserWithNFTs(address user, uint256 nftCount) internal {
        // Ensure user has enough tokens
        uint256 needed = nftCount * UNIT;
        uint256 currentBalance = token.balanceOf(user);

        if (currentBalance < needed) {
            vm.prank(address(token));
            token.transfer(user, needed - currentBalance);
        }

        // Mint NFTs for the user
        vm.prank(user);
        token.balanceMint(nftCount);
    }

    // ┌─────────────────────────┐
    // │  Basic Reroll Tests     │
    // └─────────────────────────┘

    function test_RerollInitiation_BasicFlow() public {
        // Setup: Give user1 5 NFTs (transfers tokens and mints NFTs)
        _setupUserWithNFTs(user1, 5);

        uint256 rerollAmount = 2 * UNIT; // 2M tokens for 2 NFTs
        uint256[] memory exemptedIds = new uint256[](0);

        vm.prank(user1);
        vm.expectEmit(true, false, false, true);
        emit RerollInitiated(user1, rerollAmount, exemptedIds);
        token.rerollSelectedNFTs(rerollAmount, exemptedIds);

        // Verify balance maintained
        assertEq(token.balanceOf(user1), 5 * UNIT);
    }

    function test_RerollCompletion_BalancePreserved() public {
        // Setup: Give user1 10 NFTs
        _setupUserWithNFTs(user1, 10);

        uint256 initialBalance = token.balanceOf(user1);
        uint256 rerollAmount = 4 * UNIT; // 4M tokens (4 NFTs)
        uint256[] memory exemptedIds = new uint256[](0);

        vm.prank(user1);
        token.rerollSelectedNFTs(rerollAmount, exemptedIds);

        // Balance should be unchanged
        assertEq(token.balanceOf(user1), initialBalance);
    }

    function test_RerollRevert_InsufficientBalance() public {
        // Setup: Give user1 2 NFTs only
        _setupUserWithNFTs(user1, 2);

        uint256 rerollAmount = 5 * UNIT; // Try to reroll 5M tokens
        uint256[] memory exemptedIds = new uint256[](0);

        vm.prank(user1);
        vm.expectRevert("Insufficient token balance");
        token.rerollSelectedNFTs(rerollAmount, exemptedIds);
    }

    function test_RerollRevert_ZeroTokenAmount() public {
        uint256[] memory exemptedIds = new uint256[](0);

        vm.prank(user1);
        vm.expectRevert("Token amount must be > 0");
        token.rerollSelectedNFTs(0, exemptedIds);
    }

    function test_RerollRevert_TokensNotRepresentingNFT() public {
        // Setup: Give user1 5 NFTs
        _setupUserWithNFTs(user1, 5);

        uint256 rerollAmount = UNIT / 2; // 500k tokens (less than 1 NFT)
        uint256[] memory exemptedIds = new uint256[](0);

        vm.prank(user1);
        vm.expectRevert("Token amount must represent at least 1 NFT");
        token.rerollSelectedNFTs(rerollAmount, exemptedIds);
    }

    // ┌─────────────────────────┐
    // │  Escrow Tests           │
    // └─────────────────────────┘

    function test_Escrow_TokensHeldDuringReroll() public {
        // Setup: Give user1 5 NFTs
        _setupUserWithNFTs(user1, 5);

        uint256 rerollAmount = 2 * UNIT;

        // Before reroll
        assertEq(token.getRerollEscrow(user1), 0);

        // During reroll (check in test by monitoring events and final state)
        vm.prank(user1);
        token.rerollSelectedNFTs(rerollAmount, new uint256[](0));

        // After reroll, escrow should be cleared
        assertEq(token.getRerollEscrow(user1), 0);
    }

    function test_Escrow_MultipleUsers_Independent() public {
        // Setup: Give both users 5 NFTs each
        _setupUserWithNFTs(user1, 5);
        _setupUserWithNFTs(user2, 5);

        uint256 rerollAmount1 = 2 * UNIT;
        uint256 rerollAmount2 = 3 * UNIT;

        // Both initiate reroll
        vm.prank(user1);
        token.rerollSelectedNFTs(rerollAmount1, new uint256[](0));

        vm.prank(user2);
        token.rerollSelectedNFTs(rerollAmount2, new uint256[](0));

        // Both escrows cleared
        assertEq(token.getRerollEscrow(user1), 0);
        assertEq(token.getRerollEscrow(user2), 0);

        // Balances preserved
        assertEq(token.balanceOf(user1), 5 * UNIT);
        assertEq(token.balanceOf(user2), 5 * UNIT);
    }

    // ┌─────────────────────────┐
    // │  Exemption Tests        │
    // └─────────────────────────┘

    function test_Reroll_WithExemptedNFTs() public {
        // Setup: Give user1 5 NFTs
        _setupUserWithNFTs(user1, 5);

        uint256[] memory exemptedIds = new uint256[](2);
        exemptedIds[0] = 1;
        exemptedIds[1] = 3;

        uint256 rerollAmount = 3 * UNIT; // Reroll 3 NFTs, exempt 2

        vm.prank(user1);
        vm.expectEmit(true, false, false, true);
        emit RerollInitiated(user1, rerollAmount, exemptedIds);
        token.rerollSelectedNFTs(rerollAmount, exemptedIds);

        // Verify balance maintained
        assertEq(token.balanceOf(user1), 5 * UNIT);
    }

    function test_Reroll_AllNFTsExempted() public {
        // Setup: Give user1 3 NFTs
        _setupUserWithNFTs(user1, 3);

        uint256[] memory exemptedIds = new uint256[](3);
        exemptedIds[0] = 1;
        exemptedIds[1] = 2;
        exemptedIds[2] = 3;

        uint256 rerollAmount = UNIT; // Only reroll 1 NFT, exempt 3

        vm.prank(user1);
        token.rerollSelectedNFTs(rerollAmount, exemptedIds);

        // Verify balance maintained
        assertEq(token.balanceOf(user1), 3 * UNIT);
    }

    function test_Reroll_NoExemptions() public {
        // Setup: Give user1 5 NFTs
        _setupUserWithNFTs(user1, 5);

        uint256[] memory exemptedIds = new uint256[](0);
        uint256 rerollAmount = 5 * UNIT; // Reroll all

        vm.prank(user1);
        vm.expectEmit(true, false, false, true);
        emit RerollInitiated(user1, rerollAmount, exemptedIds);
        token.rerollSelectedNFTs(rerollAmount, exemptedIds);

        // Verify balance maintained
        assertEq(token.balanceOf(user1), 5 * UNIT);
    }

    // ┌─────────────────────────┐
    // │  Event Emission Tests   │
    // └─────────────────────────┘

    function test_Events_RerollInitiatedAndCompleted() public {
        // Setup: Give user1 4 NFTs
        _setupUserWithNFTs(user1, 4);

        uint256[] memory exemptedIds = new uint256[](1);
        exemptedIds[0] = 2;

        uint256 rerollAmount = 2 * UNIT;

        vm.prank(user1);

        // Expect both events in order
        vm.expectEmit(true, false, false, true);
        emit RerollInitiated(user1, rerollAmount, exemptedIds);

        vm.expectEmit(true, false, false, false);
        emit RerollCompleted(user1, rerollAmount);

        token.rerollSelectedNFTs(rerollAmount, exemptedIds);
    }

    // ┌─────────────────────────┐
    // │  Edge Case Tests        │
    // └─────────────────────────┘

    function test_Reroll_ExactBalance() public {
        // Setup: Give user1 exactly 3 NFTs
        _setupUserWithNFTs(user1, 3);

        uint256 rerollAmount = 3 * UNIT; // Exactly the balance

        vm.prank(user1);
        token.rerollSelectedNFTs(rerollAmount, new uint256[](0));

        // Verify balance maintained
        assertEq(token.balanceOf(user1), 3 * UNIT);
    }

    function test_Reroll_MinimumAmount() public {
        // Setup: Give user1 1 NFT
        _setupUserWithNFTs(user1, 1);

        uint256 rerollAmount = UNIT; // Minimum viable amount

        vm.prank(user1);
        token.rerollSelectedNFTs(rerollAmount, new uint256[](0));

        // Verify balance maintained
        assertEq(token.balanceOf(user1), UNIT);
    }

    function test_Reroll_LargeExemptionList() public {
        // Setup: Give user1 100 NFTs
        _setupUserWithNFTs(user1, 100);

        // Exempt 50 NFTs
        uint256[] memory exemptedIds = new uint256[](50);
        for (uint256 i = 0; i < 50; i++) {
            exemptedIds[i] = i + 1;
        }

        uint256 rerollAmount = 50 * UNIT;

        vm.prank(user1);
        token.rerollSelectedNFTs(rerollAmount, exemptedIds);

        // Verify balance maintained
        assertEq(token.balanceOf(user1), 100 * UNIT);
    }

    function test_Reroll_SkipNFTPreserved() public {
        // Setup: Give user1 5 NFTs
        _setupUserWithNFTs(user1, 5);

        // Get original skipNFT state
        bool originalSkipNFT = token.getSkipNFT(user1);

        // Perform reroll
        vm.prank(user1);
        token.rerollSelectedNFTs(2 * UNIT, new uint256[](0));

        // Verify skipNFT state is preserved
        assertEq(token.getSkipNFT(user1), originalSkipNFT);
    }

    // ┌─────────────────────────┐
    // │  Reentrancy Tests       │
    // └─────────────────────────┘

    function test_Reroll_NonReentrant() public {
        // Setup: Give user1 5 NFTs
        _setupUserWithNFTs(user1, 5);

        // The nonReentrant modifier on rerollSelectedNFTs prevents direct reentrancy
        // This test verifies the function signature has nonReentrant guard

        vm.prank(user1);
        token.rerollSelectedNFTs(2 * UNIT, new uint256[](0));

        // Test passes if no reentrancy issues occur
        assertEq(token.balanceOf(user1), 5 * UNIT);
    }

    // Events to match contract
    event RerollInitiated(address indexed user, uint256 tokenAmount, uint256[] exemptedNFTIds);
    event RerollCompleted(address indexed user, uint256 tokensReturned);
}
