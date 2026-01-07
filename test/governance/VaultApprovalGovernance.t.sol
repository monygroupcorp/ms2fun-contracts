// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {VaultApprovalGovernance} from "../../src/governance/VaultApprovalGovernance.sol";
import {MasterRegistryV1} from "../../src/master/MasterRegistryV1.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockVault} from "../mocks/MockVault.sol";

/**
 * @title VaultApprovalGovernanceTest
 * @notice Comprehensive test suite for vault approval governance system
 * @dev Tests the full lifecycle: application → voting → challenges → registration
 */
contract VaultApprovalGovernanceTest is Test {
    // Contracts
    VaultApprovalGovernance public governance;
    MasterRegistryV1 public registry;
    MockERC20 public execToken;
    MockVault public testVault;

    // Test accounts
    address public owner = makeAddr("owner");
    address public applicant = makeAddr("applicant");
    address public voter1 = makeAddr("voter1");
    address public voter2 = makeAddr("voter2");
    address public voter3 = makeAddr("voter3");
    address public challenger = makeAddr("challenger");

    // Constants (matching governance)
    uint256 constant MIN_DEPOSIT = 100 ether;
    uint256 constant APPLICATION_FEE = 0.1 ether;
    uint256 constant INITIAL_VOTING_PERIOD = 7 days;
    uint256 constant CHALLENGE_WINDOW = 7 days;
    uint256 constant CHALLENGE_VOTING_PERIOD = 7 days;
    uint256 constant LAME_DUCK_PERIOD = 3 days;

    // Events
    event ApplicationSubmitted(
        address indexed vaultAddress,
        address indexed applicant,
        string vaultType,
        uint256 applicationFee
    );
    event VoteDeposited(
        address indexed vaultAddress,
        address indexed voter,
        bool supportsApproval,
        uint256 amount,
        uint256 roundIndex
    );
    event ApplicationChallenged(
        address indexed vaultAddress,
        address indexed challenger,
        uint256 roundIndex,
        uint256 challengeDeposit
    );
    event ApplicationApproved(address indexed vaultAddress);
    event ApplicationRejected(address indexed vaultAddress);
    event ApplicationRegistered(address indexed vaultAddress, address indexed registrar);

    function setUp() public {
        // Deploy EXEC token
        execToken = new MockERC20("EXEC Token", "EXEC");

        // Deploy registry
        vm.startPrank(owner);
        registry = new MasterRegistryV1();
        registry.initialize(address(execToken), owner);
        vm.stopPrank();

        // Get governance module address (auto-deployed by registry)
        governance = VaultApprovalGovernance(registry.vaultGovernanceModule());

        // Deploy test vault
        testVault = new MockVault();

        // Mint EXEC tokens to test accounts
        execToken.mint(applicant, 10000 ether);
        execToken.mint(voter1, 10000 ether);
        execToken.mint(voter2, 10000 ether);
        execToken.mint(voter3, 10000 ether);
        execToken.mint(challenger, 10000 ether);

        // Approve governance to spend EXEC
        vm.prank(applicant);
        execToken.approve(address(governance), type(uint256).max);
        vm.prank(voter1);
        execToken.approve(address(governance), type(uint256).max);
        vm.prank(voter2);
        execToken.approve(address(governance), type(uint256).max);
        vm.prank(voter3);
        execToken.approve(address(governance), type(uint256).max);
        vm.prank(challenger);
        execToken.approve(address(governance), type(uint256).max);

        // Fund applicant with ETH for application fee
        vm.deal(applicant, 10 ether);
    }

    // ========== Application Submission Tests ==========

    function test_SubmitApplication_Success() public {
        bytes32[] memory features = new bytes32[](2);
        features[0] = bytes32("full-range-lp");
        features[1] = bytes32("auto-compound");

        // Submit application (event check removed due to global messaging integration)
        vm.prank(applicant);
        governance.submitApplication{value: APPLICATION_FEE}(
            address(testVault),
            "MockVault",
            "Test Vault",
            "Test Vault for Testing",
            "ipfs://Qm...",
            features,
            ""
        );

        // Verify application state
        (
            address returnedApplicant,
            string memory vaultType,
            string memory title,
            VaultApprovalGovernance.ApplicationPhase phase,
            uint256 phaseDeadline,
            uint256 cumulativeYayRequired,
            uint256 roundCount
        ) = governance.getApplication(address(testVault));

        assertEq(returnedApplicant, applicant);
        assertEq(vaultType, "MockVault");
        assertEq(title, "Test Vault");
        assertTrue(phase == VaultApprovalGovernance.ApplicationPhase.InitialVoting);
        assertGt(phaseDeadline, block.timestamp);
        assertEq(cumulativeYayRequired, 0);
        assertEq(roundCount, 1);
    }

    function test_SubmitApplication_InsufficientFee() public {
        bytes32[] memory features = new bytes32[](0);

        vm.prank(applicant);
        vm.expectRevert("Insufficient application fee");
        governance.submitApplication{value: 0.05 ether}(
            address(testVault),
            "MockVault",
            "Test Vault",
            "Test Vault for Testing",
            "ipfs://Qm...",
            features,
            ""
        );
    }

    function test_SubmitApplication_DuplicateVault() public {
        bytes32[] memory features = new bytes32[](0);

        // Submit first application
        vm.prank(applicant);
        governance.submitApplication{value: APPLICATION_FEE}(
            address(testVault),
            "MockVault",
            "Test Vault",
            "Test Vault for Testing",
            "ipfs://Qm...",
            features,
            ""
        );

        // Try to submit duplicate
        vm.prank(applicant);
        vm.expectRevert("Application already exists");
        governance.submitApplication{value: APPLICATION_FEE}(
            address(testVault),
            "MockVault",
            "Test Vault",
            "Test Vault for Testing",
            "ipfs://Qm...",
            features,
            ""
        );
    }

    // ========== Voting Tests ==========

    function test_VoteYay_Success() public {
        _submitApplication();

        // Vote (event check removed due to global messaging integration)
        vm.prank(voter1);
        governance.voteWithDeposit(address(testVault), true, 500 ether, "Supporting this vault!");

        // Verify vote was recorded
        VaultApprovalGovernance.VoteRound memory round = governance.getRound(address(testVault), 0);
        assertEq(round.yayDeposits, 500 ether);
        assertEq(round.nayDeposits, 0);
    }

    function test_VoteNay_Success() public {
        _submitApplication();

        vm.prank(voter1);
        governance.voteWithDeposit(address(testVault), false, 500 ether, "Too risky");

        // Verify vote was recorded
        VaultApprovalGovernance.VoteRound memory round = governance.getRound(address(testVault), 0);
        assertEq(round.yayDeposits, 0);
        assertEq(round.nayDeposits, 500 ether);
    }

    function test_Vote_BelowMinDeposit() public {
        _submitApplication();

        vm.prank(voter1);
        vm.expectRevert("Below minimum deposit");
        governance.voteWithDeposit(address(testVault), true, 1000, ""); // Below MIN_DEPOSIT (1_000_000)
    }

    function test_Vote_AfterDeadline() public {
        _submitApplication();

        // Fast forward past deadline
        vm.warp(block.timestamp + INITIAL_VOTING_PERIOD + 1);

        vm.prank(voter1);
        vm.expectRevert("Voting period ended");
        governance.voteWithDeposit(address(testVault), true, 500 ether, "");
    }

    function test_Vote_CannotSwitchSides() public {
        _submitApplication();

        // Vote yay
        vm.prank(voter1);
        governance.voteWithDeposit(address(testVault), true, 500 ether, "");

        // Try to vote nay (should fail)
        vm.prank(voter1);
        vm.expectRevert("Cannot vote for opposite side");
        governance.voteWithDeposit(address(testVault), false, 500 ether, "");
    }

    function test_Vote_CanAddToSameSide() public {
        _submitApplication();

        // Vote yay
        vm.prank(voter1);
        governance.voteWithDeposit(address(testVault), true, 500 ether, "");

        // Add more yay votes
        vm.prank(voter1);
        governance.voteWithDeposit(address(testVault), true, 300 ether, "");

        // Verify total
        VaultApprovalGovernance.VoteRound memory round = governance.getRound(address(testVault), 0);
        assertEq(round.yayDeposits, 800 ether);
    }

    // ========== Phase Transition Tests ==========

    function test_FinalizeInitialVoting_Approved() public {
        _submitApplication();

        // Vote overwhelmingly yay
        vm.prank(voter1);
        governance.voteWithDeposit(address(testVault), true, 1000 ether, "");
        vm.prank(voter2);
        governance.voteWithDeposit(address(testVault), true, 1000 ether, "");

        // Fast forward past voting period
        vm.warp(block.timestamp + INITIAL_VOTING_PERIOD + 1);

        // Finalize
        governance.finalizeRound(address(testVault));

        // Should be in challenge window with deadline 7 days from finalization
        (, , , VaultApprovalGovernance.ApplicationPhase phase, uint256 deadline, ,) = governance.getApplication(address(testVault));

        assertTrue(phase == VaultApprovalGovernance.ApplicationPhase.ChallengeWindow);
        // Deadline should be approximately current time + CHALLENGE_WINDOW
        assertGt(deadline, block.timestamp);
        assertLt(deadline, block.timestamp + CHALLENGE_WINDOW + 2); // Allow 1 second tolerance
    }

    function test_FinalizeInitialVoting_Rejected() public {
        _submitApplication();

        // Vote overwhelmingly nay
        vm.prank(voter1);
        governance.voteWithDeposit(address(testVault), false, 1000 ether, "");
        vm.prank(voter2);
        governance.voteWithDeposit(address(testVault), false, 1000 ether, "");

        // Fast forward past voting period
        vm.warp(block.timestamp + INITIAL_VOTING_PERIOD + 1);

        // Finalize (event check removed due to global messaging integration)
        governance.finalizeRound(address(testVault));

        // Should be rejected
        (, , , VaultApprovalGovernance.ApplicationPhase phase, , ,) = governance.getApplication(address(testVault));
        assertTrue(phase == VaultApprovalGovernance.ApplicationPhase.Rejected);
    }

    function test_FinalizeInitialVoting_TooEarly() public {
        _submitApplication();

        vm.prank(voter1);
        governance.voteWithDeposit(address(testVault), true, 1000 ether, "");

        // Try to finalize before deadline
        vm.expectRevert("Voting period not ended");
        governance.finalizeRound(address(testVault));
    }

    // ========== Challenge Tests ==========

    function test_Challenge_Success() public {
        _submitApplication();
        _approveInitialVoting();

        // Get required challenge deposit
        (, , , , , uint256 cumulativeYay, ) = governance.getApplication(address(testVault));

        // Challenge - event check removed due to global messaging integration
        vm.prank(challenger);
        governance.initiateChallenge(address(testVault), cumulativeYay, "Security concerns");

        // Should be in challenge voting
        (, , , VaultApprovalGovernance.ApplicationPhase phase, , ,) = governance.getApplication(address(testVault));
        assertTrue(phase == VaultApprovalGovernance.ApplicationPhase.ChallengeVoting);
    }

    function test_Challenge_OutsideChallengeWindow() public {
        _submitApplication();
        _approveInitialVoting();

        // Get required challenge deposit
        (, , , , , uint256 cumulativeYay, ) = governance.getApplication(address(testVault));

        // Fast forward past challenge window
        vm.warp(block.timestamp + CHALLENGE_WINDOW + 1);

        vm.prank(challenger);
        vm.expectRevert("Challenge period ended");
        governance.initiateChallenge(address(testVault), cumulativeYay, "Too late");
    }

    function test_Challenge_InsufficientDeposit() public {
        _submitApplication();
        _approveInitialVoting();

        // Try to challenge with less than MIN_DEPOSIT
        vm.prank(challenger);

        // First, reduce challenger's balance
        vm.store(
            address(execToken),
            keccak256(abi.encode(challenger, 0)), // Assuming balance is in slot 0
            bytes32(uint256(50 ether))
        );

        vm.expectRevert();
        governance.initiateChallenge(address(testVault), 50 ether, "Not enough");
    }

    // ========== Challenge Voting Tests ==========

    function test_ChallengeVoting_DefeatChallenge() public {
        _submitApplication();
        _approveInitialVoting();
        _submitChallenge();

        // Vote to defeat challenge (yay = keep vault)
        vm.prank(voter1);
        governance.voteWithDeposit(address(testVault), true, 2000 ether, "Challenge is wrong");
        vm.prank(voter2);
        governance.voteWithDeposit(address(testVault), true, 2000 ether, "Vault is good");

        // Fast forward past challenge voting
        vm.warp(block.timestamp + CHALLENGE_VOTING_PERIOD + 1);

        // Finalize challenge
        governance.finalizeRound(address(testVault));

        // Should be back in challenge window for more challenges
        (, , , VaultApprovalGovernance.ApplicationPhase phase, , ,) = governance.getApplication(address(testVault));
        assertTrue(phase == VaultApprovalGovernance.ApplicationPhase.ChallengeWindow);
    }

    function test_ChallengeVoting_SuccessfulChallenge() public {
        _submitApplication();
        _approveInitialVoting();
        _submitChallenge();

        // Vote to uphold challenge (nay = reject vault)
        vm.prank(voter1);
        governance.voteWithDeposit(address(testVault), false, 3000 ether, "Challenge is valid");
        vm.prank(voter2);
        governance.voteWithDeposit(address(testVault), false, 3000 ether, "Vault should be rejected");

        // Fast forward past challenge voting
        vm.warp(block.timestamp + CHALLENGE_VOTING_PERIOD + 1);

        // Finalize challenge (event check removed due to global messaging integration)
        governance.finalizeRound(address(testVault));

        // Should be rejected
        (, , , VaultApprovalGovernance.ApplicationPhase phase, , ,) = governance.getApplication(address(testVault));
        assertTrue(phase == VaultApprovalGovernance.ApplicationPhase.Rejected);
    }

    // ========== Lame Duck Tests ==========

    function test_MoveToLameDuck_AfterChallengeWindow() public {
        _submitApplication();
        _approveInitialVoting();

        // No challenges, fast forward past challenge window
        vm.warp(block.timestamp + CHALLENGE_WINDOW + 1);

        governance.enterLameDuck(address(testVault));

        // Should be in lame duck
        (, , , VaultApprovalGovernance.ApplicationPhase phase, uint256 deadline, ,) = governance.getApplication(address(testVault));
        assertTrue(phase == VaultApprovalGovernance.ApplicationPhase.LameDuck);
        assertEq(deadline, block.timestamp + LAME_DUCK_PERIOD);
    }

    function test_MoveToLameDuck_TooEarly() public {
        _submitApplication();
        _approveInitialVoting();

        // Try to move to lame duck before challenge window ends
        vm.expectRevert("Challenge window not ended");
        governance.enterLameDuck(address(testVault));
    }

    // ========== Registration Tests ==========

    function test_RegisterVault_AfterLameDuck() public {
        _submitApplication();
        _approveInitialVoting();
        _skipChallengeWindow();
        _waitForLameDuck();

        // Register vault
        vm.expectEmit(true, true, false, false);
        emit ApplicationRegistered(address(testVault), address(this));

        governance.registerVault(address(testVault));

        // Verify vault is registered in MasterRegistry
        assertTrue(registry.isVaultRegistered(address(testVault)));

        // Verify application is approved
        (, , , VaultApprovalGovernance.ApplicationPhase phase, , ,) = governance.getApplication(address(testVault));
        assertTrue(phase == VaultApprovalGovernance.ApplicationPhase.Approved);
    }

    function test_RegisterVault_DuringLameDuck() public {
        _submitApplication();
        _approveInitialVoting();
        _skipChallengeWindow();

        // Try to register during lame duck (not after)
        vm.expectRevert("Lame duck period not ended");
        governance.registerVault(address(testVault));
    }

    function test_RegisterVault_BeforeLameDuck() public {
        _submitApplication();
        _approveInitialVoting();

        // Try to register before lame duck even starts
        vm.expectRevert("Not in lame duck period");
        governance.registerVault(address(testVault));
    }

    // ========== Withdrawal Tests ==========

    function test_Withdraw_AfterApproval() public {
        _submitApplication();

        // Vote yay with enough to pass
        vm.prank(voter1);
        governance.voteWithDeposit(address(testVault), true, 1000 ether, "");
        vm.prank(voter2);
        governance.voteWithDeposit(address(testVault), true, 1000 ether, "");

        // Finalize initial voting
        vm.warp(block.timestamp + INITIAL_VOTING_PERIOD + 1);
        governance.finalizeRound(address(testVault));

        // Skip challenge window and lame duck
        _skipChallengeWindow();
        _waitForLameDuck();
        governance.registerVault(address(testVault));

        // Withdraw voter1's deposit
        uint256 balanceBefore = execToken.balanceOf(voter1);

        vm.prank(voter1);
        governance.withdrawDeposits(address(testVault));

        uint256 balanceAfter = execToken.balanceOf(voter1);
        assertEq(balanceAfter - balanceBefore, 1000 ether);
    }

    function test_Withdraw_AfterRejection() public {
        _submitApplication();

        // Vote nay
        vm.prank(voter1);
        governance.voteWithDeposit(address(testVault), false, 1000 ether, "");

        // Reject the vault
        vm.warp(block.timestamp + INITIAL_VOTING_PERIOD + 1);
        governance.finalizeRound(address(testVault));

        // Withdraw
        uint256 balanceBefore = execToken.balanceOf(voter1);

        vm.prank(voter1);
        governance.withdrawDeposits(address(testVault));

        uint256 balanceAfter = execToken.balanceOf(voter1);
        assertEq(balanceAfter - balanceBefore, 1000 ether);
    }

    function test_Withdraw_CannotWithdrawDuringVoting() public {
        _submitApplication();

        vm.prank(voter1);
        governance.voteWithDeposit(address(testVault), true, 1000 ether, "");

        // Try to withdraw during active voting
        vm.prank(voter1);
        vm.expectRevert("Application not resolved");
        governance.withdrawDeposits(address(testVault));
    }

    // ========== Helper Functions ==========

    function _submitApplication() internal {
        bytes32[] memory features = new bytes32[](2);
        features[0] = bytes32("full-range-lp");
        features[1] = bytes32("auto-compound");

        vm.prank(applicant);
        governance.submitApplication{value: APPLICATION_FEE}(
            address(testVault),
            "MockVault",
            "Test Vault",
            "Test Vault for Testing",
            "ipfs://QmTest123",
            features,
            "Initial submission"
        );
    }

    function _approveInitialVoting() internal {
        // Vote yay
        vm.prank(voter1);
        governance.voteWithDeposit(address(testVault), true, 1000 ether, "");
        vm.prank(voter2);
        governance.voteWithDeposit(address(testVault), true, 1000 ether, "");

        // Fast forward and finalize
        vm.warp(block.timestamp + INITIAL_VOTING_PERIOD + 1);
        governance.finalizeRound(address(testVault));
    }

    function _submitChallenge() internal {
        // Get the required challenge deposit (must match cumulativeYayRequired)
        (, , , , , uint256 cumulativeYay, ) = governance.getApplication(address(testVault));

        vm.prank(challenger);
        governance.initiateChallenge(address(testVault), cumulativeYay, "Security concerns");
    }

    function _skipChallengeWindow() internal {
        vm.warp(block.timestamp + CHALLENGE_WINDOW + 1);
        governance.enterLameDuck(address(testVault));
    }

    function _waitForLameDuck() internal {
        vm.warp(block.timestamp + LAME_DUCK_PERIOD + 1);
    }

    // ========== Edge Case Tests ==========

    function test_MultipleRounds_EscalatingDeposits() public {
        _submitApplication();
        _approveInitialVoting();

        // Get first challenge deposit requirement
        (, , , , , uint256 cumulativeYay1, ) = governance.getApplication(address(testVault));
        assertEq(cumulativeYay1, 2000 ether); // From initial voting

        // First challenge
        vm.prank(challenger);
        governance.initiateChallenge(address(testVault), cumulativeYay1, "Round 1");

        // Defeat first challenge
        vm.prank(voter1);
        governance.voteWithDeposit(address(testVault), true, 3000 ether, "");
        vm.warp(block.timestamp + CHALLENGE_VOTING_PERIOD + 1);
        governance.finalizeRound(address(testVault));

        // Get second challenge deposit requirement (should be cumulative)
        (, , , , , uint256 cumulativeYay2, uint256 roundCount1) = governance.getApplication(address(testVault));
        assertEq(roundCount1, 2); // Initial + first challenge
        assertEq(cumulativeYay2, 5000 ether); // 2000 + 3000

        // Second challenge requires higher deposit
        vm.prank(voter3);
        governance.initiateChallenge(address(testVault), cumulativeYay2, "Round 2");

        // Verify it's in challenge voting and round count increased
        (, , , VaultApprovalGovernance.ApplicationPhase phase, , , uint256 roundCount2) = governance.getApplication(address(testVault));
        assertTrue(phase == VaultApprovalGovernance.ApplicationPhase.ChallengeVoting);
        assertEq(roundCount2, 3); // Initial + 2 challenges
    }

    function test_ApplicationFee_Refunded() public {
        uint256 balanceBefore = applicant.balance;

        vm.prank(applicant);
        governance.submitApplication{value: 1 ether}(
            address(testVault),
            "MockVault",
            "Test",
            "Test",
            "ipfs://Qm...",
            new bytes32[](0),
            "Overpayment test"
        );

        uint256 balanceAfter = applicant.balance;

        // Should refund excess (1 ether - 0.1 ether = 0.9 ether refunded)
        assertEq(balanceBefore - balanceAfter, APPLICATION_FEE);
    }
}
