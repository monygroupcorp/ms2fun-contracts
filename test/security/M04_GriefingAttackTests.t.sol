// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/vaults/UltraAlignmentVault.sol";
import "../../src/master/MasterRegistryV1.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import "../mocks/MockEXECToken.sol";

// ============ Griefing Attack Contracts ============

/**
 * @notice Malicious contract that always reverts on ETH receipt
 * @dev This is the griefing attack vector - revert to block operation
 */
contract GrieferAlwaysReverts {
    UltraAlignmentVault public vault;

    constructor(UltraAlignmentVault _vault) {
        vault = _vault;
    }

    function attemptConversion(uint256 minOut) external {
        // This will execute all the conversion work
        vault.convertAndAddLiquidity(minOut);
        // But our receive() will revert when reward is sent
    }

    receive() external payable {
        revert("Griefing attack: reject reward to block operation");
    }
}

/**
 * @notice Contract that conditionally reverts (griefs only sometimes)
 */
contract GrieferConditional {
    UltraAlignmentVault public vault;
    bool public shouldGrief;

    constructor(UltraAlignmentVault _vault) {
        vault = _vault;
    }

    function setGriefing(bool _grief) external {
        shouldGrief = _grief;
    }

    function attemptConversion(uint256 minOut) external {
        vault.convertAndAddLiquidity(minOut);
    }

    receive() external payable {
        if (shouldGrief) {
            revert("Conditional griefing attack");
        }
        // Otherwise accept payment
    }
}

/**
 * @notice Contract that runs out of gas when receiving (accidental griefing)
 */
contract GrieferOutOfGas {
    UltraAlignmentVault public vault;

    constructor(UltraAlignmentVault _vault) {
        vault = _vault;
    }

    function attemptConversion(uint256 minOut) external {
        vault.convertAndAddLiquidity(minOut);
    }

    receive() external payable {
        // Infinite loop consumes all gas
        while (true) {}
    }
}

/**
 * @notice Good caller contract that accepts payments
 */
contract GoodCaller {
    UltraAlignmentVault public vault;

    constructor(UltraAlignmentVault _vault) {
        vault = _vault;
    }

    function callConversion(uint256 minOut) external {
        vault.convertAndAddLiquidity(minOut);
    }

    receive() external payable {
        // Accept payment
    }
}

// ============ Main Test Contract ============

/**
 * @title M04_GriefingAttackTests
 * @notice Tests demonstrating M-04 security fix prevents griefing attacks
 * @dev Tests prove that malicious contracts cannot block incentivized functions
 *      by rejecting reward payments (pre-fix vulnerability)
 */
contract M04_GriefingAttackTests is Test {
    UltraAlignmentVault public vault;
    MockEXECToken public alignmentToken;

    address public owner;
    address public alice;
    address public mockPoolManager;
    address public mockV3Router;
    address public mockV2Router;
    address public mockV2Factory;
    address public mockV3Factory;
    address public mockWeth;

    // Events to test
    event ConversionRewardPaid(address indexed caller, uint256 totalReward, uint256 gasCost, uint256 standardReward);
    event ConversionRewardRejected(address indexed caller, uint256 rewardAmount);
    event InsufficientRewardBalance(address indexed caller, uint256 rewardAmount, uint256 contractBalance);

    function setUp() public {
        owner = address(this);
        alice = makeAddr("alice");

        // Deploy mock addresses (as EOAs - no code)
        mockPoolManager = makeAddr("poolManager");
        mockV3Router = makeAddr("v3Router");
        mockV2Router = makeAddr("v2Router");
        mockV2Factory = makeAddr("v2Factory");
        mockV3Factory = makeAddr("v3Factory");
        mockWeth = makeAddr("weth");

        // Leave mocks as EOAs (no code) - vault has test stubs that check code.length == 0
        // This allows vault to skip pool queries and use default behavior for testing

        // Deploy real ERC20 token for alignment token
        alignmentToken = new MockEXECToken(1000000e18);

        // Deploy vault
        vault = new UltraAlignmentVault(
            mockWeth,
            mockPoolManager,
            mockV3Router,
            mockV2Router,
            mockV2Factory,
            mockV3Factory,
            address(alignmentToken)
        );

        // Set V4 pool key for conversion tests
        PoolKey memory mockPoolKey = PoolKey({
            currency0: Currency.wrap(address(0)), // Native ETH
            currency1: Currency.wrap(address(alignmentToken)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        vault.setV4PoolKey(mockPoolKey);

        // Fund vault for rewards
        vm.deal(address(vault), 100 ether);
    }

    // ============ Test: Griefing Attack Blocked ============

    function test_GriefingAttack_AlwaysReverts_OperationSucceeds() public {
        // Setup: Add pending ETH to vault (from alice)
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        (bool success, ) = address(vault).call{value: 5 ether}("");
        assertTrue(success, "Alice contribution failed");

        // Deploy griefing contract
        GrieferAlwaysReverts griefer = new GrieferAlwaysReverts(vault);

        // Record state before attack
        uint256 pendingBefore = vault.totalPendingETH();
        assertEq(pendingBefore, 5 ether, "Should have pending ETH");

        // Attack: Griefer tries to block conversion by rejecting reward
        // ✅ KEY TEST: This should NOT revert (pre-fix it would have reverted)
        griefer.attemptConversion(0);

        // ✅ VERIFY: Operation succeeded despite griefing attempt
        uint256 pendingAfter = vault.totalPendingETH();
        assertEq(pendingAfter, 0, "Conversion should succeed - pending ETH cleared");

        // ✅ VERIFY: Shares were issued (conversion completed)
        uint256 aliceShares = vault.benefactorShares(alice);
        assertGt(aliceShares, 0, "Alice should have shares - conversion completed");

        // ✅ VERIFY: Griefer got no reward (rejected payment)
        assertEq(address(griefer).balance, 0, "Griefer should have no reward");
    }

    function test_GriefingAttack_ConditionalRevert_OperationSucceeds() public {
        // Setup
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        (bool success, ) = address(vault).call{value: 3 ether}("");
        assertTrue(success);

        GrieferConditional griefer = new GrieferConditional(vault);

        // Enable griefing mode
        griefer.setGriefing(true);

        // Attack should fail to block operation
        griefer.attemptConversion(0);

        // Verify conversion completed
        assertEq(vault.totalPendingETH(), 0, "Conversion completed despite griefing");
        assertGt(vault.benefactorShares(alice), 0, "Shares issued");
    }

    function test_GriefingAttack_OutOfGas_OperationSucceeds() public {
        // Setup
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        (bool success, ) = address(vault).call{value: 2 ether}("");
        assertTrue(success);

        GrieferOutOfGas griefer = new GrieferOutOfGas(vault);

        // Attack: Out of gas on receive (accidental griefing)
        griefer.attemptConversion(0);

        // Verify operation succeeded
        assertEq(vault.totalPendingETH(), 0, "Conversion completed");
    }

    // ============ Test: Legitimate Callers Get Paid ============

    function test_LegitimateEOA_ReceivesReward() public {
        // Setup
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 5 ether}("");
        assertTrue(s1);

        address caller = makeAddr("caller");
        vm.deal(caller, 1 ether);

        // Record balance before
        uint256 balanceBefore = caller.balance;

        // Legitimate call - should receive reward
        vm.prank(caller);
        vault.convertAndAddLiquidity(0);

        // Verify caller received reward
        uint256 balanceAfter = caller.balance;
        assertGt(balanceAfter, balanceBefore, "Caller should receive reward");

        // Verify reward is reasonable (gas cost + standard reward)
        // Note: In test environment with low/zero gas price, reward may equal exactly standard reward
        uint256 rewardReceived = balanceAfter - balanceBefore;
        assertGe(rewardReceived, 0.0012 ether, "Should receive at least standard reward");
        assertLt(rewardReceived, 0.01 ether, "Reward should be reasonable");
    }

    function test_LegitimateContract_ReceivesReward() public {
        // Setup
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 5 ether}("");
        assertTrue(s1);

        // Deploy contract that accepts payment
        GoodCaller goodCaller = new GoodCaller(vault);

        // Record balance
        uint256 balanceBefore = address(goodCaller).balance;

        // Legitimate call
        goodCaller.callConversion(0);

        // Verify reward received
        assertGt(address(goodCaller).balance, balanceBefore, "Good caller should receive reward");
    }

    // ============ Test: Insufficient Balance Handling ============

    function test_InsufficientBalance_OperationStillSucceeds() public {
        // Setup vault with NO ETH for rewards
        UltraAlignmentVault poorVault = new UltraAlignmentVault(
            mockWeth,
            mockPoolManager,
            mockV3Router,
            mockV2Router,
            mockV2Factory,
            mockV3Factory,
            address(alignmentToken)
        );

        // Set V4 pool key
        PoolKey memory mockPoolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(alignmentToken)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        poorVault.setV4PoolKey(mockPoolKey);

        // Add pending ETH (but no extra for rewards)
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        (bool s1, ) = address(poorVault).call{value: 5 ether}("");
        assertTrue(s1);

        // Drain vault balance to simulate insufficient reward funds
        // Note: With mock addresses, test stubs don't consume ETH during swap/LP operations
        // So we manually drain the vault to test insufficient balance scenario
        vm.deal(address(poorVault), 0);

        address caller = makeAddr("poorCaller");

        // Call should succeed even though reward can't be paid
        vm.prank(caller);
        poorVault.convertAndAddLiquidity(0);

        // Verify operation completed
        assertEq(poorVault.totalPendingETH(), 0, "Conversion completed");
        assertGt(poorVault.benefactorShares(alice), 0, "Shares issued");

        // Caller got no reward (insufficient balance)
        assertEq(caller.balance, 0, "No reward paid due to insufficient balance");
    }

    // ============ Test: Reward Calculation Accuracy ============

    function test_RewardCalculation_ScalesWithBenefactors() public {
        // Add contributions from multiple benefactors
        address bob = makeAddr("bob");
        address charlie = makeAddr("charlie");

        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.deal(charlie, 10 ether);

        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 3 ether}("");
        assertTrue(s1);

        vm.prank(bob);
        (bool s2, ) = address(vault).call{value: 2 ether}("");
        assertTrue(s2);

        vm.prank(charlie);
        (bool s3, ) = address(vault).call{value: 1 ether}("");
        assertTrue(s3);

        // Now 3 benefactors, reward should be:
        // (100k + 3*15k) * gasPrice + 0.0012 ether
        // = 145k * gasPrice + 0.0012 ether

        address caller = makeAddr("rewardTester");
        vm.deal(caller, 1 ether);

        uint256 balanceBefore = caller.balance;

        // Set gas price to test reward scaling with work
        vm.txGasPrice(1 gwei);
        vm.prank(caller);
        vault.convertAndAddLiquidity(0);

        uint256 balanceAfter = caller.balance;
        uint256 rewardReceived = balanceAfter - balanceBefore;

        // Verify reward includes standard amount
        // Note: In test environment with low/zero gas price, reward may equal exactly standard reward
        assertGe(rewardReceived, 0.0012 ether, "Should include standard reward");

        // Verify reward scales with benefactor count (includes gas cost)
        // At minimum gas price (1 gwei), gas cost = 145k * 1 gwei = 0.000145 ether
        // Total = 0.000145 + 0.0012 = 0.001345 ether exactly
        assertGe(rewardReceived, 0.001345 ether, "Reward should scale with work");
    }

    // ============ Test: Admin Controls ============

    function test_AdminCanUpdateStandardReward() public {
        uint256 newReward = 0.002 ether;

        vault.setStandardConversionReward(newReward);

        assertEq(vault.standardConversionReward(), newReward, "Standard reward updated");
    }

    function test_AdminCannotSetExcessiveReward() public {
        vm.expectRevert("Reward too high (max 0.1 ETH)");
        vault.setStandardConversionReward(0.2 ether);
    }

    function test_NonAdminCannotUpdateReward() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setStandardConversionReward(0.002 ether);
    }
}
