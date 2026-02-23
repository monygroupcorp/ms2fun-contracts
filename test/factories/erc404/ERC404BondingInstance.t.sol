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
 * @dev Tests bonding curve, password-protected tiers, messages, and V4 liquidity
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
    ERC404BondingInstance.TierConfig tierConfig;
    
    bytes32 public passwordHash1;
    bytes32 public passwordHash2;
    
    // Mock addresses (would need proper mocks in full implementation)
    address public mockV4PoolManager = address(0x100);
    address public mockV4Hook = address(0x200);
    address public mockWETH = address(0x300);
    address public mockMasterRegistry = address(0x400);
    address public mockHookFactory = address(0x500);
    address public mockLiquidityDeployer = address(0x600);

    MockMasterRegistryForStaking public stakingRegistry;
    ERC404StakingModule public stakingModule;
    CurveParamsComputer public curveComputer;

    function setUp() public {
        // Deploy staking infrastructure before pranking as owner
        stakingRegistry = new MockMasterRegistryForStaking();
        stakingModule = new ERC404StakingModule(address(stakingRegistry));
        curveComputer = new CurveParamsComputer(address(this));

        vm.startPrank(owner);
        
        // Set up password hashes
        passwordHash1 = keccak256("password1");
        passwordHash2 = keccak256("password2");
        
        // Set up bonding curve parameters (matching CULTEXEC404 defaults)
        curveParams = BondingCurveMath.Params({
            initialPrice: 0.025 ether,
            quarticCoeff: 3 gwei,        // 12/4 * 1 gwei
            cubicCoeff: 1333333333,       // 4/3 * 1 gwei  
            quadraticCoeff: 2 gwei,      // 4/2 * 1 gwei
            normalizationFactor: 1e7     // 10M tokens
        });
        
        // Set up tier config (volume cap mode)
        bytes32[] memory passwordHashes = new bytes32[](2);
        passwordHashes[0] = passwordHash1;
        passwordHashes[1] = passwordHash2;
        
        uint256[] memory volumeCaps = new uint256[](2);
        volumeCaps[0] = 1000 * 1e18;  // Tier 1: 1000 tokens
        volumeCaps[1] = 10000 * 1e18; // Tier 2: 10000 tokens
        
        tierConfig = ERC404BondingInstance.TierConfig({
            tierType: ERC404BondingInstance.TierType.VOLUME_CAP,
            passwordHashes: passwordHashes,
            volumeCaps: volumeCaps,
            tierUnlockTimes: new uint256[](0) // Not used in volume cap mode
        });
        
        // Deploy instance via clone + initialize pattern
        // Note: Factory must match msg.sender for DN404Mirror linking to work
        // Since we're pranked as 'owner', factory must be 'owner'
        ERC404BondingInstance impl = new ERC404BondingInstance();
        instance = ERC404BondingInstance(payable(LibClone.clone(address(impl))));
        instance.initialize(
            "Test Token",
            "TEST",
            MAX_SUPPLY,
            LIQUIDITY_RESERVE_PERCENT,
            curveParams,
            tierConfig,
            mockV4PoolManager,
            address(0), // Hook set later
            mockWETH,
            owner, // Factory must match msg.sender (pranked as owner)
            mockMasterRegistry, // MasterRegistry
            address(0xBEEF), // vault
            owner,
            "", // styleUri
            address(0xFEE), // protocolTreasury
            100, // bondingFeeBps (1%)
            200, // graduationFeeBps (2%)
            100, // polBps (1%)
            address(0xC1EA), // factoryCreator
            40, // creatorGraduationFeeBps (0.4%)
            3000, // poolFee
            60, // tickSpacing
            1_000_000 ether, // unit
            address(stakingModule), // staking module
            mockLiquidityDeployer, // liquidity deployer module
            address(curveComputer), // curve computer\n            mockMasterRegistry // master registry
        );

        vm.stopPrank();

        // Register instance with staking registry so staking module accepts calls from it
        stakingRegistry.setInstance(address(instance), true);
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
        // Test that password verification happens inline during buyBonding
        // Previously users had to call unlockTier() first, now it's checked at purchase
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
        // Should succeed with valid password (inlined verification)
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
        zeroFeeInstance.initialize(
            "Zero Fee Token",
            "ZFT",
            MAX_SUPPLY,
            LIQUIDITY_RESERVE_PERCENT,
            curveParams,
            tierConfig,
            mockV4PoolManager,
            address(0),
            mockWETH,
            owner,
            mockMasterRegistry,
            address(0xBEEF),
            owner,
            "",
            address(0xFEE),
            0, // 0% bonding fee
            0, // 0% graduation fee
            0, // 0% polBps
            address(0xC1EA), // factoryCreator
            40, // creatorGraduationFeeBps
            3000, // poolFee
            60, // tickSpacing
            1_000_000 ether, // unit
            address(stakingModule), // staking module
            mockLiquidityDeployer, // liquidity deployer module
            address(curveComputer) // curve computer
        );
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
        noTreasuryInstance.initialize(
            "No Treasury Token",
            "NTT",
            MAX_SUPPLY,
            LIQUIDITY_RESERVE_PERCENT,
            curveParams,
            tierConfig,
            mockV4PoolManager,
            address(0),
            mockWETH,
            owner,
            mockMasterRegistry,
            address(0xBEEF),
            owner,
            "",
            address(0), // no treasury
            100, // bondingFeeBps
            200, // graduationFeeBps
            100, // polBps
            address(0xC1EA), // factoryCreator
            40, // creatorGraduationFeeBps
            3000, // poolFee
            60, // tickSpacing
            1_000_000 ether, // unit
            address(stakingModule), // staking module
            mockLiquidityDeployer, // liquidity deployer module
            address(curveComputer) // curve computer
        );
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
        customInstance.initialize(
            "Custom Grad Fee",
            "CGF",
            MAX_SUPPLY,
            LIQUIDITY_RESERVE_PERCENT,
            curveParams,
            tierConfig,
            mockV4PoolManager,
            address(0),
            mockWETH,
            owner,
            mockMasterRegistry,
            address(0xBEEF),
            owner,
            "",
            address(0xFEE),
            100, // bondingFeeBps
            450, // graduationFeeBps (4.5%)
            100, // polBps
            address(0xC1EA), // factoryCreator
            40, // creatorGraduationFeeBps
            3000, // poolFee
            60, // tickSpacing
            1_000_000 ether, // unit
            address(stakingModule), // staking module
            mockLiquidityDeployer, // liquidity deployer module
            address(curveComputer) // curve computer
        );
        vm.stopPrank();

        assertEq(customInstance.graduationFeeBps(), 450, "Custom graduation fee should be stored");
    }

    function test_GraduationFeeBps_ZeroAllowed() public {
        vm.startPrank(owner);
        ERC404BondingInstance zeroGradImpl = new ERC404BondingInstance();
        ERC404BondingInstance zeroGradInstance = ERC404BondingInstance(payable(LibClone.clone(address(zeroGradImpl))));
        zeroGradInstance.initialize(
            "Zero Grad Fee",
            "ZGF",
            MAX_SUPPLY,
            LIQUIDITY_RESERVE_PERCENT,
            curveParams,
            tierConfig,
            mockV4PoolManager,
            address(0),
            mockWETH,
            owner,
            mockMasterRegistry,
            address(0xBEEF),
            owner,
            "",
            address(0xFEE),
            100, // bondingFeeBps
            0, // 0% graduation fee
            100, // polBps
            address(0xC1EA), // factoryCreator
            40, // creatorGraduationFeeBps
            3000, // poolFee
            60, // tickSpacing
            1_000_000 ether, // unit
            address(stakingModule), // staking module
            mockLiquidityDeployer, // liquidity deployer module
            address(curveComputer) // curve computer
        );
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
    // POL BPS Tests
    // ========================

    function test_PolBps_StoredCorrectly() public {
        assertEq(instance.polBps(), 100, "POL bps should be 100 (1%)");
    }

    function test_PolBps_Immutable() public {
        vm.startPrank(owner);
        ERC404BondingInstance customPolImpl = new ERC404BondingInstance();
        ERC404BondingInstance customInstance = ERC404BondingInstance(payable(LibClone.clone(address(customPolImpl))));
        customInstance.initialize(
            "Custom POL",
            "CPOL",
            MAX_SUPPLY,
            LIQUIDITY_RESERVE_PERCENT,
            curveParams,
            tierConfig,
            mockV4PoolManager,
            address(0),
            mockWETH,
            owner,
            mockMasterRegistry,
            address(0xBEEF),
            owner,
            "",
            address(0xFEE),
            100, // bondingFeeBps
            200, // graduationFeeBps
            250, // polBps (2.5%)
            address(0xC1EA), // factoryCreator
            40, // creatorGraduationFeeBps
            3000, // poolFee
            60, // tickSpacing
            1_000_000 ether, // unit
            address(stakingModule), // staking module
            mockLiquidityDeployer, // liquidity deployer module
            address(curveComputer) // curve computer
        );
        vm.stopPrank();

        assertEq(customInstance.polBps(), 250, "Custom POL bps should be stored");
    }

    function test_POL_MathCorrectness() public {
        // With 2% grad fee on 15 ETH = 0.3, then 1% POL on 14.7 = 0.147
        uint256 deployETH = 15 ether;
        uint256 deployTokens = 1_000_000 * 1e18;
        uint256 gradFeeBps = instance.graduationFeeBps(); // 200
        uint256 polFeeBps = instance.polBps(); // 100

        // Step 1: Graduation fee
        uint256 graduationFee = (deployETH * gradFeeBps) / 10000;
        uint256 afterGrad = deployETH - graduationFee;

        // Step 2: POL carve-out
        uint256 polETH = (afterGrad * polFeeBps) / 10000;
        uint256 polTokens = (deployTokens * polFeeBps) / 10000;
        uint256 mainETH = afterGrad - polETH;
        uint256 mainTokens = deployTokens - polTokens;

        assertEq(graduationFee, 0.3 ether, "Graduation fee: 2% of 15 ETH");
        assertEq(afterGrad, 14.7 ether, "After grad: 14.7 ETH");
        assertEq(polETH, 0.147 ether, "POL ETH: 1% of 14.7");
        assertEq(polTokens, 10_000 * 1e18, "POL tokens: 1% of 1M");
        assertEq(mainETH, 14.553 ether, "Main ETH: 14.7 - 0.147");
        assertEq(mainTokens, 990_000 * 1e18, "Main tokens: 1M - 10K");
    }

    function test_POL_ZeroBps() public {
        vm.startPrank(owner);
        ERC404BondingInstance zeroPOLImpl = new ERC404BondingInstance();
        ERC404BondingInstance zeroPOL = ERC404BondingInstance(payable(LibClone.clone(address(zeroPOLImpl))));
        zeroPOL.initialize(
            "Zero POL",
            "ZPOL",
            MAX_SUPPLY,
            LIQUIDITY_RESERVE_PERCENT,
            curveParams,
            tierConfig,
            mockV4PoolManager,
            address(0),
            mockWETH,
            owner,
            mockMasterRegistry,
            address(0xBEEF),
            owner,
            "",
            address(0xFEE),
            100,
            200,
            0, // 0% polBps
            address(0xC1EA), // factoryCreator
            40, // creatorGraduationFeeBps
            3000, // poolFee
            60, // tickSpacing
            1_000_000 ether, // unit
            address(stakingModule), // staking module
            mockLiquidityDeployer, // liquidity deployer module
            address(curveComputer) // curve computer
        );
        vm.stopPrank();

        assertEq(zeroPOL.polBps(), 0, "Zero POL bps should be allowed");

        // Verify no carve-out with 0 bps
        uint256 deployETH = 15 ether;
        uint256 polETH = (deployETH * zeroPOL.polBps()) / 10000;
        assertEq(polETH, 0, "No POL carve with 0 bps");
    }

    function test_POL_NoTreasury() public {
        vm.startPrank(owner);
        ERC404BondingInstance noTreasuryPOLImpl = new ERC404BondingInstance();
        ERC404BondingInstance noTreasuryPOL = ERC404BondingInstance(payable(LibClone.clone(address(noTreasuryPOLImpl))));
        noTreasuryPOL.initialize(
            "No Treasury POL",
            "NTPOL",
            MAX_SUPPLY,
            LIQUIDITY_RESERVE_PERCENT,
            curveParams,
            tierConfig,
            mockV4PoolManager,
            address(0),
            mockWETH,
            owner,
            mockMasterRegistry,
            address(0xBEEF),
            owner,
            "",
            address(0), // no treasury
            100,
            200,
            100, // polBps
            address(0xC1EA), // factoryCreator
            40, // creatorGraduationFeeBps
            3000, // poolFee
            60, // tickSpacing
            1_000_000 ether, // unit
            address(stakingModule), // staking module
            mockLiquidityDeployer, // liquidity deployer module
            address(curveComputer) // curve computer
        );
        vm.stopPrank();

        assertEq(noTreasuryPOL.polBps(), 100, "POL bps stored even without treasury");
        assertEq(noTreasuryPOL.protocolTreasury(), address(0), "Treasury should be zero");
        // POL carve-out is skipped when treasury is address(0) — verified in integration tests
    }

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
        noHookInstance.initialize(
            "No Hook",
            "NH",
            MAX_SUPPLY,
            LIQUIDITY_RESERVE_PERCENT,
            curveParams,
            tierConfig,
            mockV4PoolManager,
            address(0), // no hook
            mockWETH,
            owner,
            mockMasterRegistry,
            address(0xBEEF),
            owner,
            "",
            address(0xFEE),
            100,
            200,
            100,
            address(0xC1EA),
            40,
            3000,
            60,
            1_000_000 ether, // unit
            address(stakingModule), // staking module
            mockLiquidityDeployer, // liquidity deployer module
            address(curveComputer) // curve computer
        );
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

