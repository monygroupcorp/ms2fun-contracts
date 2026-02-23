// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {UltraAlignmentVaultV2, IZAMM} from "../../src/vaults/UltraAlignmentVaultV2.sol";
import {MockZAMM} from "../mocks/MockZAMM.sol";
import {MockZRouter} from "../mocks/MockZRouter.sol";
import {MockEXECToken} from "../mocks/MockEXECToken.sol";
import {Currency} from "v4-core/types/Currency.sol";

contract UltraAlignmentVaultV2Test is Test {
    // Mirror events for expectEmit matching
    event ContributionReceived(address indexed benefactor, uint256 amount);
    event Harvested(uint256 totalFees, uint256 benefactorFees, uint256 callerReward);
    event VaultDeployed(address indexed vault, address indexed alignmentToken, address indexed creator);

    UltraAlignmentVaultV2 public vault;
    UltraAlignmentVaultV2 public impl;
    MockZAMM public mockZamm;
    MockZRouter public mockZRouter;
    MockEXECToken public alignmentToken;

    address public owner = address(0x1);
    address public treasury = address(0x99);
    address public creator = address(0xC1EA);
    address public alice = address(0x2);
    address public bob = address(0x3);
    address public charlie = address(0x4);

    IZAMM.PoolKey public poolKey;

    function setUp() public {
        alignmentToken = new MockEXECToken(1_000_000e18);
        mockZamm = new MockZAMM();
        mockZRouter = new MockZRouter();

        // Fund mocks
        vm.deal(address(mockZamm), 100 ether);
        vm.deal(address(mockZRouter), 100 ether);
        alignmentToken.transfer(address(mockZamm), 100_000e18);
        alignmentToken.transfer(address(mockZRouter), 100_000e18);

        poolKey = IZAMM.PoolKey({
            id0: 0,
            id1: 0,
            token0: address(0),          // ETH
            token1: address(alignmentToken),
            feeOrHook: 30                 // 0.3%
        });

        vm.prank(owner);
        impl = new UltraAlignmentVaultV2();

        vault = UltraAlignmentVaultV2(payable(LibClone.clone(address(impl))));
        vault.initialize(
            address(mockZamm),
            address(mockZRouter),
            address(alignmentToken),
            poolKey,
            creator,
            100, // 1% creator cut
            treasury
        );

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(charlie, 100 ether);
    }

    // ── Initialization ──────────────────────────────────────────────

    function test_initialize_setsConfig() public view {
        assertEq(vault.zamm(), address(mockZamm));
        assertEq(vault.zRouter(), address(mockZRouter));
        assertEq(vault.alignmentToken(), address(alignmentToken));
        assertEq(vault.factoryCreator(), creator);
        assertEq(vault.protocolTreasury(), treasury);
        assertEq(vault.protocolYieldCutBps(), 500);
        assertEq(vault.creatorYieldCutBps(), 100);
    }

    function test_initialize_locksPoolKey() public view {
        IZAMM.PoolKey memory k = vault.getPoolKey();
        assertEq(k.token0, address(0));
        assertEq(k.token1, address(alignmentToken));
        assertEq(k.feeOrHook, 30);
    }

    function test_initialize_revertIfCalledTwice() public {
        vm.expectRevert();
        vault.initialize(
            address(mockZamm),
            address(mockZRouter),
            address(alignmentToken),
            poolKey,
            creator,
            100,
            treasury
        );
    }

    function test_initialize_revertIfCreatorCutExceeds500() public {
        UltraAlignmentVaultV2 v2 = UltraAlignmentVaultV2(payable(LibClone.clone(address(impl))));
        vm.expectRevert();
        v2.initialize(
            address(mockZamm),
            address(mockZRouter),
            address(alignmentToken),
            poolKey,
            creator,
            501, // over max
            treasury
        );
    }

    // ── receiveInstance ──────────────────────────────────────────────

    function test_receiveInstance_tracksPending() public {
        vm.prank(alice);
        vault.receiveInstance{value: 1 ether}(Currency.wrap(address(0)), 1 ether, alice);

        assertEq(vault.pendingETH(), 1 ether);
        assertEq(vault.pendingContribution(alice), 1 ether);
    }

    function test_receiveInstance_accumulatesMultiple() public {
        vm.prank(alice);
        vault.receiveInstance{value: 1 ether}(Currency.wrap(address(0)), 1 ether, alice);

        vm.prank(bob);
        vault.receiveInstance{value: 2 ether}(Currency.wrap(address(0)), 2 ether, bob);

        assertEq(vault.pendingETH(), 3 ether);
        assertEq(vault.pendingContribution(alice), 1 ether);
        assertEq(vault.pendingContribution(bob), 2 ether);
    }

    function test_receiveInstance_emitsContributionReceived() public {
        vm.expectEmit(true, false, false, true);
        emit ContributionReceived(alice, 1 ether);

        vm.prank(alice);
        vault.receiveInstance{value: 1 ether}(Currency.wrap(address(0)), 1 ether, alice);
    }

    function test_receiveInstance_revertOnNonEthCurrency() public {
        vm.expectRevert();
        vm.prank(alice);
        vault.receiveInstance{value: 0}(
            Currency.wrap(address(alignmentToken)),
            1 ether,
            alice
        );
    }

    function test_receive_tracksSenderAsBenefactor() public {
        vm.prank(alice);
        (bool ok,) = address(vault).call{value: 0.5 ether}("");
        assertTrue(ok);
        assertEq(vault.pendingContribution(alice), 0.5 ether);
    }

    // ── convertAndAddLiquidity ────────────────────────────────────────────

    function _receiveFromAlice(uint256 amount) internal {
        vm.prank(alice);
        vault.receiveInstance{value: amount}(Currency.wrap(address(0)), amount, alice);
    }

    function _setupPool(uint112 r0, uint112 r1) internal {
        uint256 pid = vault.poolId();
        mockZamm.setPool(pid, r0, r1, 0);
    }

    function test_convertAndAddLiquidity_mintsLP() public {
        _receiveFromAlice(1 ether);
        _setupPool(10 ether, 10_000e18);

        uint256 lpBefore = mockZamm.lpBalances(address(vault), vault.poolId());
        vault.convertAndAddLiquidity(0, 0, 0);
        uint256 lpAfter = mockZamm.lpBalances(address(vault), vault.poolId());

        assertGt(lpAfter, lpBefore, "LP should increase");
    }

    function test_convertAndAddLiquidity_clearsPending() public {
        _receiveFromAlice(2 ether);
        _setupPool(10 ether, 10_000e18);

        vault.convertAndAddLiquidity(0, 0, 0);

        assertEq(vault.pendingETH(), 0);
        assertEq(vault.pendingContribution(alice), 0);
    }

    function test_convertAndAddLiquidity_tracksBenefactorContribution() public {
        _receiveFromAlice(1 ether);

        vm.prank(bob);
        vault.receiveInstance{value: 3 ether}(Currency.wrap(address(0)), 3 ether, bob);

        _setupPool(10 ether, 10_000e18);
        vault.convertAndAddLiquidity(0, 0, 0);

        uint256 aliceContrib = vault.benefactorContribution(alice);
        uint256 bobContrib = vault.benefactorContribution(bob);
        // Alice contributed 1/4, Bob contributed 3/4
        assertEq(aliceContrib * 3, bobContrib, "proportions wrong");
    }

    function test_convertAndAddLiquidity_growsPrincipal() public {
        _receiveFromAlice(1 ether);
        _setupPool(10 ether, 10_000e18);

        vault.convertAndAddLiquidity(0, 0, 0);

        assertGt(vault.principalETH(), 0, "principalETH should grow");
        assertGt(vault.principalToken(), 0, "principalToken should grow");
    }

    function test_convertAndAddLiquidity_revertIfNoPending() public {
        vm.expectRevert();
        vault.convertAndAddLiquidity(0, 0, 0);
    }

    function test_convertAndAddLiquidity_paysCallerReward() public {
        _receiveFromAlice(10 ether);
        _setupPool(10 ether, 10_000e18);

        // Set a non-zero conversion reward
        vm.prank(vault.owner());
        vault.setConversionReward(0.01 ether);

        address caller = address(0xCAFE);
        vm.deal(caller, 0);
        vm.prank(caller);
        vault.convertAndAddLiquidity(0, 0, 0);

        assertEq(caller.balance, 0.01 ether, "caller should receive reward");
    }

    // ── harvest ───────────────────────────────────────────────────────────

    function _setupWithLiquidity() internal {
        _receiveFromAlice(4 ether);
        _setupPool(10 ether, 10_000e18);
        vault.convertAndAddLiquidity(0, 0, 0);
    }

    function test_harvest_updatesAccumulator() public {
        _setupWithLiquidity();

        uint256 accBefore = vault.accRewardPerContribution();

        // Simulate fee accrual: set ethPerLp so removeLiquidity returns more than principal
        mockZamm.setEthPerLp(0.002 ether); // returns 2x
        mockZamm.setTokenPerLp(0.002 ether);

        vault.harvest(0);

        assertGt(vault.accRewardPerContribution(), accBefore, "accumulator should grow");
    }

    function test_harvest_paysCallerReward() public {
        _setupWithLiquidity();

        vm.prank(vault.owner());
        vault.setHarvestReward(0.005 ether);

        vm.deal(address(mockZamm), 10 ether);
        mockZamm.setEthPerLp(0.002 ether);

        address caller = address(0xBEEF);
        vm.deal(caller, 0);
        vm.prank(caller);
        vault.harvest(0);

        assertEq(caller.balance, 0.005 ether);
    }

    function test_harvest_emitsFeesAccumulated() public {
        _setupWithLiquidity();
        mockZamm.setEthPerLp(0.002 ether);
        mockZamm.setTokenPerLp(0.002 ether);
        vm.deal(address(mockZRouter), 10 ether);
        alignmentToken.transfer(address(mockZamm), 50_000e18);

        vm.expectEmit(false, false, false, false);
        emit Harvested(0, 0, 0); // values ignored, just check event fires
        vault.harvest(0);
    }

    // ── claimFees + delegation ────────────────────────────────────────────

    function _triggerHarvestWithFees() internal {
        mockZamm.setEthPerLp(0.002 ether);
        mockZamm.setTokenPerLp(0.002 ether);
        vm.deal(address(mockZamm), 10 ether);
        vm.deal(address(mockZRouter), 10 ether);
        alignmentToken.transfer(address(mockZamm), 50_000e18);
        vault.harvest(0);
    }

    function test_claimFees_transfersEth() public {
        _setupWithLiquidity();
        _triggerHarvestWithFees();

        uint256 balBefore = alice.balance;
        vm.prank(alice);
        uint256 claimed = vault.claimFees();

        assertGt(claimed, 0, "should claim nonzero");
        assertEq(alice.balance - balBefore, claimed);
    }

    function test_claimFees_updatesRewardDebt() public {
        _setupWithLiquidity();
        _triggerHarvestWithFees();

        vm.prank(alice);
        vault.claimFees();

        // Second claim should return 0
        vm.prank(alice);
        uint256 secondClaim = vault.claimFees();
        assertEq(secondClaim, 0);
    }

    function test_calculateClaimableAmount_matchesClaim() public {
        _setupWithLiquidity();
        _triggerHarvestWithFees();

        uint256 pending = vault.calculateClaimableAmount(alice);
        assertGt(pending, 0);

        vm.prank(alice);
        uint256 claimed = vault.claimFees();
        assertEq(pending, claimed);
    }

    function test_delegation_routesYieldToDelegate() public {
        _setupWithLiquidity();

        // Alice delegates to a staking contract
        address stakingContract = address(0xBEEF);
        vm.prank(alice);
        vault.delegateBenefactor(stakingContract);

        assertEq(vault.getBenefactorDelegate(alice), stakingContract);

        _triggerHarvestWithFees();

        uint256 balBefore = stakingContract.balance;
        vm.prank(alice);
        vault.claimFees();

        assertGt(stakingContract.balance - balBefore, 0, "delegate should receive ETH");
    }

    function test_claimFeesAsDelegate_batchClaim() public {
        // Bob and Charlie both receive from alice (as benefactors)
        vm.prank(bob);
        vault.receiveInstance{value: 2 ether}(Currency.wrap(address(0)), 2 ether, bob);
        vm.prank(charlie);
        vault.receiveInstance{value: 2 ether}(Currency.wrap(address(0)), 2 ether, charlie);

        _setupPool(10 ether, 10_000e18);
        vault.convertAndAddLiquidity(0, 0, 0);

        // Both delegate to a staking contract
        address staking = address(0xDEAD);
        vm.prank(bob); vault.delegateBenefactor(staking);
        vm.prank(charlie); vault.delegateBenefactor(staking);

        _triggerHarvestWithFees();

        address[] memory benefactors = new address[](2);
        benefactors[0] = bob;
        benefactors[1] = charlie;

        uint256 balBefore = staking.balance;
        vm.prank(staking);
        uint256 total = vault.claimFeesAsDelegate(benefactors);

        assertGt(total, 0);
        assertEq(staking.balance - balBefore, total);
    }

    function test_claimFeesAsDelegate_revertIfNotDelegate() public {
        vm.prank(alice);
        vault.receiveInstance{value: 1 ether}(Currency.wrap(address(0)), 1 ether, alice);
        _setupPool(10 ether, 10_000e18);
        vault.convertAndAddLiquidity(0, 0, 0);

        address[] memory benefactors = new address[](1);
        benefactors[0] = alice;

        vm.expectRevert();
        vm.prank(bob); // bob is not alice's delegate
        vault.claimFeesAsDelegate(benefactors);
    }

    // ── Governance ────────────────────────────────────────────────────────

    function test_setProtocolYieldCutBps_ownerOnly() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setProtocolYieldCutBps(300);

        vm.prank(vault.owner());
        vault.setProtocolYieldCutBps(300);
        assertEq(vault.protocolYieldCutBps(), 300);
    }

    function test_setProtocolTreasury_ownerOnly() public {
        address newTreasury = address(0xABCD);
        vm.prank(vault.owner());
        vault.setProtocolTreasury(newTreasury);
        assertEq(vault.protocolTreasury(), newTreasury);
    }

    function test_withdrawProtocolFees_sendToTreasury() public {
        _setupWithLiquidity();
        _triggerHarvestWithFees();

        uint256 treasuryBefore = treasury.balance;
        vault.withdrawProtocolFees();
        assertGt(treasury.balance - treasuryBefore, 0);
        assertEq(vault.accumulatedProtocolFees(), 0);
    }

    function test_transferFactoryCreator_twoStep() public {
        address newCreator = address(0xCCCC);
        vm.prank(creator);
        vault.transferFactoryCreator(newCreator);
        assertEq(vault.pendingFactoryCreator(), newCreator);

        vm.prank(newCreator);
        vault.acceptFactoryCreator();
        assertEq(vault.factoryCreator(), newCreator);
    }

    function test_withdrawCreatorFees() public {
        _setupWithLiquidity();
        _triggerHarvestWithFees();

        uint256 before = creator.balance;
        vm.prank(creator);
        vault.withdrawCreatorFees();
        assertGt(creator.balance - before, 0);
    }
}
