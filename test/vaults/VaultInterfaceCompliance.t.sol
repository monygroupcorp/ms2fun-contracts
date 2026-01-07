// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IAlignmentVault} from "../../src/interfaces/IAlignmentVault.sol";
import {UltraAlignmentVault} from "../../src/vaults/UltraAlignmentVault.sol";
import {MockVault} from "../mocks/MockVault.sol";
import {Currency} from "v4-core/types/Currency.sol";

/**
 * @title VaultInterfaceComplianceTest
 * @notice Tests that vault implementations properly implement IAlignmentVault interface
 * @dev Validates both UltraAlignmentVault and MockVault interface compliance
 */
contract VaultInterfaceComplianceTest is Test {
    // Vault instances
    UltraAlignmentVault ultraVault;
    MockVault mockVault;

    // Mock addresses for UltraAlignmentVault constructor
    address constant MOCK_WETH = address(0x1);
    address constant MOCK_POOL_MANAGER = address(0x2);
    address constant MOCK_V3_ROUTER = address(0x3);
    address constant MOCK_V2_ROUTER = address(0x4);
    address constant MOCK_V2_FACTORY = address(0x5);
    address constant MOCK_V3_FACTORY = address(0x6);
    address constant MOCK_ALIGNMENT_TOKEN = address(0x7);

    // Test benefactors
    address benefactor1 = makeAddr("benefactor1");
    address benefactor2 = makeAddr("benefactor2");

    function setUp() public {
        // Deploy UltraAlignmentVault with mock addresses
        ultraVault = new UltraAlignmentVault(
            MOCK_WETH,
            MOCK_POOL_MANAGER,
            MOCK_V3_ROUTER,
            MOCK_V2_ROUTER,
            MOCK_V2_FACTORY,
            MOCK_V3_FACTORY,
            MOCK_ALIGNMENT_TOKEN
        );

        // Deploy MockVault
        mockVault = new MockVault();

        // Fund test accounts
        vm.deal(benefactor1, 100 ether);
        vm.deal(benefactor2, 100 ether);
    }

    // ========== Interface Compliance Tests ==========

    /**
     * @notice Test UltraAlignmentVault implements IAlignmentVault
     */
    function test_UltraAlignmentVault_ImplementsInterface() public {
        // Cast to interface (payable required for interface with receive())
        IAlignmentVault vault = IAlignmentVault(payable(address(ultraVault)));

        // Verify vaultType returns correct string
        assertEq(vault.vaultType(), "UniswapV4LP");

        // Verify description is non-empty
        assertTrue(bytes(vault.description()).length > 0);
        assertEq(
            vault.description(),
            "Full-range liquidity provision on Uniswap V4 with automated fee compounding and benefactor share distribution"
        );
    }

    /**
     * @notice Test MockVault implements IAlignmentVault
     */
    function test_MockVault_ImplementsInterface() public {
        // Cast to interface (payable required for interface with receive())
        IAlignmentVault vault = IAlignmentVault(payable(address(mockVault)));

        // Verify vaultType returns correct string
        assertEq(vault.vaultType(), "MockVault");

        // Verify description is non-empty
        assertTrue(bytes(vault.description()).length > 0);
        assertTrue(bytes(vault.description()).length > 20); // Should be descriptive
    }

    /**
     * @notice Test all interface methods are callable via interface reference
     */
    function test_InterfaceMethods_CallableViaMockVault() public {
        // Use interface reference instead of concrete type
        IAlignmentVault vault = IAlignmentVault(payable(address(mockVault)));

        // Test receiveHookTax
        vm.prank(benefactor1);
        vault.receiveHookTax{value: 1 ether}(
            Currency.wrap(address(0)),
            1 ether,
            benefactor1
        );

        // Test calculateClaimableAmount
        uint256 claimable = vault.calculateClaimableAmount(benefactor1);
        assertEq(claimable, 1 ether, "Should be able to claim 1 ETH");

        // Test share queries
        assertEq(vault.getBenefactorContribution(benefactor1), 1 ether, "Contribution should be 1 ETH");
        assertEq(vault.getBenefactorShares(benefactor1), 1 ether, "Shares should be 1 ETH");

        // Test vault info
        assertEq(vault.totalShares(), 1 ether, "Total shares should be 1 ETH");
        assertEq(vault.accumulatedFees(), 1 ether, "Accumulated fees should be 1 ETH");

        // Test claimFees
        vm.prank(benefactor1);
        uint256 claimed = vault.claimFees();
        assertEq(claimed, 1 ether, "Should claim 1 ETH");

        // After claim, accumulated fees should be 0
        assertEq(vault.accumulatedFees(), 0, "Fees should be 0 after claim");
    }

    /**
     * @notice Test interface casting works for both vaults
     */
    function test_InterfaceCast_WorksForBothVaults() public {
        // Cast both to interface
        IAlignmentVault vault1 = IAlignmentVault(payable(address(ultraVault)));
        IAlignmentVault vault2 = IAlignmentVault(payable(address(mockVault)));

        // Both should have vaultType
        assertTrue(bytes(vault1.vaultType()).length > 0);
        assertTrue(bytes(vault2.vaultType()).length > 0);

        // Both should have description
        assertTrue(bytes(vault1.description()).length > 0);
        assertTrue(bytes(vault2.description()).length > 0);

        // Vault types should be different
        assertFalse(
            keccak256(bytes(vault1.vaultType())) == keccak256(bytes(vault2.vaultType())),
            "Vault types should be different"
        );
    }

    // ========== Functional Tests ==========

    /**
     * @notice Test MockVault receiveHookTax functionality
     */
    function test_MockVault_ReceiveHookTax() public {
        vm.prank(benefactor1);
        mockVault.receiveHookTax{value: 5 ether}(
            Currency.wrap(address(0)),
            5 ether,
            benefactor1
        );

        assertEq(mockVault.getBenefactorContribution(benefactor1), 5 ether);
        assertEq(mockVault.getBenefactorShares(benefactor1), 5 ether);
        assertEq(mockVault.totalShares(), 5 ether);
        assertEq(mockVault.accumulatedFees(), 5 ether);
    }

    /**
     * @notice Test MockVault receive() fallback
     */
    function test_MockVault_ReceiveFallback() public {
        vm.prank(benefactor1);
        (bool success, ) = address(mockVault).call{value: 3 ether}("");
        assertTrue(success, "ETH transfer should succeed");

        assertEq(mockVault.getBenefactorContribution(benefactor1), 3 ether);
        assertEq(mockVault.getBenefactorShares(benefactor1), 3 ether);
    }

    /**
     * @notice Test MockVault multi-benefactor scenario
     */
    function test_MockVault_MultiBenefactor() public {
        // Benefactor1 contributes 6 ETH
        vm.prank(benefactor1);
        mockVault.receiveHookTax{value: 6 ether}(
            Currency.wrap(address(0)),
            6 ether,
            benefactor1
        );

        // Benefactor2 contributes 4 ETH
        vm.prank(benefactor2);
        mockVault.receiveHookTax{value: 4 ether}(
            Currency.wrap(address(0)),
            4 ether,
            benefactor2
        );

        // Total should be 10 ETH
        assertEq(mockVault.totalShares(), 10 ether);
        assertEq(mockVault.accumulatedFees(), 10 ether);

        // Benefactor1 should be able to claim 60% (6/10)
        uint256 claimable1 = mockVault.calculateClaimableAmount(benefactor1);
        assertEq(claimable1, 6 ether, "Benefactor1 should claim 6 ETH");

        // Benefactor2 should be able to claim 40% (4/10)
        uint256 claimable2 = mockVault.calculateClaimableAmount(benefactor2);
        assertEq(claimable2, 4 ether, "Benefactor2 should claim 4 ETH");
    }

    /**
     * @notice Test MockVault claim and reclaim scenario
     */
    function test_MockVault_ClaimAndReclaim() public {
        // Initial contribution
        vm.prank(benefactor1);
        mockVault.receiveHookTax{value: 10 ether}(
            Currency.wrap(address(0)),
            10 ether,
            benefactor1
        );

        // Claim all fees
        vm.prank(benefactor1);
        uint256 claimed1 = mockVault.claimFees();
        assertEq(claimed1, 10 ether, "Should claim all 10 ETH");
        assertEq(mockVault.accumulatedFees(), 0, "Fees should be 0 after claim");

        // Add more yield (in MockVault, we simulate this)
        mockVault.simulateYield{value: 5 ether}(5 ether);
        assertEq(mockVault.accumulatedFees(), 5 ether, "Should have 5 ETH in fees");

        // Claim again
        vm.prank(benefactor1);
        uint256 claimed2 = mockVault.claimFees();
        assertEq(claimed2, 5 ether, "Should claim 5 ETH on second claim");
    }

    /**
     * @notice Test UltraAlignmentVault has correct interface methods
     */
    function test_UltraAlignmentVault_HasInterfaceMethods() public {
        // Verify vaultType
        assertEq(ultraVault.vaultType(), "UniswapV4LP");

        // Verify description
        string memory desc = ultraVault.description();
        assertTrue(bytes(desc).length > 50, "Description should be detailed");

        // Verify state getters exist
        ultraVault.totalShares(); // Should not revert
        ultraVault.accumulatedFees(); // Should not revert
    }

    /**
     * @notice Test interface methods don't require concrete type knowledge
     */
    function test_InterfaceAbstraction_NoConcretTypeNeeded() public {
        // Function that accepts any IAlignmentVault
        _testAnyVault(IAlignmentVault(payable(address(mockVault))), benefactor1);
        _testAnyVault(IAlignmentVault(payable(address(ultraVault))), benefactor2);
    }

    /**
     * @notice Helper function demonstrating vault abstraction
     * @dev This function works with ANY vault that implements IAlignmentVault
     */
    function _testAnyVault(IAlignmentVault vault, address benefactor) internal {
        // Can call vaultType without knowing concrete implementation
        string memory vType = vault.vaultType();
        assertTrue(bytes(vType).length > 0, "All vaults must have a type");

        // Can call description without knowing concrete implementation
        string memory desc = vault.description();
        assertTrue(bytes(desc).length > 0, "All vaults must have a description");

        // Can query state without knowing concrete implementation
        uint256 shares = vault.totalShares();
        uint256 fees = vault.accumulatedFees();

        // These are just queries, testing abstraction works
        // (values may be 0, that's fine)
    }

    // ========== Edge Case Tests ==========

    /**
     * @notice Test vaultType returns non-empty string
     */
    function test_VaultType_NonEmpty() public {
        assertGt(bytes(mockVault.vaultType()).length, 0, "MockVault type should not be empty");
        assertGt(bytes(ultraVault.vaultType()).length, 0, "UltraVault type should not be empty");
    }

    /**
     * @notice Test description returns non-empty string
     */
    function test_Description_NonEmpty() public {
        assertGt(bytes(mockVault.description()).length, 0, "MockVault description should not be empty");
        assertGt(bytes(ultraVault.description()).length, 0, "UltraVault description should not be empty");
    }

    /**
     * @notice Test description is sufficiently descriptive (>20 chars)
     */
    function test_Description_Descriptive() public {
        assertGt(bytes(mockVault.description()).length, 20, "MockVault description should be descriptive");
        assertGt(bytes(ultraVault.description()).length, 20, "UltraVault description should be descriptive");
    }

    /**
     * @notice Test calculateClaimableAmount returns 0 for unknown benefactor
     */
    function test_CalculateClaimable_UnknownBenefactor() public {
        address unknown = makeAddr("unknown");
        uint256 claimable = mockVault.calculateClaimableAmount(unknown);
        assertEq(claimable, 0, "Unknown benefactor should have 0 claimable");
    }

    /**
     * @notice Test getBenefactorShares returns 0 for unknown benefactor
     */
    function test_GetShares_UnknownBenefactor() public {
        address unknown = makeAddr("unknown");
        uint256 shares = mockVault.getBenefactorShares(unknown);
        assertEq(shares, 0, "Unknown benefactor should have 0 shares");
    }

    /**
     * @notice Test getBenefactorContribution returns 0 for unknown benefactor
     */
    function test_GetContribution_UnknownBenefactor() public {
        address unknown = makeAddr("unknown");
        uint256 contribution = mockVault.getBenefactorContribution(unknown);
        assertEq(contribution, 0, "Unknown benefactor should have 0 contribution");
    }

    // ========== Event Tests ==========

    /**
     * @notice Test ContributionReceived event is emitted
     */
    function test_Event_ContributionReceived() public {
        vm.expectEmit(true, true, true, true);
        emit IAlignmentVault.ContributionReceived(benefactor1, 1 ether);

        vm.prank(benefactor1);
        mockVault.receiveHookTax{value: 1 ether}(
            Currency.wrap(address(0)),
            1 ether,
            benefactor1
        );
    }

    /**
     * @notice Test FeesClaimed event is emitted
     */
    function test_Event_FeesClaimed() public {
        // Setup: contribute first
        vm.prank(benefactor1);
        mockVault.receiveHookTax{value: 1 ether}(
            Currency.wrap(address(0)),
            1 ether,
            benefactor1
        );

        // Expect event
        vm.expectEmit(true, true, true, true);
        emit IAlignmentVault.FeesClaimed(benefactor1, 1 ether);

        // Claim
        vm.prank(benefactor1);
        mockVault.claimFees();
    }

    /**
     * @notice Test FeesAccumulated event is emitted
     */
    function test_Event_FeesAccumulated() public {
        vm.expectEmit(true, true, true, true);
        emit IAlignmentVault.FeesAccumulated(1 ether);

        vm.prank(benefactor1);
        mockVault.receiveHookTax{value: 1 ether}(
            Currency.wrap(address(0)),
            1 ether,
            benefactor1
        );
    }
}
