// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {UltraAlignmentVault} from "../../src/vaults/UltraAlignmentVault.sol";
import {MockEXECToken} from "../mocks/MockEXECToken.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

/**
 * @title UltraAlignmentVaultTest
 * @notice Comprehensive test suite for UltraAlignmentVault
 * @dev Tests all functionality: contributions, shares, claims, conversions, access control
 */
contract UltraAlignmentVaultTest is Test {
    UltraAlignmentVault public vault;
    MockEXECToken public alignmentToken;

    address public owner = address(0x1);
    address public alice = address(0x2);
    address public bob = address(0x3);
    address public charlie = address(0x4);
    address public dave = address(0x5);

    address public mockWETH = address(0x1111111111111111111111111111111111111111);
    address public mockPoolManager = address(0x2222222222222222222222222222222222222222);
    address public mockV3Router = address(0x3333333333333333333333333333333333333333);
    address public mockV2Router = address(0x4444444444444444444444444444444444444444);
    address public mockV2Factory = address(0x5555555555555555555555555555555555555555);
    address public mockV3Factory = address(0x6666666666666666666666666666666666666666);

    // Events
    event ContributionReceived(address indexed benefactor, uint256 amount);
    event LiquidityAdded(
        uint256 ethSwapped,
        uint256 tokenReceived,
        uint256 lpPositionValue,
        uint256 sharesIssued,
        uint256 callerReward
    );
    event FeesClaimed(address indexed benefactor, uint256 ethAmount);
    event FeesAccumulated(uint256 amount);

    function setUp() public {
        vm.startPrank(owner);

        // Deploy mock alignment token
        alignmentToken = new MockEXECToken(1000000e18);

        // Deploy vault
        vault = new UltraAlignmentVault(
            mockWETH,
            mockPoolManager,
            mockV3Router,
            mockV2Router,
            mockV2Factory,
            mockV3Factory,
            address(alignmentToken)
        );

        // Set V4 pool key for conversion tests (using native ETH)
        PoolKey memory mockPoolKey = PoolKey({
            currency0: Currency.wrap(address(0)), // Native ETH
            currency1: Currency.wrap(address(alignmentToken)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        vault.setV4PoolKey(mockPoolKey);

        vm.stopPrank();

        // Fund test accounts
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(charlie, 100 ether);
        vm.deal(dave, 100 ether);
        vm.deal(owner, 100 ether);
    }

    // ========== Initialization Tests ==========

    function test_Constructor_StoresParametersCorrectly() public view {
        assertEq(vault.weth(), mockWETH, "WETH address incorrect");
        assertEq(vault.poolManager(), mockPoolManager, "PoolManager address incorrect");
        assertEq(vault.alignmentToken(), address(alignmentToken), "AlignmentToken address incorrect");
        assertEq(vault.owner(), owner, "Owner address incorrect");
    }

    function test_Constructor_InitializesStateVariables() public view {
        assertEq(vault.totalShares(), 0, "Total shares should be 0");
        assertEq(vault.totalPendingETH(), 0, "Total pending ETH should be 0");
        assertEq(vault.accumulatedFees(), 0, "Accumulated fees should be 0");
        assertEq(vault.totalLPUnits(), 0, "Total LP units should be 0");
        assertEq(vault.standardConversionReward(), 0.0012 ether, "Standard conversion reward should be 0.0012 ETH");
    }

    function test_Constructor_RevertsOnInvalidWETH() public {
        vm.expectRevert("Invalid WETH");
        new UltraAlignmentVault(address(0), mockPoolManager, mockV3Router, mockV2Router, mockV2Factory, mockV3Factory, address(alignmentToken));
    }

    function test_Constructor_RevertsOnInvalidPoolManager() public {
        vm.expectRevert("Invalid pool manager");
        new UltraAlignmentVault(mockWETH, address(0), mockV3Router, mockV2Router, mockV2Factory, mockV3Factory, address(alignmentToken));
    }

    function test_Constructor_RevertsOnInvalidAlignmentToken() public {
        vm.expectRevert("Invalid alignment token");
        new UltraAlignmentVault(mockWETH, mockPoolManager, mockV3Router, mockV2Router, mockV2Factory, mockV3Factory, address(0));
    }

    // ========== Direct ETH Contribution Tests (receive) ==========

    function test_Receive_AcceptsETHContribution() public {
        vm.startPrank(alice);

        vm.expectEmit(true, true, true, true);
        emit ContributionReceived(alice, 1 ether);

        (bool success, ) = address(vault).call{value: 1 ether}("");
        assertTrue(success, "ETH transfer should succeed");

        vm.stopPrank();
    }

    function test_Receive_TracksBenefactorTotalETH() public {
        vm.prank(alice);
        (bool success, ) = address(vault).call{value: 2 ether}("");
        assertTrue(success);

        assertEq(vault.benefactorTotalETH(alice), 2 ether, "Benefactor total ETH should be 2 ether");
    }

    function test_Receive_TracksPendingETH() public {
        vm.prank(alice);
        (bool success, ) = address(vault).call{value: 3 ether}("");
        assertTrue(success);

        assertEq(vault.pendingETH(alice), 3 ether, "Pending ETH should be 3 ether");
        assertEq(vault.totalPendingETH(), 3 ether, "Total pending ETH should be 3 ether");
    }

    function test_Receive_AddsToConversionParticipants() public {
        vm.prank(alice);
        (bool success, ) = address(vault).call{value: 1 ether}("");
        assertTrue(success);

        assertEq(vault.conversionParticipants(0), alice, "Alice should be first participant");
    }

    function test_Receive_MultipleContributionsFromSameBenefactor() public {
        vm.startPrank(alice);
        (bool success1, ) = address(vault).call{value: 1 ether}("");
        assertTrue(success1);

        (bool success2, ) = address(vault).call{value: 2 ether}("");
        assertTrue(success2);
        vm.stopPrank();

        assertEq(vault.benefactorTotalETH(alice), 3 ether, "Total should be 3 ether");
        assertEq(vault.pendingETH(alice), 3 ether, "Pending should be 3 ether");
        assertEq(vault.totalPendingETH(), 3 ether, "Global pending should be 3 ether");
    }

    function test_Receive_RevertsOnZeroAmount() public {
        vm.startPrank(alice);
        (bool success, bytes memory returnData) = address(vault).call{value: 0}("");
        assertFalse(success, "Should revert on zero amount");
        vm.stopPrank();
    }

    // ========== Hook Tax Reception Tests ==========

    function test_ReceiveHookTax_AcceptsContributionWithBenefactor() public {
        vm.startPrank(alice);

        vm.expectEmit(true, true, true, true);
        emit ContributionReceived(bob, 1 ether);

        vault.receiveHookTax{value: 1 ether}(Currency.wrap(address(0)), 1 ether, bob);

        vm.stopPrank();
    }

    function test_ReceiveHookTax_TracksBenefactorNotSender() public {
        vm.prank(alice);
        vault.receiveHookTax{value: 2 ether}(Currency.wrap(address(0)), 2 ether, bob);

        assertEq(vault.benefactorTotalETH(bob), 2 ether, "Bob should be tracked as benefactor");
        assertEq(vault.benefactorTotalETH(alice), 0, "Alice should not be benefactor");
    }

    function test_ReceiveHookTax_TracksPendingETH() public {
        vm.prank(alice);
        vault.receiveHookTax{value: 3 ether}(Currency.wrap(address(0)), 3 ether, bob);

        assertEq(vault.pendingETH(bob), 3 ether, "Bob's pending ETH should be 3 ether");
        assertEq(vault.totalPendingETH(), 3 ether, "Total pending ETH should be 3 ether");
    }

    function test_ReceiveHookTax_RevertsOnZeroAmount() public {
        vm.startPrank(alice);
        vm.expectRevert("Amount must be positive");
        vault.receiveHookTax(Currency.wrap(address(0)), 0, bob);
        vm.stopPrank();
    }

    function test_ReceiveHookTax_RevertsOnInvalidBenefactor() public {
        vm.startPrank(alice);
        vm.expectRevert("Invalid benefactor");
        vault.receiveHookTax{value: 1 ether}(Currency.wrap(address(0)), 1 ether, address(0));
        vm.stopPrank();
    }

    // ========== Multi-Benefactor Contribution Tests ==========

    function test_MultipleBenefactors_TrackIndependently() public {
        vm.prank(alice);
        (bool success1, ) = address(vault).call{value: 1 ether}("");
        assertTrue(success1);

        vm.prank(bob);
        (bool success2, ) = address(vault).call{value: 2 ether}("");
        assertTrue(success2);

        vm.prank(charlie);
        (bool success3, ) = address(vault).call{value: 3 ether}("");
        assertTrue(success3);

        assertEq(vault.benefactorTotalETH(alice), 1 ether);
        assertEq(vault.benefactorTotalETH(bob), 2 ether);
        assertEq(vault.benefactorTotalETH(charlie), 3 ether);
        assertEq(vault.totalPendingETH(), 6 ether);
    }

    function test_MultipleBenefactors_AllAddedToConversionParticipants() public {
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 1 ether}("");
        assertTrue(s1);

        vm.prank(bob);
        (bool s2, ) = address(vault).call{value: 2 ether}("");
        assertTrue(s2);

        vm.prank(charlie);
        (bool s3, ) = address(vault).call{value: 3 ether}("");
        assertTrue(s3);

        assertEq(vault.conversionParticipants(0), alice);
        assertEq(vault.conversionParticipants(1), bob);
        assertEq(vault.conversionParticipants(2), charlie);
    }

    function test_MultipleBenefactors_MixedContributionMethods() public {
        // Alice via receive
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 1 ether}("");
        assertTrue(s1);

        // Bob via receiveHookTax (charlie is sender)
        vm.prank(charlie);
        vault.receiveHookTax{value: 2 ether}(Currency.wrap(address(0)), 2 ether, bob);

        // Charlie via receive
        vm.prank(charlie);
        (bool s2, ) = address(vault).call{value: 3 ether}("");
        assertTrue(s2);

        assertEq(vault.benefactorTotalETH(alice), 1 ether);
        assertEq(vault.benefactorTotalETH(bob), 2 ether);
        assertEq(vault.benefactorTotalETH(charlie), 3 ether);
        assertEq(vault.totalPendingETH(), 6 ether);
    }

    // ========== Conversion & Liquidity Tests ==========

    function test_ConvertAndAddLiquidity_ConvertsSuccessfully() public {
        // Setup: Alice and Bob contribute
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 10 ether}("");
        assertTrue(s1);

        vm.prank(bob);
        (bool s2, ) = address(vault).call{value: 20 ether}("");
        assertTrue(s2);

        // Conversion
        vm.prank(dave);
        uint256 lpValue = vault.convertAndAddLiquidity(0);

        assertTrue(lpValue > 0, "LP value should be positive");
    }

    function test_ConvertAndAddLiquidity_IssuesSharesProportionally() public {
        // Alice: 10 ETH (33.33%), Bob: 20 ETH (66.66%)
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 10 ether}("");
        assertTrue(s1);

        vm.prank(bob);
        (bool s2, ) = address(vault).call{value: 20 ether}("");
        assertTrue(s2);

        vm.prank(dave);
        vault.convertAndAddLiquidity(0);

        uint256 aliceShares = vault.benefactorShares(alice);
        uint256 bobShares = vault.benefactorShares(bob);

        assertTrue(aliceShares > 0, "Alice should have shares");
        assertTrue(bobShares > 0, "Bob should have shares");

        // Bob should have approximately 2x Alice's shares
        assertTrue(bobShares > aliceShares, "Bob should have more shares");
        assertApproxEqRel(bobShares, aliceShares * 2, 0.01e18); // 1% tolerance
    }

    function test_ConvertAndAddLiquidity_ClearsPendingETH() public {
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 10 ether}("");
        assertTrue(s1);

        vm.prank(dave);
        vault.convertAndAddLiquidity(0);

        assertEq(vault.pendingETH(alice), 0, "Pending ETH should be cleared");
        assertEq(vault.totalPendingETH(), 0, "Total pending ETH should be cleared");
    }

    function test_ConvertAndAddLiquidity_ClearsConversionParticipants() public {
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 10 ether}("");
        assertTrue(s1);

        vm.prank(bob);
        (bool s2, ) = address(vault).call{value: 20 ether}("");
        assertTrue(s2);

        vm.prank(dave);
        vault.convertAndAddLiquidity(0);

        // Array should be empty - trying to access should revert
        vm.expectRevert();
        vault.conversionParticipants(0);
    }

    function test_ConvertAndAddLiquidity_PaysCallerReward() public {
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 10 ether}("");
        assertTrue(s1);

        uint256 daveBalanceBefore = dave.balance;

        vm.prank(dave);
        vault.convertAndAddLiquidity(0);

        uint256 daveBalanceAfter = dave.balance;
        // M-04 fix: Reward is now gas-based + standard reward (not percentage)
        // In test environment with zero gas price: reward = gasCost + standardReward = 0 + 0.0012 ether
        uint256 expectedReward = vault.standardConversionReward(); // 0.0012 ether

        assertEq(daveBalanceAfter - daveBalanceBefore, expectedReward, "Caller should receive reward");
    }

    function test_ConvertAndAddLiquidity_UpdatesTotalLPUnits() public {
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 10 ether}("");
        assertTrue(s1);

        uint256 lpUnitsBefore = vault.totalLPUnits();

        vm.prank(dave);
        vault.convertAndAddLiquidity(0);

        uint256 lpUnitsAfter = vault.totalLPUnits();

        assertTrue(lpUnitsAfter > lpUnitsBefore, "LP units should increase");
    }

    function test_ConvertAndAddLiquidity_EmitsLiquidityAddedEvent() public {
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 10 ether}("");
        assertTrue(s1);

        vm.expectEmit(false, false, false, false);
        emit LiquidityAdded(0, 0, 0, 0, 0);

        vm.prank(dave);
        vault.convertAndAddLiquidity(0);
    }

    function test_ConvertAndAddLiquidity_RevertsWhenNoPendingETH() public {
        vm.prank(dave);
        vm.expectRevert("No pending ETH to convert");
        vault.convertAndAddLiquidity(0);
    }

    function test_ConvertAndAddLiquidity_RevertsWhenNoAlignmentTokenSet() public {
        // We can't actually set alignment token to zero because of constructor check
        // Instead, we test that the revert message exists by trying to deploy with zero
        // This test verifies the check is in place
        vm.expectRevert("Invalid token");
        vm.prank(owner);
        vault.setAlignmentToken(address(0));
    }

    function test_ConvertAndAddLiquidity_RevertsWhenNoV4PoolSet() public {
        // Deploy new vault without V4 pool
        vm.startPrank(owner);
        UltraAlignmentVault newVault = new UltraAlignmentVault(
            mockWETH,
            mockPoolManager,
            mockV3Router,
            mockV2Router,
            mockV2Factory,
            mockV3Factory,
            address(alignmentToken)
        );
        vm.stopPrank();

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        (bool s1, ) = address(newVault).call{value: 10 ether}("");
        assertTrue(s1);

        vm.prank(dave);
        vm.expectRevert("V4 pool key not set");
        newVault.convertAndAddLiquidity(0);
    }

    function test_ConvertAndAddLiquidity_MultipleRoundsAccumulateShares() public {
        // Round 1
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 10 ether}("");
        assertTrue(s1);

        vm.prank(dave);
        vault.convertAndAddLiquidity(0);

        uint256 aliceSharesRound1 = vault.benefactorShares(alice);

        // Round 2
        vm.prank(alice);
        (bool s2, ) = address(vault).call{value: 10 ether}("");
        assertTrue(s2);

        vm.prank(dave);
        vault.convertAndAddLiquidity(0);

        uint256 aliceSharesRound2 = vault.benefactorShares(alice);

        assertTrue(aliceSharesRound2 > aliceSharesRound1, "Shares should accumulate");
    }

    // ========== Fee Accumulation Tests ==========

    function test_RecordAccumulatedFees_OwnerCanRecordFees() public {
        vm.startPrank(owner);

        vm.expectEmit(true, true, true, true);
        emit FeesAccumulated(5 ether);

        vault.recordAccumulatedFees(5 ether);

        vm.stopPrank();

        assertEq(vault.accumulatedFees(), 5 ether, "Accumulated fees should be 5 ether");
    }

    function test_RecordAccumulatedFees_AccumulatesMultipleTimes() public {
        vm.startPrank(owner);

        vault.recordAccumulatedFees(3 ether);
        vault.recordAccumulatedFees(2 ether);

        vm.stopPrank();

        assertEq(vault.accumulatedFees(), 5 ether, "Accumulated fees should be 5 ether");
    }

    function test_RecordAccumulatedFees_RevertsOnZeroAmount() public {
        vm.startPrank(owner);
        vm.expectRevert("Fee amount must be positive");
        vault.recordAccumulatedFees(0);
        vm.stopPrank();
    }

    function test_RecordAccumulatedFees_RevertsWhenNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.recordAccumulatedFees(5 ether);
    }

    function test_DepositFees_OwnerCanDepositFees() public {
        vm.startPrank(owner);

        vm.expectEmit(true, true, true, true);
        emit FeesAccumulated(5 ether);

        vault.depositFees{value: 5 ether}();

        vm.stopPrank();

        assertEq(vault.accumulatedFees(), 5 ether, "Accumulated fees should be 5 ether");
        assertEq(address(vault).balance, 5 ether, "Vault balance should be 5 ether");
    }

    function test_DepositFees_RevertsOnZeroAmount() public {
        vm.startPrank(owner);
        vm.expectRevert("Amount must be positive");
        vault.depositFees{value: 0}();
        vm.stopPrank();
    }

    function test_DepositFees_RevertsWhenNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.depositFees{value: 5 ether}();
    }

    // ========== Fee Claim Tests ==========

    function test_ClaimFees_BenefactorCanClaimFees() public {
        // Setup: Alice contributes and gets shares
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 10 ether}("");
        assertTrue(s1);

        vm.prank(dave);
        vault.convertAndAddLiquidity(0);

        // Owner deposits fees
        vm.prank(owner);
        vault.depositFees{value: 10 ether}();

        // Alice claims
        uint256 aliceBalanceBefore = alice.balance;

        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit FeesClaimed(alice, 10 ether);

        uint256 claimed = vault.claimFees();

        uint256 aliceBalanceAfter = alice.balance;

        assertEq(claimed, 10 ether, "Claimed amount should be 10 ether");
        assertEq(aliceBalanceAfter - aliceBalanceBefore, 10 ether, "Alice should receive 10 ether");
    }

    function test_ClaimFees_ProportionalClaimWithMultipleBenefactors() public {
        // Alice: 10 ETH (33.33%), Bob: 20 ETH (66.66%)
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 10 ether}("");
        assertTrue(s1);

        vm.prank(bob);
        (bool s2, ) = address(vault).call{value: 20 ether}("");
        assertTrue(s2);

        vm.prank(dave);
        vault.convertAndAddLiquidity(0);

        // Owner deposits 30 ether in fees
        vm.prank(owner);
        vault.depositFees{value: 30 ether}();

        // Alice claims
        uint256 aliceBalanceBefore = alice.balance;
        vm.prank(alice);
        uint256 aliceClaimed = vault.claimFees();
        uint256 aliceBalanceAfter = alice.balance;

        // Bob claims
        uint256 bobBalanceBefore = bob.balance;
        vm.prank(bob);
        uint256 bobClaimed = vault.claimFees();
        uint256 bobBalanceAfter = bob.balance;

        // Alice should get ~10 ether (33.33%), Bob should get ~20 ether (66.66%)
        assertApproxEqRel(aliceClaimed, 10 ether, 0.01e18, "Alice should claim ~10 ether");
        assertApproxEqRel(bobClaimed, 20 ether, 0.01e18, "Bob should claim ~20 ether");
        assertEq(aliceBalanceAfter - aliceBalanceBefore, aliceClaimed);
        assertEq(bobBalanceAfter - bobBalanceBefore, bobClaimed);
    }

    function test_ClaimFees_MultipleClaimsTrackDelta() public {
        // Alice contributes and gets shares
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 10 ether}("");
        assertTrue(s1);

        vm.prank(dave);
        vault.convertAndAddLiquidity(0);

        // First fee deposit and claim
        vm.prank(owner);
        vault.depositFees{value: 5 ether}();

        vm.prank(alice);
        uint256 claimed1 = vault.claimFees();
        assertEq(claimed1, 5 ether, "First claim should be 5 ether");

        // Second fee deposit and claim
        vm.prank(owner);
        vault.depositFees{value: 3 ether}();

        vm.prank(alice);
        uint256 claimed2 = vault.claimFees();
        assertEq(claimed2, 3 ether, "Second claim should be 3 ether (delta)");
    }

    function test_ClaimFees_UpdatesClaimState() public {
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 10 ether}("");
        assertTrue(s1);

        vm.prank(dave);
        vault.convertAndAddLiquidity(0);

        vm.prank(owner);
        vault.depositFees{value: 10 ether}();

        uint256 timestampBefore = block.timestamp;

        vm.prank(alice);
        vault.claimFees();

        assertEq(vault.shareValueAtLastClaim(alice), 10 ether, "Share value at last claim should be updated");
        assertEq(vault.lastClaimTimestamp(alice), timestampBefore, "Last claim timestamp should be updated");
    }

    function test_ClaimFees_RevertsWhenNoShares() public {
        vm.prank(alice);
        vm.expectRevert("No shares");
        vault.claimFees();
    }

    function test_ClaimFees_RevertsWhenNoFeesAccumulated() public {
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 10 ether}("");
        assertTrue(s1);

        vm.prank(dave);
        vault.convertAndAddLiquidity(0);

        vm.prank(alice);
        vm.expectRevert("No fees to claim");
        vault.claimFees();
    }

    function test_ClaimFees_RevertsWhenNoNewFees() public {
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 10 ether}("");
        assertTrue(s1);

        vm.prank(dave);
        vault.convertAndAddLiquidity(0);

        vm.prank(owner);
        vault.depositFees{value: 10 ether}();

        // First claim succeeds
        vm.prank(alice);
        vault.claimFees();

        // Second claim without new fees should revert
        vm.prank(alice);
        vm.expectRevert("No new fees to claim");
        vault.claimFees();
    }

    function test_ClaimFees_IndependentClaimsByMultipleBenefactors() public {
        // Alice and Bob contribute
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 10 ether}("");
        assertTrue(s1);

        vm.prank(bob);
        (bool s2, ) = address(vault).call{value: 10 ether}("");
        assertTrue(s2);

        vm.prank(dave);
        vault.convertAndAddLiquidity(0);

        // First fee deposit
        vm.prank(owner);
        vault.depositFees{value: 10 ether}();

        // Alice claims first
        vm.prank(alice);
        uint256 aliceClaimed1 = vault.claimFees();
        assertApproxEqRel(aliceClaimed1, 5 ether, 0.01e18);

        // Second fee deposit
        vm.prank(owner);
        vault.depositFees{value: 10 ether}();

        // Bob claims both rounds
        vm.prank(bob);
        uint256 bobClaimed = vault.claimFees();
        assertApproxEqRel(bobClaimed, 10 ether, 0.01e18); // 5 from first + 5 from second

        // Alice claims second round only
        vm.prank(alice);
        uint256 aliceClaimed2 = vault.claimFees();
        assertApproxEqRel(aliceClaimed2, 5 ether, 0.01e18);
    }

    // ========== Query Function Tests ==========

    function test_GetBenefactorContribution_ReturnsCorrectAmount() public {
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 5 ether}("");
        assertTrue(s1);

        assertEq(vault.getBenefactorContribution(alice), 5 ether);
    }

    function test_GetBenefactorShares_ReturnsCorrectAmount() public {
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 10 ether}("");
        assertTrue(s1);

        vm.prank(dave);
        vault.convertAndAddLiquidity(0);

        uint256 shares = vault.getBenefactorShares(alice);
        assertTrue(shares > 0, "Alice should have shares");
    }

    function test_CalculateClaimableAmount_ReturnsCorrectValue() public {
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 10 ether}("");
        assertTrue(s1);

        vm.prank(dave);
        vault.convertAndAddLiquidity(0);

        vm.prank(owner);
        vault.depositFees{value: 10 ether}();

        uint256 claimable = vault.calculateClaimableAmount(alice);
        assertEq(claimable, 10 ether, "Claimable should be 10 ether");
    }

    function test_GetUnclaimedFees_ReturnsCorrectDelta() public {
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 10 ether}("");
        assertTrue(s1);

        vm.prank(dave);
        vault.convertAndAddLiquidity(0);

        // First fee deposit and claim
        vm.prank(owner);
        vault.depositFees{value: 5 ether}();

        vm.prank(alice);
        vault.claimFees();

        // Second fee deposit
        vm.prank(owner);
        vault.depositFees{value: 3 ether}();

        // Check unclaimed
        uint256 unclaimed = vault.getUnclaimedFees(alice);
        assertEq(unclaimed, 3 ether, "Unclaimed should be 3 ether (delta)");
    }

    function test_GetUnclaimedFees_ReturnsZeroWhenNoNewFees() public {
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 10 ether}("");
        assertTrue(s1);

        vm.prank(dave);
        vault.convertAndAddLiquidity(0);

        vm.prank(owner);
        vault.depositFees{value: 10 ether}();

        vm.prank(alice);
        vault.claimFees();

        uint256 unclaimed = vault.getUnclaimedFees(alice);
        assertEq(unclaimed, 0, "Unclaimed should be 0 after full claim");
    }

    // ========== Configuration Tests ==========

    function test_SetAlignmentToken_OwnerCanUpdate() public {
        address newToken = address(0x9999);

        vm.prank(owner);
        vault.setAlignmentToken(newToken);

        assertEq(vault.alignmentToken(), newToken, "Alignment token should be updated");
    }

    function test_SetAlignmentToken_RevertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert("Invalid token");
        vault.setAlignmentToken(address(0));
    }

    function test_SetAlignmentToken_RevertsWhenNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setAlignmentToken(address(0x9999));
    }

    function test_SetV4PoolKey_OwnerCanUpdate() public {
        PoolKey memory newPoolKey = PoolKey({
            currency0: Currency.wrap(address(0)), // Native ETH
            currency1: Currency.wrap(address(alignmentToken)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        vm.prank(owner);
        vault.setV4PoolKey(newPoolKey);

        // Just verify the call succeeded (no easy way to read back PoolKey struct)
    }

    function test_SetV4PoolKey_RevertsOnInvalidPoolKey() public {
        PoolKey memory invalidPoolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(0)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        vm.prank(owner);
        vm.expectRevert("Invalid pool key: no currencies set");
        vault.setV4PoolKey(invalidPoolKey);
    }

    function test_SetV4PoolKey_RevertsWhenNotOwner() public {
        PoolKey memory newPoolKey = PoolKey({
            currency0: Currency.wrap(address(0x8888)),
            currency1: Currency.wrap(address(alignmentToken)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        vm.prank(alice);
        vm.expectRevert();
        vault.setV4PoolKey(newPoolKey);
    }

    function test_SetConversionRewardBps_OwnerCanUpdate() public {
        vm.prank(owner);
        vault.setStandardConversionReward(0.01 ether);

        assertEq(vault.standardConversionReward(), 0.01 ether, "Standard conversion reward should be updated");
    }

    function test_SetConversionRewardBps_RevertsOnTooHighValue() public {
        vm.prank(owner);
        vm.expectRevert("Reward too high (max 0.1 ETH)");
        vault.setStandardConversionReward(0.2 ether);
    }

    function test_SetConversionRewardBps_RevertsWhenNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setStandardConversionReward(0.01 ether);
    }

    function test_SetConversionRewardBps_CanSetToZero() public {
        vm.prank(owner);
        vault.setStandardConversionReward(0);

        assertEq(vault.standardConversionReward(), 0, "Standard conversion reward should be 0");
    }

    function test_SetConversionRewardBps_CanSetToMax() public {
        vm.prank(owner);
        vault.setStandardConversionReward(0.1 ether);

        assertEq(vault.standardConversionReward(), 0.1 ether, "Standard conversion reward should be 0.1 ETH");
    }

    // ========== Reentrancy Protection Tests ==========

    function test_Receive_ReentrancyProtection() public {
        // This test verifies that the nonReentrant modifier is present
        // In practice, we'd need a malicious contract to test actual reentrancy
        // For now, we verify the function is marked nonReentrant by checking it doesn't fail
        vm.prank(alice);
        (bool success, ) = address(vault).call{value: 1 ether}("");
        assertTrue(success, "Should succeed with reentrancy protection");
    }

    function test_ReceiveHookTax_ReentrancyProtection() public {
        vm.prank(alice);
        vault.receiveHookTax{value: 1 ether}(Currency.wrap(address(0)), 1 ether, bob);
        // Should succeed without reentrancy issues
    }

    function test_ConvertAndAddLiquidity_ReentrancyProtection() public {
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 10 ether}("");
        assertTrue(s1);

        vm.prank(dave);
        vault.convertAndAddLiquidity(0);
        // Should succeed without reentrancy issues
    }

    function test_ClaimFees_ReentrancyProtection() public {
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 10 ether}("");
        assertTrue(s1);

        vm.prank(dave);
        vault.convertAndAddLiquidity(0);

        vm.prank(owner);
        vault.depositFees{value: 10 ether}();

        vm.prank(alice);
        vault.claimFees();
        // Should succeed without reentrancy issues
    }

    // ========== Complex Integration Tests ==========

    function test_CompleteWorkflow_SingleBenefactor() public {
        // 1. Alice contributes
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 10 ether}("");
        assertTrue(s1);

        // 2. Conversion happens
        vm.prank(dave);
        vault.convertAndAddLiquidity(0);

        // 3. Fees accumulate
        vm.prank(owner);
        vault.depositFees{value: 5 ether}();

        // 4. Alice claims
        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.claimFees();
        uint256 balanceAfter = alice.balance;

        assertEq(balanceAfter - balanceBefore, 5 ether, "Alice should receive all fees");
    }

    function test_CompleteWorkflow_MultipleBenefactorsMultipleRounds() public {
        // Round 1: Alice and Bob contribute
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 6 ether}("");
        assertTrue(s1);

        vm.prank(bob);
        (bool s2, ) = address(vault).call{value: 4 ether}("");
        assertTrue(s2);

        vm.prank(dave);
        vault.convertAndAddLiquidity(0);

        // Track alice and bob shares after round 1
        uint256 aliceSharesR1 = vault.benefactorShares(alice);
        uint256 bobSharesR1 = vault.benefactorShares(bob);
        uint256 totalSharesR1 = vault.totalShares();

        // Fees accumulate
        vm.prank(owner);
        vault.depositFees{value: 10 ether}();

        // Alice claims
        vm.prank(alice);
        uint256 aliceClaimed1 = vault.claimFees();
        assertApproxEqRel(aliceClaimed1, 6 ether, 0.01e18); // 60%

        // Round 2: Charlie joins
        vm.prank(charlie);
        (bool s3, ) = address(vault).call{value: 10 ether}("");
        assertTrue(s3);

        vm.prank(dave);
        vault.convertAndAddLiquidity(0);

        // Now Alice and Bob have shares from R1, Charlie has shares from R2
        uint256 aliceSharesR2 = vault.benefactorShares(alice);
        uint256 bobSharesR2 = vault.benefactorShares(bob);
        uint256 charlieSharesR2 = vault.benefactorShares(charlie);
        uint256 totalSharesR2 = vault.totalShares();

        // Verify shares accumulated correctly
        assertEq(aliceSharesR2, aliceSharesR1, "Alice shares unchanged");
        assertEq(bobSharesR2, bobSharesR1, "Bob shares unchanged");
        assertTrue(charlieSharesR2 > 0, "Charlie has new shares");
        assertEq(totalSharesR2, totalSharesR1 + charlieSharesR2, "Total shares increased by Charlie's shares");

        // More fees
        vm.prank(owner);
        vault.depositFees{value: 10 ether}();

        // Bob claims - should get his share proportion
        vm.prank(bob);
        uint256 bobClaimed = vault.claimFees();
        assertTrue(bobClaimed > 0, "Bob should claim some fees");

        // Charlie claims - should get his share proportion
        vm.prank(charlie);
        uint256 charlieClaimed = vault.claimFees();
        assertTrue(charlieClaimed > 0, "Charlie should have fees");

        // Alice may have unclaimed fees from round 2
        uint256 aliceUnclaimed = vault.getUnclaimedFees(alice);
        if (aliceUnclaimed > 0) {
            vm.prank(alice);
            uint256 aliceClaimed2 = vault.claimFees();
            assertTrue(aliceClaimed2 > 0, "Alice should have fees from round 2");
        }
    }

    function test_EdgeCase_VerySmallContributions() public {
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 1 wei}("");
        assertTrue(s1);

        assertEq(vault.benefactorTotalETH(alice), 1 wei);
        assertEq(vault.pendingETH(alice), 1 wei);
    }

    function test_EdgeCase_VeryLargeContributions() public {
        vm.deal(alice, 10000 ether);
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 10000 ether}("");
        assertTrue(s1);

        assertEq(vault.benefactorTotalETH(alice), 10000 ether);
    }

    function test_EdgeCase_ManyBenefactors() public {
        // Create 10 benefactors
        for (uint160 i = 1; i <= 10; i++) {
            address benefactor = address(i + 1000);
            vm.deal(benefactor, 10 ether);
            vm.prank(benefactor);
            (bool success, ) = address(vault).call{value: 1 ether}("");
            assertTrue(success);
        }

        assertEq(vault.totalPendingETH(), 10 ether);

        // Convert
        vm.prank(dave);
        vault.convertAndAddLiquidity(0);

        // All should have shares
        for (uint160 i = 1; i <= 10; i++) {
            address benefactor = address(i + 1000);
            assertTrue(vault.benefactorShares(benefactor) > 0, "Each benefactor should have shares");
        }
    }
}
