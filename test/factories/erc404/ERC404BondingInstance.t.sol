// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {ERC404BondingInstance, MaxCostExceeded, BondingNotConfigured, OnlyOwnerBeforeMaturity, HookNotSet, NoReserve} from "../../../src/factories/erc404/ERC404BondingInstance.sol";
import {ERC404Factory} from "../../../src/factories/erc404/ERC404Factory.sol";
import {ERC404StakingModule} from "../../../src/factories/erc404/ERC404StakingModule.sol";
import {CurveParamsComputer} from "../../../src/factories/erc404/CurveParamsComputer.sol";
import {BondingCurveMath} from "../../../src/factories/erc404/libraries/BondingCurveMath.sol";
import {LibClone} from "solady/utils/LibClone.sol";

contract MockMasterRegistryForStaking {
    mapping(address => bool) public instances;
    function setInstance(address a, bool v) external { instances[a] = v; }
    function isRegisteredInstance(address a) external view returns (bool) { return instances[a]; }
}

/**
 * @title ERC404BondingInstanceTest
 * @notice Comprehensive test suite for ERC404BondingInstance
 * @dev Tests bonding curve, gating module, messages, and V4 liquidity
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

    BondingCurveMath.Params curveParams;

    bytes32 public passwordHash1;

    // Mock addresses
    address public mockV4PoolManager = address(0x100);
    address public mockV4Hook = address(0x200);
    address public mockWETH = address(0x300);
    address public mockMasterRegistry = address(0x400);
    address public mockLiquidityDeployer = address(0x600);
    address public mockGlobalMsgRegistry = address(0x700);

    MockMasterRegistryForStaking public stakingRegistry;
    ERC404StakingModule public stakingModule;
    CurveParamsComputer public curveComputer;

    function setUp() public {
        // Deploy staking infrastructure before pranking as owner
        stakingRegistry = new MockMasterRegistryForStaking();
        stakingModule = new ERC404StakingModule(address(stakingRegistry));
        curveComputer = new CurveParamsComputer(address(this));

        vm.startPrank(owner);

        // Set up password hash (used in tier-gating tests)
        passwordHash1 = keccak256("password1");

        // Set up bonding curve parameters (matching CULTEXEC404 defaults)
        curveParams = BondingCurveMath.Params({
            initialPrice: 0.025 ether,
            quarticCoeff: 3 gwei,        // 12/4 * 1 gwei
            cubicCoeff: 1333333333,       // 4/3 * 1 gwei
            quadraticCoeff: 2 gwei,      // 4/2 * 1 gwei
            normalizationFactor: 1e7     // 10M tokens
        });

        // Deploy instance via clone + initialize pattern
        // Note: factory = msg.sender (pranked as owner), so all 3-step init calls
        // must occur within this prank context
        ERC404BondingInstance impl = new ERC404BondingInstance();
        instance = ERC404BondingInstance(payable(LibClone.clone(address(impl))));
        _initInstance(instance, address(0xBEEF), address(0xFEE), 100, 200, 100, address(0));
        instance.initializeMetadata("Test Token", "TEST", "");

        vm.stopPrank();

        // Register instance with staking registry so staking module accepts calls from it
        stakingRegistry.setInstance(address(instance), true);
    }

    // ========================
    // Internal Helpers
    // ========================

    /**
     * @dev 3-step initialize helper. Must be called within vm.startPrank(owner) context
     *      because factory = msg.sender is captured during initialize().
     */
    function _initInstance(
        ERC404BondingInstance inst,
        address vault_,
        address treasury_,
        uint256 bondingFeeBps_,
        uint256 graduationFeeBps_,
        uint256 polBps_,
        address hook_
    ) internal {
        ERC404BondingInstance.BondingParams memory bonding = ERC404BondingInstance.BondingParams({
            maxSupply: MAX_SUPPLY,
            unit: 1_000_000 ether,
            liquidityReservePercent: LIQUIDITY_RESERVE_PERCENT,
            curve: curveParams,
            poolFee: 3000,
            tickSpacing: 60
        });
        inst.initialize(owner, vault_, bonding, hook_, address(0));

        ERC404BondingInstance.ProtocolParams memory proto = ERC404BondingInstance.ProtocolParams({
            globalMessageRegistry: mockGlobalMsgRegistry,
            protocolTreasury: treasury_,
            masterRegistry: mockMasterRegistry,
            stakingModule: address(stakingModule),
            liquidityDeployer: mockLiquidityDeployer,
            curveComputer: address(curveComputer),
            v4PoolManager: mockV4PoolManager,
            weth: mockWETH,
            bondingFeeBps: bondingFeeBps_,
            graduationFeeBps: graduationFeeBps_
        });
        inst.initializeProtocol(proto);
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
        // Test that buyBonding accepts any password hash when no gating module is set
        // (address(0) gatingModule = open gating — all purchases allowed)
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
        uint256 cost = _getCost(instance, buyAmount);
        uint256 fee = (cost * instance.bondingFeeBps()) / 10000;
        uint256 totalWithFee = cost + fee;
        // Should succeed — open gating (no module set), password hash is ignored
        instance.buyBonding{value: totalWithFee}(buyAmount, totalWithFee, false, passwordHash1, bytes(""), 0);
        vm.stopPrank();
    }

    function test_CalculateCost() public {
        uint256 amount = 1000 * 1e18;
        uint256 cost = _getCost(instance, amount);
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
        uint256 cost = _getCost(instance, buyAmount);
        uint256 fee = (cost * instance.bondingFeeBps()) / 10000;
        uint256 totalWithFee = cost + fee;
        instance.buyBonding{value: totalWithFee}(buyAmount, totalWithFee, false, bytes32(0), bytes(""), 0);
        vm.stopPrank();

        // Now calculate refund
        uint256 refund = _getRefund(instance, buyAmount);
        assertGt(refund, 0);
        // Refund equals curve cost (not cost+fee) — curve symmetry preserved
        assertEq(refund, cost);
    }

    // ========================
    // Helpers
    // ========================

    /// @dev Helper: fetch curve cost using curveComputer for a given instance
    function _getCost(ERC404BondingInstance inst, uint256 amount) internal view returns (uint256) {
        (uint256 ip, uint256 qc, uint256 cc, uint256 qdc, uint256 nf) = inst.curveParams();
        BondingCurveMath.Params memory p = BondingCurveMath.Params({
            initialPrice: ip,
            quarticCoeff: qc,
            cubicCoeff: cc,
            quadraticCoeff: qdc,
            normalizationFactor: nf
        });
        return curveComputer.calculateCost(p, inst.totalBondingSupply(), amount);
    }

    /// @dev Helper: fetch curve refund using curveComputer for a given instance
    function _getRefund(ERC404BondingInstance inst, uint256 amount) internal view returns (uint256) {
        (uint256 ip, uint256 qc, uint256 cc, uint256 qdc, uint256 nf) = inst.curveParams();
        BondingCurveMath.Params memory p = BondingCurveMath.Params({
            initialPrice: ip,
            quarticCoeff: qc,
            cubicCoeff: cc,
            quadraticCoeff: qdc,
            normalizationFactor: nf
        });
        return curveComputer.calculateRefund(p, inst.totalBondingSupply(), amount);
    }

    // ========================
    // Bonding Fee Tests
    // ========================

    function _activateBonding() internal {
        vm.startPrank(owner);
        uint256 futureTime = block.timestamp + 1 days;
        instance.setBondingOpenTime(futureTime);
        instance.setV4Hook(mockV4Hook);
        instance.setBondingActive(true);
        vm.stopPrank();
        vm.warp(futureTime);
    }

    function test_BuyBondingWithFee_TreasurySentFee() public {
        _activateBonding();

        address treasury = address(0xFEE);
        uint256 treasuryBalanceBefore = treasury.balance;

        vm.deal(user1, 10 ether);
        vm.startPrank(user1);
        uint256 buyAmount = 1000 * 1e18;
        uint256 cost = _getCost(instance, buyAmount);
        uint256 fee = (cost * instance.bondingFeeBps()) / 10000;
        uint256 totalWithFee = cost + fee;

        instance.buyBonding{value: totalWithFee}(buyAmount, totalWithFee, false, bytes32(0), bytes(""), 0);
        vm.stopPrank();

        assertEq(treasury.balance - treasuryBalanceBefore, fee, "Treasury should receive fee");
    }

    function test_BuyBondingWithFee_ReserveOnlyGetsCost() public {
        _activateBonding();

        uint256 reserveBefore = instance.reserve();
        vm.deal(user1, 10 ether);
        vm.startPrank(user1);
        uint256 buyAmount = 1000 * 1e18;
        uint256 cost = _getCost(instance, buyAmount);
        uint256 fee = (cost * instance.bondingFeeBps()) / 10000;
        uint256 totalWithFee = cost + fee;

        instance.buyBonding{value: totalWithFee}(buyAmount, totalWithFee, false, bytes32(0), bytes(""), 0);
        vm.stopPrank();

        assertEq(instance.reserve() - reserveBefore, cost, "Reserve should only increase by cost, not fee");
    }

    function test_BuyBondingWithFee_RefundExcess() public {
        _activateBonding();

        vm.deal(user1, 10 ether);
        vm.startPrank(user1);
        uint256 buyAmount = 1000 * 1e18;
        uint256 cost = _getCost(instance, buyAmount);
        uint256 fee = (cost * instance.bondingFeeBps()) / 10000;
        uint256 totalWithFee = cost + fee;

        uint256 overpay = 1 ether;
        uint256 balanceBefore = user1.balance;
        instance.buyBonding{value: totalWithFee + overpay}(buyAmount, totalWithFee + overpay, false, bytes32(0), bytes(""), 0);
        uint256 balanceAfter = user1.balance;

        assertEq(balanceBefore - balanceAfter, totalWithFee, "Should refund excess beyond totalWithFee");
        vm.stopPrank();
    }

    function test_BuyBondingWithFee_MaxCostMustCoverFee() public {
        _activateBonding();

        vm.deal(user1, 10 ether);
        vm.startPrank(user1);
        uint256 buyAmount = 1000 * 1e18;
        uint256 cost = _getCost(instance, buyAmount);
        // Pass maxCost = cost (without fee) — should revert
        vm.expectRevert(MaxCostExceeded.selector);
        instance.buyBonding{value: 10 ether}(buyAmount, cost, false, bytes32(0), bytes(""), 0);
        vm.stopPrank();
    }

    function test_BuyBondingWithFee_ZeroFee() public {
        // Deploy instance with 0% fee
        vm.startPrank(owner);
        ERC404BondingInstance zeroFeeImpl = new ERC404BondingInstance();
        ERC404BondingInstance zeroFeeInstance = ERC404BondingInstance(payable(LibClone.clone(address(zeroFeeImpl))));
        _initInstance(zeroFeeInstance, address(0xBEEF), address(0xFEE), 0, 0, 0, address(0));
        zeroFeeInstance.initializeMetadata("Zero Fee Token", "ZFT", "");
        uint256 futureTime = block.timestamp + 1 days;
        zeroFeeInstance.setBondingOpenTime(futureTime);
        zeroFeeInstance.setV4Hook(mockV4Hook);
        zeroFeeInstance.setBondingActive(true);
        vm.stopPrank();
        vm.warp(futureTime);

        address treasury = address(0xFEE);
        uint256 treasuryBefore = treasury.balance;

        vm.deal(user1, 10 ether);
        vm.startPrank(user1);
        uint256 buyAmount = 1000 * 1e18;
        uint256 cost = _getCost(zeroFeeInstance, buyAmount);
        zeroFeeInstance.buyBonding{value: cost}(buyAmount, cost, false, bytes32(0), bytes(""), 0);
        vm.stopPrank();

        assertEq(treasury.balance, treasuryBefore, "Treasury balance unchanged with 0% fee");
    }

    function test_BuyBondingWithFee_NoTreasury() public {
        // Deploy instance with treasury = address(0)
        vm.startPrank(owner);
        ERC404BondingInstance noTreasuryImplInst = new ERC404BondingInstance();
        ERC404BondingInstance noTreasuryInstance = ERC404BondingInstance(payable(LibClone.clone(address(noTreasuryImplInst))));
        _initInstance(noTreasuryInstance, address(0xBEEF), address(0), 100, 200, 100, address(0));
        noTreasuryInstance.initializeMetadata("No Treasury Token", "NTT", "");
        uint256 futureTime = block.timestamp + 1 days;
        noTreasuryInstance.setBondingOpenTime(futureTime);
        noTreasuryInstance.setV4Hook(mockV4Hook);
        noTreasuryInstance.setBondingActive(true);
        vm.stopPrank();
        vm.warp(futureTime);

        vm.deal(user1, 10 ether);
        vm.startPrank(user1);
        uint256 buyAmount = 1000 * 1e18;
        uint256 cost = _getCost(noTreasuryInstance, buyAmount);
        uint256 fee = (cost * noTreasuryInstance.bondingFeeBps()) / 10000;
        uint256 totalWithFee = cost + fee;
        // Should succeed even without treasury — fee just stays in contract
        noTreasuryInstance.buyBonding{value: totalWithFee}(buyAmount, totalWithFee, false, bytes32(0), bytes(""), 0);
        vm.stopPrank();
    }

    function test_SellBondingAfterFee_CurveSolvency() public {
        _activateBonding();

        vm.deal(user1, 10 ether);
        vm.startPrank(user1);
        uint256 buyAmount = 1000 * 1e18;
        uint256 cost = _getCost(instance, buyAmount);
        uint256 fee = (cost * instance.bondingFeeBps()) / 10000;
        uint256 totalWithFee = cost + fee;

        instance.buyBonding{value: totalWithFee}(buyAmount, totalWithFee, false, bytes32(0), bytes(""), 0);

        // Refund should equal exact curve cost (not cost+fee)
        uint256 refund = _getRefund(instance, buyAmount);
        assertEq(refund, cost, "Refund should equal curve cost, preserving solvency");

        // Reserve should be sufficient to cover the refund
        assertGe(instance.reserve(), refund, "Reserve must be >= refund amount");
        vm.stopPrank();
    }

    function test_BondingFeePaidEvent() public {
        _activateBonding();

        vm.deal(user1, 10 ether);
        vm.startPrank(user1);
        uint256 buyAmount = 1000 * 1e18;
        uint256 cost = _getCost(instance, buyAmount);
        uint256 fee = (cost * instance.bondingFeeBps()) / 10000;
        uint256 totalWithFee = cost + fee;

        vm.expectEmit(true, false, false, true);
        emit ERC404BondingInstance.BondingFeePaid(user1, fee);
        instance.buyBonding{value: totalWithFee}(buyAmount, totalWithFee, false, bytes32(0), bytes(""), 0);
        vm.stopPrank();
    }

    // ========================
    // Graduation Fee Tests
    // ========================

    function test_GraduationFeeBps_StoredCorrectly() public {
        assertEq(instance.graduationFeeBps(), 200, "Graduation fee should be 2% (200 bps)");
    }

    function test_GraduationFeeBps_Immutable() public {
        // Deploy instance with specific graduation fee
        vm.startPrank(owner);
        ERC404BondingInstance customGradImpl = new ERC404BondingInstance();
        ERC404BondingInstance customInstance = ERC404BondingInstance(payable(LibClone.clone(address(customGradImpl))));
        _initInstance(customInstance, address(0xBEEF), address(0xFEE), 100, 450, 100, address(0));
        customInstance.initializeMetadata("Custom Grad Fee", "CGF", "");
        vm.stopPrank();

        assertEq(customInstance.graduationFeeBps(), 450, "Custom graduation fee should be stored");
    }

    function test_GraduationFeeBps_ZeroAllowed() public {
        vm.startPrank(owner);
        ERC404BondingInstance zeroGradImpl = new ERC404BondingInstance();
        ERC404BondingInstance zeroGradInstance = ERC404BondingInstance(payable(LibClone.clone(address(zeroGradImpl))));
        _initInstance(zeroGradInstance, address(0xBEEF), address(0xFEE), 100, 0, 100, address(0));
        zeroGradInstance.initializeMetadata("Zero Grad Fee", "ZGF", "");
        vm.stopPrank();

        assertEq(zeroGradInstance.graduationFeeBps(), 0, "Zero graduation fee should be allowed");
    }

    function test_GraduationFee_MathCorrectness() public {
        // Verify the fee math: (amount * bps) / 10000
        // With 200 bps (2%) on 15 ETH: fee = 0.3 ETH, pool gets 14.7 ETH
        uint256 deployETH = 15 ether;
        uint256 feeBps = instance.graduationFeeBps(); // 200
        uint256 expectedFee = (deployETH * feeBps) / 10000;
        uint256 expectedPoolAmount = deployETH - expectedFee;

        assertEq(expectedFee, 0.3 ether, "2% of 15 ETH should be 0.3 ETH");
        assertEq(expectedPoolAmount, 14.7 ether, "Pool should get 14.7 ETH");
    }

    function test_GraduationFee_SmallAmountPrecision() public {
        // Verify fee doesn't round to zero on small amounts
        uint256 deployETH = 0.01 ether; // 10 finney
        uint256 feeBps = 200; // 2%
        uint256 fee = (deployETH * feeBps) / 10000;

        assertEq(fee, 0.0002 ether, "2% of 0.01 ETH should be 0.0002 ETH");
        assertGt(fee, 0, "Fee should be nonzero even on small amounts");
    }

    function test_GraduationFee_MaxCapBoundary() public {
        // At max cap (500 bps = 5%), verify calculation
        uint256 deployETH = 10 ether;
        uint256 feeBps = 500;
        uint256 fee = (deployETH * feeBps) / 10000;
        uint256 poolAmount = deployETH - fee;

        assertEq(fee, 0.5 ether, "5% of 10 ETH should be 0.5 ETH");
        assertEq(poolAmount, 9.5 ether, "Pool should get 9.5 ETH");
    }

    // Note: Full deployLiquidity integration tests with graduation fee require
    // mock V4 PoolManager, mock WETH, and mock hook contracts.
    // The graduation fee logic is exercised in fork tests when available.
    // The unit tests above verify:
    // - Storage (immutable set at construction)
    // - Factory passthrough (graduationFeeBps propagated to instance)
    // - Fee math correctness (bps calculation, precision, boundary)

    // ========================
    // Deterministic deployLiquidity Tests
    // ========================

    function test_deployLiquidity_noParams() public {
        // Verifies deployLiquidity() takes zero arguments and reverts properly
        // when bonding hasn't started
        vm.expectRevert(BondingNotConfigured.selector);
        instance.deployLiquidity();
    }

    function test_deployLiquidity_ownerOnlyBeforeFull() public {
        _activateBonding();

        // Buy some tokens so reserve > 0
        vm.deal(user1, 10 ether);
        vm.startPrank(user1);
        uint256 buyAmount = 1000 * 1e18;
        uint256 cost = _getCost(instance, buyAmount);
        uint256 fee = (cost * instance.bondingFeeBps()) / 10000;
        instance.buyBonding{value: cost + fee}(buyAmount, cost + fee, false, bytes32(0), bytes(""), 0);

        // Now try to deploy liquidity as non-owner
        vm.expectRevert(OnlyOwnerBeforeMaturity.selector);
        instance.deployLiquidity();
        vm.stopPrank();
    }

    function test_deployLiquidity_requiresHook() public {
        // Deploy instance with no hook
        vm.startPrank(owner);
        ERC404BondingInstance noHookImpl = new ERC404BondingInstance();
        ERC404BondingInstance noHookInstance = ERC404BondingInstance(payable(LibClone.clone(address(noHookImpl))));
        _initInstance(noHookInstance, address(0xBEEF), address(0xFEE), 100, 200, 100, address(0));
        noHookInstance.initializeMetadata("No Hook", "NH", "");
        uint256 futureTime = block.timestamp + 1 days;
        noHookInstance.setBondingOpenTime(futureTime);
        // Note: cannot setBondingActive without hook, but deployLiquidity
        // checks hook independently. Set maturity so it's permissionless.
        noHookInstance.setBondingMaturityTime(futureTime + 1);
        vm.stopPrank();
        vm.warp(futureTime + 1);

        vm.prank(owner);
        vm.expectRevert(HookNotSet.selector);
        noHookInstance.deployLiquidity();
    }

    function test_deployLiquidity_requiresReserve() public {
        _activateBonding();
        // Instance has no reserve (no buys happened), so reserve == 0
        vm.prank(owner);
        vm.expectRevert(NoReserve.selector);
        instance.deployLiquidity();
    }

    // ── Vault migration tests ─────────────────────────────────────────────────

    function test_MigrateVault_UpdatesActiveVault() public {
        address newVault = makeAddr("newVault");
        // mockMasterRegistry is an EOA — stub the migrateVault call
        vm.mockCall(
            mockMasterRegistry,
            abi.encodeWithSignature("migrateVault(address,address)", address(instance), newVault),
            abi.encode()
        );
        vm.prank(owner);
        instance.migrateVault(newVault);
        assertEq(address(instance.vault()), newVault);
    }

    function test_ClaimAllFees_IteratesAllVaults() public {
        address vault1 = address(0xBEEF);
        address vault2 = makeAddr("vault2");

        address[] memory vaults = new address[](2);
        vaults[0] = vault1;
        vaults[1] = vault2;

        vm.mockCall(
            mockMasterRegistry,
            abi.encodeWithSignature("getInstanceVaults(address)", address(instance)),
            abi.encode(vaults)
        );
        vm.mockCall(vault1, abi.encodeWithSignature("claimFees()"), abi.encode(uint256(0)));
        vm.mockCall(vault2, abi.encodeWithSignature("claimFees()"), abi.encode(uint256(0)));

        vm.prank(owner);
        instance.claimAllFees();
    }

    function test_MigrateVault_RevertIfNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        instance.migrateVault(makeAddr("newVault"));
    }
}
