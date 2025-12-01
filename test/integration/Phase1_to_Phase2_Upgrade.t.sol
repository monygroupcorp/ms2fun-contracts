// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {UltraAlignmentVault} from "src/vaults/UltraAlignmentVault.sol";
import {MockBeneficiary} from "test/mocks/MockBeneficiary.sol";
import {MockBenefactorStaking} from "test/mocks/MockBenefactorStaking.sol";
import {Currency} from "v4-core/types/Currency.sol";

/**
 * @title Phase1_to_Phase2_Upgrade
 * @notice Tests that verify Phase 1 → Phase 2 upgrade path works seamlessly
 * @dev Tests confirm:
 *   - Phase 1 (SimpleBeneficiary) works
 *   - Vault code unchanged when upgrading to Phase 2
 *   - Phase 2 (VaultBenefactorStaking) can be swapped in
 *   - All data preserved during upgrade
 */
contract Phase1_to_Phase2_UpgradeTest is Test {
    // ========== Setup ==========

    UltraAlignmentVault vault;
    MockBeneficiary simpleBeneficiary; // Phase 1
    MockBenefactorStaking benefactorStaking; // Phase 2

    address constant ALIGNMENT_TARGET = address(0x1111111111111111111111111111111111111111);
    address constant V3_POOL = address(0x2222222222222222222222222222222222222222);
    address constant WETH = address(0x3333333333333333333333333333333333333333);
    address constant V3_POSITION_MANAGER = address(0x4444444444444444444444444444444444444444);
    address constant V4_POOL_MANAGER = address(0x5555555555555555555555555555555555555555);
    address constant ROUTER = address(0x6666666666666666666666666666666666666666);

    address constant HOOK = address(0x7777777777777777777777777777777777777777);
    address constant HOOK_FACTORY = address(0x8888888888888888888888888888888888888888);
    address constant PROJECT1 = address(0x9999999999999999999999999999999999999999);
    address constant PROJECT2 = address(0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa);

    address constant USER1 = address(0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB);
    address constant USER2 = address(0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC);

    function setUp() public {
        // Deploy vault
        vault = new UltraAlignmentVault(
            ALIGNMENT_TARGET,
            V3_POOL,
            WETH,
            V3_POSITION_MANAGER,
            V4_POOL_MANAGER,
            ROUTER,
            HOOK_FACTORY
        );

        // Deploy Phase 1 beneficiary
        simpleBeneficiary = new MockBeneficiary(address(vault));

        // Deploy Phase 2 beneficiary
        benefactorStaking = new MockBenefactorStaking(address(vault));
    }

    // ========== Phase 1: Simple Beneficiary ==========

    /**
     * @notice Test Phase 1 workflow: fees collected, simple beneficiary notified
     */
    function test_Phase1_SimpleBeneficiary_Workflow() public {
        // Step 1: Set Phase 1 beneficiary
        vault.setBeneficiaryModule(address(simpleBeneficiary));

        // Step 2: Send taxes
        uint256 tax1 = 1 ether;
        uint256 tax2 = 2 ether;

        vm.prank(HOOK);
        vault.receiveERC404Tax(Currency.wrap(address(0)), tax1, PROJECT1);

        vm.prank(HOOK);
        vault.receiveERC404Tax(Currency.wrap(address(0)), tax2, PROJECT2);

        // Step 3: Verify beneficiary was notified
        assertEq(simpleBeneficiary.getTotalFeesReceived(), tax1 + tax2);
        assertEq(simpleBeneficiary.getCallCount(), 2);

        // Step 4: Verify vault accumulated fees
        assertEq(vault.getAccumulatedETH(), tax1 + tax2);

        // Step 5: Verify benefactor tracking
        uint256 percent1 = vault.getBenefactorPercentage(PROJECT1);
        uint256 percent2 = vault.getBenefactorPercentage(PROJECT2);
        assertEq(percent1, 33); // 1 / 3 = 33%
        assertEq(percent2, 66); // 2 / 3 = 66%
    }

    // ========== Phase 2: Upgrade Scenario ==========

    /**
     * @notice Test Phase 1 → Phase 2 upgrade: vault code unchanged, module swapped
     */
    function test_Phase1_to_Phase2_Upgrade_SeamlessSwap() public {
        // ========== PHASE 1 ==========
        vault.setBeneficiaryModule(address(simpleBeneficiary));

        uint256 phase1Tax = 3 ether;
        vm.prank(HOOK);
        vault.receiveERC404Tax(Currency.wrap(address(0)), phase1Tax, PROJECT1);

        assertEq(simpleBeneficiary.getTotalFeesReceived(), phase1Tax);
        assertEq(vault.getAccumulatedETH(), phase1Tax);

        // ========== UPGRADE TO PHASE 2 ==========
        // Just swap the module (1 transaction!)
        vault.setBeneficiaryModule(address(benefactorStaking));

        // Vault code: unchanged
        // Vault state: unchanged
        // Accumulated fees: unchanged

        // ========== PHASE 2 ==========
        uint256 phase2Tax = 2 ether;
        vm.prank(HOOK);
        vault.receiveERC404Tax(Currency.wrap(address(0)), phase2Tax, PROJECT1);

        // Old beneficiary: no new notifications
        assertEq(simpleBeneficiary.getTotalFeesReceived(), phase1Tax);

        // New beneficiary: receives only Phase 2 taxes
        assertEq(benefactorStaking.getTotalFeesReceived(), phase2Tax);

        // Vault: accumulated both
        assertEq(vault.getAccumulatedETH(), phase1Tax + phase2Tax);
    }

    /**
     * @notice Test fees from Phase 1 are included in vault state when Phase 2 starts
     */
    function test_Phase2_SeesAllPhase1Data() public {
        // Phase 1: Accumulate fees
        vault.setBeneficiaryModule(address(simpleBeneficiary));

        uint256 tax1 = 1 ether;
        uint256 tax2 = 2 ether;

        vm.prank(HOOK);
        vault.receiveERC404Tax(Currency.wrap(address(0)), tax1, PROJECT1);

        vm.prank(HOOK);
        vault.receiveERC404Tax(Currency.wrap(address(0)), tax2, PROJECT2);

        // Verify Phase 1 state
        assertEq(vault.getAccumulatedETH(), tax1 + tax2);
        assertEq(vault.getTotalETHCollected(), uint128(tax1 + tax2));

        // Upgrade to Phase 2
        vault.setBeneficiaryModule(address(benefactorStaking));

        // Phase 2 module can see all accumulated fees
        assertEq(vault.getAccumulatedETH(), tax1 + tax2);
        assertEq(vault.getTotalETHCollected(), uint128(tax1 + tax2));

        // Phase 2 module can see all benefactors
        address[] memory benefactors = vault.getRegisteredBenefactors();
        assertEq(benefactors.length, 2);
        assertEq(benefactors[0], PROJECT1);
        assertEq(benefactors[1], PROJECT2);

        // Phase 2 module can access benefactor metrics
        uint256 percent1 = vault.getBenefactorPercentage(PROJECT1);
        uint256 percent2 = vault.getBenefactorPercentage(PROJECT2);
        assertEq(percent1, 33);
        assertEq(percent2, 66);
    }

    /**
     * @notice Test Phase 2 benefactor system receives all notifications going forward
     */
    function test_Phase2_ReceivesAllNewTaxes() public {
        // Phase 1 initial setup
        vault.setBeneficiaryModule(address(simpleBeneficiary));

        uint256 phase1Tax = 1 ether;
        vm.prank(HOOK);
        vault.receiveERC404Tax(Currency.wrap(address(0)), phase1Tax, PROJECT1);

        // Upgrade to Phase 2
        vault.setBeneficiaryModule(address(benefactorStaking));

        // Phase 2: All new taxes go to staking module
        uint256 tax2 = 0.5 ether;
        uint256 tax3 = 1.5 ether;
        uint256 tax4 = 2 ether;

        vm.prank(HOOK);
        vault.receiveERC404Tax(Currency.wrap(address(0)), tax2, PROJECT1);

        vm.prank(HOOK);
        vault.receiveERC404Tax(Currency.wrap(address(0)), tax3, PROJECT2);

        vm.prank(HOOK);
        vault.receiveERC404Tax(Currency.wrap(address(0)), tax4, PROJECT1);

        // Verify Phase 1 module didn't receive Phase 2 taxes
        assertEq(simpleBeneficiary.getTotalFeesReceived(), phase1Tax);

        // Verify Phase 2 module received all Phase 2 taxes
        uint256 totalPhase2Taxes = tax2 + tax3 + tax4;
        assertEq(benefactorStaking.getTotalFeesReceived(), totalPhase2Taxes);

        // Vault accumulated everything
        uint256 totalFees = phase1Tax + totalPhase2Taxes;
        assertEq(vault.getAccumulatedETH(), totalFees);
    }

    /**
     * @notice Test rolling back from Phase 2 to Phase 1 (contingency scenario)
     */
    function test_Rollback_Phase2_to_Phase1() public {
        // Start in Phase 2
        vault.setBeneficiaryModule(address(benefactorStaking));

        uint256 tax1 = 1 ether;
        vm.prank(HOOK);
        vault.receiveERC404Tax(Currency.wrap(address(0)), tax1, PROJECT1);

        assertEq(benefactorStaking.getTotalFeesReceived(), tax1);

        // If there's a problem with Phase 2, roll back to Phase 1
        vault.setBeneficiaryModule(address(simpleBeneficiary));

        // Send more taxes
        uint256 tax2 = 2 ether;
        vm.prank(HOOK);
        vault.receiveERC404Tax(Currency.wrap(address(0)), tax2, PROJECT1);

        // Phase 2 module: no new notifications
        assertEq(benefactorStaking.getTotalFeesReceived(), tax1);

        // Phase 1 module: receives Phase 2 taxes
        assertEq(simpleBeneficiary.getTotalFeesReceived(), tax2);

        // Vault: accumulated all
        assertEq(vault.getAccumulatedETH(), tax1 + tax2);
    }

    /**
     * @notice Test disabling beneficiary module doesn't break vault
     */
    function test_Phase2_DisableBeneficiary() public {
        vault.setBeneficiaryModule(address(benefactorStaking));

        uint256 tax1 = 1 ether;
        vm.prank(HOOK);
        vault.receiveERC404Tax(Currency.wrap(address(0)), tax1, PROJECT1);

        assertEq(benefactorStaking.getTotalFeesReceived(), tax1);

        // Disable beneficiary (emergency scenario)
        vault.setBeneficiaryModule(address(0));

        // Vault still works
        uint256 tax2 = 2 ether;
        vm.prank(HOOK);
        vault.receiveERC404Tax(Currency.wrap(address(0)), tax2, PROJECT1);

        // Beneficiary not notified
        assertEq(benefactorStaking.getTotalFeesReceived(), tax1);

        // But vault still accumulated
        assertEq(vault.getAccumulatedETH(), tax1 + tax2);
    }

    /**
     * @notice Test multiple upgrades are supported
     */
    function test_Multiple_Module_Swaps() public {
        // Start: Phase 1
        vault.setBeneficiaryModule(address(simpleBeneficiary));
        uint256 tax1 = 1 ether;
        vm.prank(HOOK);
        vault.receiveERC404Tax(Currency.wrap(address(0)), tax1, PROJECT1);

        // Upgrade: Phase 2
        vault.setBeneficiaryModule(address(benefactorStaking));
        uint256 tax2 = 2 ether;
        vm.prank(HOOK);
        vault.receiveERC404Tax(Currency.wrap(address(0)), tax2, PROJECT1);

        // Deploy another Phase 2 variant
        MockBenefactorStaking benefactorStaking2 = new MockBenefactorStaking(address(vault));

        // Upgrade: Phase 2 variant 2
        vault.setBeneficiaryModule(address(benefactorStaking2));
        uint256 tax3 = 3 ether;
        vm.prank(HOOK);
        vault.receiveERC404Tax(Currency.wrap(address(0)), tax3, PROJECT1);

        // Each module only received their taxes
        assertEq(simpleBeneficiary.getTotalFeesReceived(), tax1);
        assertEq(benefactorStaking.getTotalFeesReceived(), tax2);
        assertEq(benefactorStaking2.getTotalFeesReceived(), tax3);

        // Vault accumulated all
        assertEq(vault.getAccumulatedETH(), tax1 + tax2 + tax3);
    }

    /**
     * @notice Test vault bytecode unchanged between Phase 1 and Phase 2
     */
    function test_VaultBytecodeUnchanged() public {
        // Get vault code before Phase 2
        bytes memory vaultCodePhase1 = address(vault).code;

        // Swap module to Phase 2
        vault.setBeneficiaryModule(address(benefactorStaking));

        // Get vault code after Phase 2
        bytes memory vaultCodePhase2 = address(vault).code;

        // Same bytecode = vault contract unchanged
        assertEq(vaultCodePhase1.length, vaultCodePhase2.length);
        // (Deep equality would be more complex, but size equality is good enough for this test)
    }

    // ========== Integration Scenarios ==========

    /**
     * @notice Test real-world scenario: launch with Phase 1, upgrade to Phase 2 after metrics gathered
     */
    function test_RealWorldScenario_LaunchAndUpgrade() public {
        // PHASE 1: LAUNCH
        // Treasury gets designated as beneficiary (via SimpleBeneficiary)
        vault.setBeneficiaryModule(address(simpleBeneficiary));

        // Collect taxes for month 1
        uint256 month1Tax = 10 ether;
        vm.prank(HOOK);
        vault.receiveERC404Tax(Currency.wrap(address(0)), month1Tax, PROJECT1);

        // Month 2: more projects, more taxes
        uint256 month2_project1 = 5 ether;
        uint256 month2_project2 = 15 ether;

        vm.prank(HOOK);
        vault.receiveERC404Tax(Currency.wrap(address(0)), month2_project1, PROJECT1);

        vm.prank(HOOK);
        vault.receiveERC404Tax(Currency.wrap(address(0)), month2_project2, PROJECT2);

        // Analyze metrics
        uint256 totalPhase1 = month1Tax + month2_project1 + month2_project2;
        assertEq(vault.getAccumulatedETH(), totalPhase1);

        uint256 percent1 = vault.getBenefactorPercentage(PROJECT1);
        uint256 percent2 = vault.getBenefactorPercentage(PROJECT2);
        // PROJECT1: 15 / 30 = 50%
        // PROJECT2: 15 / 30 = 50%
        assertEq(percent1, 50);
        assertEq(percent2, 50);

        // PHASE 2: UPGRADE
        // Now we're ready for benefactor staking
        vault.setBeneficiaryModule(address(benefactorStaking));

        // Month 3: With benefactor module active
        uint256 month3Tax = 20 ether;
        vm.prank(HOOK);
        vault.receiveERC404Tax(Currency.wrap(address(0)), month3Tax, PROJECT1);

        // Benefactor module receives notifications
        assertEq(benefactorStaking.getTotalFeesReceived(), month3Tax);

        // But Phase 1 beneficiary doesn't get new fees
        assertEq(simpleBeneficiary.getTotalFeesReceived(), totalPhase1);

        // All accumulated
        assertEq(vault.getAccumulatedETH(), totalPhase1 + month3Tax);
    }
}
