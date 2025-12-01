// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {UltraAlignmentVault} from "src/vaults/UltraAlignmentVault.sol";
import {MockBeneficiary} from "test/mocks/MockBeneficiary.sol";
import {Currency} from "v4-core/types/Currency.sol";

/**
 * @title UltraAlignmentVaultTest
 * @notice Comprehensive tests for Phase 1 vault functionality
 * @dev Tests cover: fee collection, project tracking, and Phase 2 upgrade path
 */
contract UltraAlignmentVaultTest is Test {
    // ========== Setup ==========

    UltraAlignmentVault vault;
    MockBeneficiary mockBeneficiary;

    address constant ALIGNMENT_TARGET = address(0x1111111111111111111111111111111111111111);
    address constant V3_POOL = address(0x2222222222222222222222222222222222222222);
    address constant WETH = address(0x3333333333333333333333333333333333333333);
    address constant V3_POSITION_MANAGER = address(0x4444444444444444444444444444444444444444);
    address constant V4_POOL_MANAGER = address(0x5555555555555555555555555555555555555555);
    address constant ROUTER = address(0x6666666666666666666666666666666666666666);

    address constant HOOK1 = address(0x7777777777777777777777777777777777777777);
    address constant HOOK2 = address(0x8888888888888888888888888888888888888888);
    address constant INSTANCE1 = address(0x9999999999999999999999999999999999999999);
    address constant INSTANCE2 = address(0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa);
    address constant PROJECT1 = address(0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB);
    address constant PROJECT2 = address(0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC);

    function setUp() public {
        // Deploy vault
        vault = new UltraAlignmentVault(
            ALIGNMENT_TARGET,
            V3_POOL,
            WETH,
            V3_POSITION_MANAGER,
            V4_POOL_MANAGER,
            ROUTER,
            HOOK2  // Hook factory
        );

        // Deploy mock beneficiary
        mockBeneficiary = new MockBeneficiary(address(vault));
    }

    // ========== Fee Reception Tests ==========

    /**
     * @notice Test ERC404 tax reception from hook
     */
    function test_ReceiveERC404Tax_ValidAmount() public {
        uint256 taxAmount = 1 ether;

        // Send tax from authorized hook
        vm.prank(HOOK1);
        vault.receiveERC404Tax(Currency.wrap(address(0)), taxAmount, PROJECT1);

        // Verify accumulation
        assertEq(vault.getAccumulatedETH(), taxAmount);
        assertEq(vault.getTotalETHCollected(), uint128(taxAmount));
    }

    /**
     * @notice Test multiple ERC404 taxes accumulate
     */
    function test_ReceiveERC404Tax_Multiple() public {
        uint256 tax1 = 1 ether;
        uint256 tax2 = 2 ether;
        uint256 tax3 = 0.5 ether;

        vm.prank(HOOK1);
        vault.receiveERC404Tax(Currency.wrap(address(0)), tax1, PROJECT1);

        vm.prank(HOOK2);
        vault.receiveERC404Tax(Currency.wrap(address(0)), tax2, PROJECT1);

        vm.prank(HOOK1);
        vault.receiveERC404Tax(Currency.wrap(address(0)), tax3, PROJECT2);

        assertEq(vault.getAccumulatedETH(), tax1 + tax2 + tax3);
        assertEq(vault.getTotalETHCollected(), uint128(tax1 + tax2 + tax3));
    }

    /**
     * @notice Test ERC1155 tithe reception
     */
    function test_ReceiveERC1155Tithe_ValidAmount() public {
        uint256 titheAmount = 0.5 ether;

        // Send tithe from authorized instance
        vm.deal(INSTANCE1, titheAmount);
        vm.prank(INSTANCE1);
        vault.receiveERC1155Tithe{value: titheAmount}(PROJECT1);

        // Verify accumulation
        assertEq(vault.getAccumulatedETH(), titheAmount);
        assertEq(vault.getTotalETHCollected(), uint128(titheAmount));
    }

    /**
     * @notice Test ERC404 and ERC1155 fees accumulate together
     */
    function test_ReceiveFeesFromBothSources() public {
        uint256 erc404Tax = 1 ether;
        uint256 erc1155Tithe = 0.5 ether;

        vm.prank(HOOK1);
        vault.receiveERC404Tax(Currency.wrap(address(0)), erc404Tax, PROJECT1);

        vm.deal(INSTANCE1, erc1155Tithe);
        vm.prank(INSTANCE1);
        vault.receiveERC1155Tithe{value: erc1155Tithe}(PROJECT2);

        assertEq(vault.getAccumulatedETH(), erc404Tax + erc1155Tithe);
        assertEq(vault.getTotalETHCollected(), uint128(erc404Tax + erc1155Tithe));
    }


    // ========== Project Tracking Tests ==========

    /**
     * @notice Test benefactor contribution tracking
     */
    function test_BenefactorContribution_Tracking() public {
        uint256 amount1 = 1 ether;
        uint256 amount2 = 2 ether;

        vm.prank(HOOK1);
        vault.receiveERC404Tax(Currency.wrap(address(0)), amount1, PROJECT1);

        vm.prank(HOOK2);
        vault.receiveERC404Tax(Currency.wrap(address(0)), amount2, PROJECT1);

        // Get benefactor contribution
        UltraAlignmentVault.BenefactorContribution memory contrib = vault.getBenefactorContribution(
            PROJECT1
        );

        assertEq(contrib.benefactor, PROJECT1);
        assertEq(contrib.totalETHContributed, amount1 + amount2);
        assertEq(contrib.exists, true);
    }

    /**
     * @notice Test multiple benefactors tracked separately
     */
    function test_BenefactorContribution_Multiple() public {
        uint256 amount1 = 1 ether;
        uint256 amount2 = 2 ether;

        vm.prank(HOOK1);
        vault.receiveERC404Tax(Currency.wrap(address(0)), amount1, PROJECT1);

        vm.prank(HOOK2);
        vault.receiveERC404Tax(Currency.wrap(address(0)), amount2, PROJECT2);

        UltraAlignmentVault.BenefactorContribution memory contrib1 = vault.getBenefactorContribution(
            PROJECT1
        );
        UltraAlignmentVault.BenefactorContribution memory contrib2 = vault.getBenefactorContribution(
            PROJECT2
        );

        assertEq(contrib1.totalETHContributed, amount1);
        assertEq(contrib2.totalETHContributed, amount2);
    }

    /**
     * @notice Test benefactor percentage calculation
     */
    function test_BenefactorPercentage_Calculation() public {
        uint256 amount1 = 2 ether;
        uint256 amount2 = 8 ether;

        vm.prank(HOOK1);
        vault.receiveERC404Tax(Currency.wrap(address(0)), amount1, PROJECT1);

        vm.prank(HOOK2);
        vault.receiveERC404Tax(Currency.wrap(address(0)), amount2, PROJECT2);

        // Benefactor1: 2 / 10 = 20%
        uint256 percent1 = vault.getBenefactorPercentage(PROJECT1);
        assertEq(percent1, 20);

        // Benefactor2: 8 / 10 = 80%
        uint256 percent2 = vault.getBenefactorPercentage(PROJECT2);
        assertEq(percent2, 80);
    }

    /**
     * @notice Test get all benefactors
     */
    function test_GetRegisteredBenefactors() public {
        vm.prank(HOOK1);
        vault.receiveERC404Tax(Currency.wrap(address(0)), 1 ether, PROJECT1);

        vm.prank(HOOK2);
        vault.receiveERC404Tax(Currency.wrap(address(0)), 1 ether, PROJECT2);

        address[] memory benefactors = vault.getRegisteredBenefactors();
        assertEq(benefactors.length, 2);
        assertEq(benefactors[0], PROJECT1);
        assertEq(benefactors[1], PROJECT2);
    }

    /**
     * @notice Test open receive function accepts direct ETH
     */
    function test_ReceiveDirectETH() public {
        uint256 amount = 1 ether;

        vm.deal(address(0xdeadbeef), amount);
        vm.prank(address(0xdeadbeef));
        (bool success, ) = address(vault).call{value: amount}("");
        require(success, "Direct ETH send failed");

        // Verify contribution tracked
        assertEq(vault.getAccumulatedETH(), amount);
        assertEq(vault.getTotalETHCollected(), uint128(amount));
    }

    // ========== Phase 2 Upgrade Path Tests ==========

    /**
     * @notice Test setting beneficiary module
     */
    function test_SetBeneficiaryModule() public {
        vault.setBeneficiaryModule(address(mockBeneficiary));
        assertEq(vault.beneficiaryModule(), address(mockBeneficiary));
    }

    /**
     * @notice Test beneficiary module receives fee notifications
     */
    function test_BeneficiaryModule_ReceivesNotification() public {
        vault.setBeneficiaryModule(address(mockBeneficiary));

        uint256 taxAmount = 1 ether;

        vm.prank(HOOK1);
        vault.receiveERC404Tax(Currency.wrap(address(0)), taxAmount, PROJECT1);

        // Module should have received the notification
        assertEq(mockBeneficiary.getTotalFeesReceived(), taxAmount);
        assertEq(mockBeneficiary.getCallCount(), 1);
    }

    /**
     * @notice Test multiple notifications to beneficiary module
     */
    function test_BeneficiaryModule_MultipleNotifications() public {
        vault.setBeneficiaryModule(address(mockBeneficiary));

        uint256 tax1 = 1 ether;
        uint256 tax2 = 2 ether;
        uint256 tax3 = 0.5 ether;

        vm.prank(HOOK1);
        vault.receiveERC404Tax(Currency.wrap(address(0)), tax1, PROJECT1);

        vm.prank(HOOK2);
        vault.receiveERC404Tax(Currency.wrap(address(0)), tax2, PROJECT1);

        vm.deal(INSTANCE1, tax3);
        vm.prank(INSTANCE1);
        vault.receiveERC1155Tithe{value: tax3}(PROJECT2);

        assertEq(mockBeneficiary.getTotalFeesReceived(), tax1 + tax2 + tax3);
        assertEq(mockBeneficiary.getCallCount(), 3);
    }

    /**
     * @notice Test replacing beneficiary module
     */
    function test_ReplaceBeneficiaryModule() public {
        vault.setBeneficiaryModule(address(mockBeneficiary));

        // Send some fees
        vm.prank(HOOK1);
        vault.receiveERC404Tax(Currency.wrap(address(0)), 1 ether, PROJECT1);

        assertEq(mockBeneficiary.getTotalFeesReceived(), 1 ether);

        // Deploy new beneficiary
        MockBeneficiary mockBeneficiary2 = new MockBeneficiary(address(vault));

        // Replace module
        vault.setBeneficiaryModule(address(mockBeneficiary2));

        // Send more fees
        vm.prank(HOOK2);
        vault.receiveERC404Tax(Currency.wrap(address(0)), 2 ether, PROJECT1);

        // Old module unchanged
        assertEq(mockBeneficiary.getTotalFeesReceived(), 1 ether);

        // New module receives new fees
        assertEq(mockBeneficiary2.getTotalFeesReceived(), 2 ether);
    }

    /**
     * @notice Test disabling beneficiary module
     */
    function test_DisableBeneficiaryModule() public {
        vault.setBeneficiaryModule(address(mockBeneficiary));

        vm.prank(HOOK1);
        vault.receiveERC404Tax(Currency.wrap(address(0)), 1 ether, PROJECT1);

        assertEq(mockBeneficiary.getTotalFeesReceived(), 1 ether);

        // Disable module
        vault.setBeneficiaryModule(address(0));

        // Send more fees
        vm.prank(HOOK2);
        vault.receiveERC404Tax(Currency.wrap(address(0)), 2 ether, PROJECT1);

        // Module not notified of new fees
        assertEq(mockBeneficiary.getTotalFeesReceived(), 1 ether);
        assertEq(vault.getAccumulatedETH(), 3 ether);
    }

    /**
     * @notice Test vault continues working even if beneficiary module reverts
     */
    function test_VaultWorksWhenBeneficiaryReverts() public {
        // Create a beneficiary that will revert
        RevertingBeneficiary revertingBeneficiary = new RevertingBeneficiary(address(vault));
        vault.setBeneficiaryModule(address(revertingBeneficiary));

        // Send tax - should not revert despite beneficiary reverting
        vm.prank(HOOK1);
        vault.receiveERC404Tax(Currency.wrap(address(0)), 1 ether, PROJECT1);

        // Fees should still accumulate
        assertEq(vault.getAccumulatedETH(), 1 ether);
    }

    // ========== Configuration Tests ==========

    /**
     * @notice Test set minimum conversion threshold
     */
    function test_SetMinConversionThreshold() public {
        uint256 newThreshold = 0.05 ether;
        vault.setMinConversionThreshold(newThreshold);
        // No direct getter, but can be called without reverting
    }

    /**
     * @notice Test set minimum liquidity threshold
     */
    function test_SetMinLiquidityThreshold() public {
        uint256 newThreshold = 0.01 ether;
        vault.setMinLiquidityThreshold(newThreshold);
        // No direct getter, but can be called without reverting
    }

    /**
     * @notice Test non-owner cannot configure
     */
    function test_OnlyOwnerCanConfigure() public {
        vm.prank(address(0xdeadbeef));
        vm.expectRevert();
        vault.setMinConversionThreshold(0.05 ether);
    }
}

// ========== Helper Contracts ==========

/**
 * @notice Beneficiary that reverts for testing error handling
 */
contract RevertingBeneficiary {
    address public vault;

    constructor(address _vault) {
        vault = _vault;
    }

    function onFeeAccumulated(uint256 amount) external {
        require(msg.sender == vault, "Only vault");
        revert("Always revert");
    }
}
