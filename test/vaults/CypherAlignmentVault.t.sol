// test/vaults/CypherAlignmentVault.t.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "forge-std/Test.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockAlgebraPositionManager, MockAlgebraSwapRouter} from "../mocks/MockCypherAlgebra.sol";
import {MockWETH} from "../mocks/MockWETH.sol";
import {TestableCypherAlignmentVault} from "../helpers/TestableCypherAlignmentVault.sol";
import {CypherAlignmentVault} from "../../src/vaults/cypher/CypherAlignmentVault.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {Ownable} from "solady/auth/Ownable.sol";

contract CypherAlignmentVaultTest is Test {
    TestableCypherAlignmentVault vault;
    MockERC20 alignmentToken;
    MockWETH weth;
    MockAlgebraPositionManager positionManager;
    MockAlgebraSwapRouter swapRouter;

    address owner = address(this);
    address liquidityDeployer = makeAddr("liquidityDeployer");
    address protocolTreasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public {
        alignmentToken = new MockERC20("Alignment", "ALN");
        weth = new MockWETH();
        positionManager = new MockAlgebraPositionManager();
        swapRouter = new MockAlgebraSwapRouter();

        TestableCypherAlignmentVault impl = new TestableCypherAlignmentVault();
        vault = TestableCypherAlignmentVault(payable(LibClone.clone(address(impl))));
        vault.initialize(
            address(positionManager),
            address(swapRouter),
            address(weth),
            address(alignmentToken),
            protocolTreasury,
            liquidityDeployer
        );
    }

    /// @dev Sets up vault LP position and mock fees for a standard harvest.
    ///      Handles both token orderings cleanly without MockERC20 casting of MockWETH.
    function _setupHarvestFees(uint256 alignmentFeeAmt, uint256 wethFeeAmt, bool _tokenIsZero) internal {
        vault.setPositionForTest(1, makeAddr("pool"), _tokenIsZero);

        if (_tokenIsZero) {
            // alignment=token0, weth=token1
            positionManager.setPosition(1, address(alignmentToken), address(weth), address(vault));
            if (alignmentFeeAmt > 0) alignmentToken.mint(address(positionManager), alignmentFeeAmt);
            if (wethFeeAmt > 0) weth.mint(address(positionManager), wethFeeAmt);
            positionManager.setFees(1, alignmentFeeAmt, wethFeeAmt);
        } else {
            // weth=token0, alignment=token1
            positionManager.setPosition(1, address(weth), address(alignmentToken), address(vault));
            if (wethFeeAmt > 0) weth.mint(address(positionManager), wethFeeAmt);
            if (alignmentFeeAmt > 0) alignmentToken.mint(address(positionManager), alignmentFeeAmt);
            positionManager.setFees(1, wethFeeAmt, alignmentFeeAmt);
        }

        if (alignmentFeeAmt > 0) {
            uint256 wethOut = alignmentFeeAmt * 9 / 10;
            weth.mint(address(swapRouter), wethOut);
            swapRouter.setRate(address(alignmentToken), address(weth), 0.9e18);
        }

        uint256 totalWETH = (alignmentFeeAmt > 0 ? alignmentFeeAmt * 9 / 10 : 0) + wethFeeAmt;
        if (totalWETH > 0) vm.deal(address(weth), totalWETH);
    }

    // ── Initialize tests ──────────────────────────────────────────────────

    function test_initialize_setsConfig() public view {
        assertEq(address(vault.positionManager()), address(positionManager));
        assertEq(vault.alignmentToken(), address(alignmentToken));
        assertEq(vault.liquidityDeployer(), liquidityDeployer);
        assertEq(vault.protocolYieldCutBps(), 100);
    }

    function test_initialize_revertIfCalledTwice() public {
        vm.expectRevert();
        vault.initialize(
            address(positionManager), address(swapRouter), address(weth),
            address(alignmentToken), protocolTreasury, liquidityDeployer
        );
    }

    // ── receiveContribution tests ─────────────────────────────────────────

    function test_receiveContribution_tracksETH() public {
        vm.deal(address(this), 2 ether);
        vault.receiveContribution{value: 2 ether}(Currency.wrap(address(0)), 2 ether, alice);
        assertEq(vault.benefactorContribution(alice), 2 ether);
        assertEq(vault.totalContributions(), 2 ether);
    }

    function test_receiveContribution_zeroValueIsNoOp() public {
        vault.receiveContribution(Currency.wrap(address(0)), 0, alice);
        assertEq(vault.benefactorContribution(alice), 0);
        assertEq(vault.totalContributions(), 0);
    }

    function test_receiveContribution_zeroBenefactorIsNoOp() public {
        vm.deal(address(this), 1 ether);
        vault.receiveContribution{value: 1 ether}(Currency.wrap(address(0)), 1 ether, address(0));
        assertEq(vault.totalContributions(), 0);
    }

    function test_receiveContribution_revertsOnNonEthCurrency() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert();
        vault.receiveContribution{value: 1 ether}(
            Currency.wrap(address(alignmentToken)), 1 ether, alice
        );
    }

    function test_receiveContribution_multipleSameBenefactor() public {
        vm.deal(address(this), 3 ether);
        vault.receiveContribution{value: 1 ether}(Currency.wrap(address(0)), 1 ether, alice);
        vault.receiveContribution{value: 2 ether}(Currency.wrap(address(0)), 2 ether, alice);
        assertEq(vault.benefactorContribution(alice), 3 ether);
        assertEq(vault.totalContributions(), 3 ether);
    }

    function test_receiveContribution_multipleBenefactors() public {
        vm.deal(address(this), 3 ether);
        vault.receiveContribution{value: 1 ether}(Currency.wrap(address(0)), 1 ether, alice);
        vault.receiveContribution{value: 2 ether}(Currency.wrap(address(0)), 2 ether, bob);
        assertEq(vault.benefactorContribution(alice), 1 ether);
        assertEq(vault.benefactorContribution(bob), 2 ether);
        assertEq(vault.totalContributions(), 3 ether);
    }

    // ── registerPosition tests ────────────────────────────────────────────

    function test_registerPosition_onlyLiquidityDeployer() public {
        vm.expectRevert();
        vault.registerPosition(1, makeAddr("pool"), true, alice, 1 ether);

        vm.prank(liquidityDeployer);
        vault.registerPosition(1, makeAddr("pool"), true, alice, 1 ether);
        assertEq(vault.benefactorContribution(alice), 1 ether);
        assertEq(vault.totalContributions(), 1 ether);
    }

    function test_registerPosition_revertsIfAlreadyRegistered() public {
        vm.prank(liquidityDeployer);
        vault.registerPosition(1, makeAddr("pool"), true, alice, 1 ether);

        vm.prank(liquidityDeployer);
        vm.expectRevert();
        vault.registerPosition(2, makeAddr("pool"), true, bob, 1 ether);
    }

    function test_registerPosition_setsLPState() public {
        address pool = makeAddr("pool");
        vm.prank(liquidityDeployer);
        vault.registerPosition(42, pool, false, alice, 5 ether);

        assertEq(vault.lpTokenId(), 42);
        assertEq(vault.lpPool(), pool);
        assertFalse(vault.tokenIsZero());
    }

    // ── harvest tests ─────────────────────────────────────────────────────

    function test_harvest_revertsWithZeroContributions() public {
        vault.setPositionForTest(1, makeAddr("pool"), true);
        vm.expectRevert();
        vault.harvest(0);
    }

    function test_harvest_revertsWithNoPosition() public {
        vm.deal(address(this), 1 ether);
        vault.receiveContribution{value: 1 ether}(Currency.wrap(address(0)), 1 ether, alice);
        // lpTokenId = 0 — no position registered
        vm.expectRevert();
        vault.harvest(0);
    }

    function test_harvest_returnsZeroWhenNoFees() public {
        vm.deal(address(this), 1 ether);
        vault.receiveContribution{value: 1 ether}(Currency.wrap(address(0)), 1 ether, alice);
        vault.setPositionForTest(1, makeAddr("pool"), true);
        // No fees set on position manager — collect returns (0, 0)
        uint256 returned = vault.harvest(0);
        assertEq(returned, 0);
        assertEq(vault.accRewardPerContribution(), 0);
    }

    function test_harvest_distributesFeesToBenefactors() public {
        vm.prank(liquidityDeployer);
        vault.registerPosition(1, makeAddr("pool"), true, alice, 1 ether);
        vault.setPositionForTest(1, makeAddr("pool"), true);

        positionManager.setPosition(1, address(alignmentToken), address(weth), address(vault));
        alignmentToken.mint(address(positionManager), 0.1e18);
        weth.mint(address(positionManager), 0.05e18);
        positionManager.setFees(1, 0.1e18, 0.05e18);

        weth.mint(address(swapRouter), 0.09e18);
        swapRouter.setRate(address(alignmentToken), address(weth), 0.9e18);
        vm.deal(address(weth), 0.14e18);

        uint256 aliceBalBefore = alice.balance;
        vault.harvest(0);

        assertGt(vault.accRewardPerContribution(), 0);
        assertGt(vault.calculateClaimableAmount(alice), 0);

        vm.prank(alice);
        vault.claimFees();
        assertGt(alice.balance, aliceBalBefore);
    }

    function test_harvest_tokenIsZeroFalse() public {
        // weth=token0, alignment=token1
        vm.deal(address(this), 1 ether);
        vault.receiveContribution{value: 1 ether}(Currency.wrap(address(0)), 1 ether, alice);

        uint256 wethFees = 0.05e18;
        uint256 alignmentFees = 0.1e18;
        _setupHarvestFees(alignmentFees, wethFees, false);

        uint256 expectedTotal = wethFees + (alignmentFees * 9 / 10);
        uint256 feesETH = vault.harvest(0);
        assertEq(feesETH, expectedTotal);
        assertGt(vault.accRewardPerContribution(), 0);
    }

    function test_harvest_takesProtocolCut() public {
        vm.deal(address(this), 1 ether);
        vault.receiveContribution{value: 1 ether}(Currency.wrap(address(0)), 1 ether, alice);
        _setupHarvestFees(0, 1 ether, true);

        vault.harvest(0);

        // 1% protocol cut of 1 ETH = 0.01 ETH
        assertEq(vault.accumulatedProtocolFees(), 0.01 ether);
        // Benefactors receive 99%
        assertEq(vault.calculateClaimableAmount(alice), 0.99 ether);
    }

    function test_harvest_multipleHarvestsAccumulate() public {
        vm.deal(address(this), 1 ether);
        vault.receiveContribution{value: 1 ether}(Currency.wrap(address(0)), 1 ether, alice);

        _setupHarvestFees(0, 0.1 ether, true);
        vault.harvest(0);
        uint256 accAfterFirst = vault.accRewardPerContribution();
        assertGt(accAfterFirst, 0);

        // Second harvest — position already set, just supply new fees
        weth.mint(address(positionManager), 0.1 ether);
        positionManager.setFees(1, 0, 0.1 ether);
        vm.deal(address(weth), 0.1 ether);
        vault.harvest(0);

        assertGt(vault.accRewardPerContribution(), accAfterFirst);
    }

    // ── claimFees tests ───────────────────────────────────────────────────

    function test_claimFees_returnsZeroWithNoContributions() public {
        vm.prank(alice);
        uint256 claimed = vault.claimFees();
        assertEq(claimed, 0);
    }

    function test_claimFees_returnsZeroWhenNothingPending() public {
        vm.deal(address(this), 1 ether);
        vault.receiveContribution{value: 1 ether}(Currency.wrap(address(0)), 1 ether, alice);
        _setupHarvestFees(0, 0.1 ether, true);
        vault.harvest(0);

        vm.prank(alice);
        vault.claimFees();

        // Second claim: nothing pending
        vm.prank(alice);
        uint256 secondClaim = vault.claimFees();
        assertEq(secondClaim, 0);
    }

    function test_claimFees_proportionalWithMultipleBenefactors() public {
        vm.deal(address(this), 30 ether);
        vault.receiveContribution{value: 10 ether}(Currency.wrap(address(0)), 10 ether, alice);
        vault.receiveContribution{value: 20 ether}(Currency.wrap(address(0)), 20 ether, bob);

        _setupHarvestFees(0, 1 ether, true);
        vault.harvest(0);

        // benefactorFees = 1 ETH * 99% = 0.99 ETH (integer arithmetic)
        // Alice: 10/30 = 1/3, Bob: 20/30 = 2/3
        uint256 benefactorFees = 1 ether * 9900 / 10000; // 0.99 ETH exact

        uint256 aliceClaimable = vault.calculateClaimableAmount(alice);
        uint256 bobClaimable = vault.calculateClaimableAmount(bob);

        assertApproxEqRel(aliceClaimable, benefactorFees / 3, 0.01e18);
        assertApproxEqRel(bobClaimable, benefactorFees * 2 / 3, 0.01e18);

        vm.prank(alice);
        uint256 aliceClaimed = vault.claimFees();
        assertApproxEqRel(aliceClaimed, benefactorFees / 3, 0.01e18);

        vm.prank(bob);
        uint256 bobClaimed = vault.claimFees();
        assertApproxEqRel(bobClaimed, benefactorFees * 2 / 3, 0.01e18);
    }

    function test_claimFees_multipleClaims_deltaTracking() public {
        vm.deal(address(this), 1 ether);
        vault.receiveContribution{value: 1 ether}(Currency.wrap(address(0)), 1 ether, alice);

        // First harvest: 0.1 ETH
        _setupHarvestFees(0, 0.1 ether, true);
        vault.harvest(0);

        vm.prank(alice);
        uint256 firstClaim = vault.claimFees();
        assertGt(firstClaim, 0);

        // Second harvest: 0.2 ETH (2x first)
        weth.mint(address(positionManager), 0.2 ether);
        positionManager.setFees(1, 0, 0.2 ether);
        vm.deal(address(weth), 0.2 ether);
        vault.harvest(0);

        vm.prank(alice);
        uint256 secondClaim = vault.claimFees();
        // Second claim should be ~2x first (2x the fees, same contribution)
        assertApproxEqRel(secondClaim, firstClaim * 2, 0.01e18);
    }

    // ── claimFeesAsDelegate tests ─────────────────────────────────────────

    function test_claimFeesAsDelegate_delegateReceivesFees() public {
        vm.deal(address(this), 1 ether);
        vault.receiveContribution{value: 1 ether}(Currency.wrap(address(0)), 1 ether, alice);

        vm.prank(alice);
        vault.delegateBenefactor(carol);

        _setupHarvestFees(0, 0.1 ether, true);
        vault.harvest(0);

        uint256 carolBefore = carol.balance;
        address[] memory benefactors = new address[](1);
        benefactors[0] = alice;

        vm.prank(carol);
        vault.claimFeesAsDelegate(benefactors);

        assertGt(carol.balance, carolBefore);
    }

    function test_claimFeesAsDelegate_revertsForNonDelegate() public {
        vm.deal(address(this), 1 ether);
        vault.receiveContribution{value: 1 ether}(Currency.wrap(address(0)), 1 ether, alice);

        _setupHarvestFees(0, 0.1 ether, true);
        vault.harvest(0);

        address[] memory benefactors = new address[](1);
        benefactors[0] = alice;

        vm.prank(bob); // not alice's delegate
        vm.expectRevert(CypherAlignmentVault.NotDelegate.selector);
        vault.claimFeesAsDelegate(benefactors);
    }

    // ── delegateBenefactor tests ──────────────────────────────────────────

    function test_delegateBenefactor_setsDelegate() public {
        vm.prank(alice);
        vault.delegateBenefactor(carol);
        assertEq(vault.getBenefactorDelegate(alice), carol);
    }

    function test_getBenefactorDelegate_returnsOwnAddressIfNoneSet() public view {
        assertEq(vault.getBenefactorDelegate(alice), alice);
    }

    function test_delegateBenefactor_claimGoesToDelegate() public {
        vm.deal(address(this), 1 ether);
        vault.receiveContribution{value: 1 ether}(Currency.wrap(address(0)), 1 ether, alice);

        vm.prank(alice);
        vault.delegateBenefactor(carol);

        _setupHarvestFees(0, 0.1 ether, true);
        vault.harvest(0);

        uint256 carolBefore = carol.balance;
        uint256 aliceBefore = alice.balance;

        vm.prank(alice);
        vault.claimFees(); // alice calls, but fees go to carol

        assertGt(carol.balance, carolBefore);
        assertEq(alice.balance, aliceBefore); // alice receives nothing
    }

    // ── withdrawProtocolFees tests ────────────────────────────────────────

    function test_withdrawProtocolFees_revertsIfNotTreasury() public {
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        vault.withdrawProtocolFees();
    }

    function test_withdrawProtocolFees_transfersToTreasury() public {
        vm.deal(address(this), 1 ether);
        vault.receiveContribution{value: 1 ether}(Currency.wrap(address(0)), 1 ether, alice);
        _setupHarvestFees(0, 1 ether, true);
        vault.harvest(0); // vault now holds 1 ETH, 0.01 ETH is protocol fees (1% default)

        uint256 treasuryBefore = protocolTreasury.balance;
        vm.prank(protocolTreasury);
        vault.withdrawProtocolFees();

        assertEq(protocolTreasury.balance - treasuryBefore, 0.01 ether);
        assertEq(vault.accumulatedProtocolFees(), 0);
    }

    // ── setProtocolYieldCutBps tests ──────────────────────────────────────

    function test_setProtocolYieldCutBps_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setProtocolYieldCutBps(1000);
    }

    function test_setProtocolYieldCutBps_revertsAboveMax() public {
        vm.expectRevert(CypherAlignmentVault.ExceedsMaxBps.selector);
        vault.setProtocolYieldCutBps(1001);
    }

    function test_setProtocolYieldCutBps_updatesValue() public {
        vault.setProtocolYieldCutBps(1000);
        assertEq(vault.protocolYieldCutBps(), 1000);
    }

    // ── calculateClaimableAmount tests ────────────────────────────────────

    function test_calculateClaimableAmount_returnsZeroWithNoContribution() public view {
        assertEq(vault.calculateClaimableAmount(alice), 0);
    }

    function test_calculateClaimableAmount_returnsZeroAfterClaim() public {
        vm.deal(address(this), 1 ether);
        vault.receiveContribution{value: 1 ether}(Currency.wrap(address(0)), 1 ether, alice);
        _setupHarvestFees(0, 0.1 ether, true);
        vault.harvest(0);

        vm.prank(alice);
        vault.claimFees();

        assertEq(vault.calculateClaimableAmount(alice), 0);
    }

    // ── supportsCapability tests ──────────────────────────────────────────

    function test_supportsCapability_yieldGeneration() public view {
        assertTrue(vault.supportsCapability(keccak256("YIELD_GENERATION")));
    }

    function test_supportsCapability_benefactorDelegation() public view {
        assertTrue(vault.supportsCapability(keccak256("BENEFACTOR_DELEGATION")));
    }

    function test_supportsCapability_unknownReturnsFalse() public view {
        assertFalse(vault.supportsCapability(keccak256("UNKNOWN_CAP")));
    }

    // ── View function tests ───────────────────────────────────────────────

    function test_vaultType_returnsCypherLP() public view {
        assertEq(vault.vaultType(), "CypherLP");
    }

    function test_totalShares_equalsTotalContributions() public {
        vm.prank(liquidityDeployer);
        vault.registerPosition(1, makeAddr("pool"), true, alice, 3 ether);
        assertEq(vault.totalShares(), 3 ether);
    }

    function test_getBenefactorContribution_returnsCorrectAmount() public {
        vm.deal(address(this), 5 ether);
        vault.receiveContribution{value: 5 ether}(Currency.wrap(address(0)), 5 ether, alice);
        assertEq(vault.getBenefactorContribution(alice), 5 ether);
    }

    function test_getBenefactorShares_equalsBenefactorContribution() public {
        vm.deal(address(this), 3 ether);
        vault.receiveContribution{value: 3 ether}(Currency.wrap(address(0)), 3 ether, alice);
        assertEq(vault.getBenefactorShares(alice), 3 ether);
    }

    // ── Integration tests ─────────────────────────────────────────────────

    function test_integration_fullWorkflow() public {
        // 1. Alice contributes
        vm.deal(address(this), 1 ether);
        vault.receiveContribution{value: 1 ether}(Currency.wrap(address(0)), 1 ether, alice);

        // 2. LP position goes live, harvest fees
        _setupHarvestFees(0, 1 ether, true);
        vault.harvest(0);

        // 3. Alice claims — should receive 99% of 1 ETH (1% protocol taken)
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        vault.claimFees();

        assertApproxEqRel(alice.balance - aliceBefore, 0.99 ether, 0.01e18);

        // 4. Protocol withdraws its cut
        uint256 treasuryBefore = protocolTreasury.balance;
        vm.prank(protocolTreasury);
        vault.withdrawProtocolFees();
        assertApproxEqRel(protocolTreasury.balance - treasuryBefore, 0.01 ether, 0.01e18);
    }

    function test_integration_multipleBenefactors_proportionalDistribution() public {
        vm.deal(address(this), 30 ether);
        vault.receiveContribution{value: 10 ether}(Currency.wrap(address(0)), 10 ether, alice);
        vault.receiveContribution{value: 20 ether}(Currency.wrap(address(0)), 20 ether, bob);

        // Harvest 3 ETH in fees
        _setupHarvestFees(0, 3 ether, true);
        vault.harvest(0);

        // benefactorFees = 3 ETH * 99% = 2.97 ETH
        uint256 benefactorFees = 3 ether * 9900 / 10000;

        vm.prank(alice);
        uint256 aliceClaimed = vault.claimFees();

        vm.prank(bob);
        uint256 bobClaimed = vault.claimFees();

        // Alice: 10/30 = 1/3, Bob: 20/30 = 2/3
        assertApproxEqRel(aliceClaimed, benefactorFees / 3, 0.01e18);
        assertApproxEqRel(bobClaimed, benefactorFees * 2 / 3, 0.01e18);
        assertApproxEqRel(aliceClaimed + bobClaimed, benefactorFees, 0.01e18);
    }

    function test_integration_multipleRoundsAndClaims() public {
        vm.deal(address(this), 30 ether);
        vault.receiveContribution{value: 10 ether}(Currency.wrap(address(0)), 10 ether, alice);
        vault.receiveContribution{value: 20 ether}(Currency.wrap(address(0)), 20 ether, bob);

        // Round 1: harvest 1 ETH
        _setupHarvestFees(0, 1 ether, true);
        vault.harvest(0);

        // Alice claims round 1
        vm.prank(alice);
        uint256 aliceR1 = vault.claimFees();
        assertGt(aliceR1, 0);

        // Round 2: harvest 2 ETH
        weth.mint(address(positionManager), 2 ether);
        positionManager.setFees(1, 0, 2 ether);
        vm.deal(address(weth), 2 ether);
        vault.harvest(0);

        // Bob claims both rounds at once
        vm.prank(bob);
        uint256 bobTotal = vault.claimFees();
        assertGt(bobTotal, 0);

        // Alice claims round 2 only
        vm.prank(alice);
        uint256 aliceR2 = vault.claimFees();
        assertGt(aliceR2, 0);
        // Round 2 fees are 2x, so alice's R2 should be ~2x her R1
        assertApproxEqRel(aliceR2, aliceR1 * 2, 0.01e18);
    }
}
