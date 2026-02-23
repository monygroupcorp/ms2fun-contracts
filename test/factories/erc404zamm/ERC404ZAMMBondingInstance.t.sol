// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {ERC404ZAMMBondingInstance} from "../../../src/factories/erc404zamm/ERC404ZAMMBondingInstance.sol";
import {ZAMMLiquidityDeployerModule} from "../../../src/factories/erc404zamm/ZAMMLiquidityDeployerModule.sol";
import {BondingCurveMath} from "../../../src/factories/erc404/libraries/BondingCurveMath.sol";
import {CurveParamsComputer} from "../../../src/factories/erc404/CurveParamsComputer.sol";
import {MockZAMM} from "../../mocks/MockZAMM.sol";
import {MockMasterRegistry} from "../../mocks/MockMasterRegistry.sol";

contract ERC404ZAMMBondingInstanceTest is Test {
    ERC404ZAMMBondingInstance instance;
    MockZAMM zamm;
    ZAMMLiquidityDeployerModule realDeployer;
    CurveParamsComputer realCurveComputer;

    address owner = makeAddr("owner");
    address buyer = makeAddr("buyer");
    address treasury = makeAddr("treasury");
    address vault = makeAddr("vault");
    address factory = makeAddr("factory");
    address globalMsgRegistry = makeAddr("globalMsgRegistry");
    address factoryCreator = makeAddr("factoryCreator");
    address zammAddr;
    MockMasterRegistry masterRegistry;

    function setUp() public {
        zamm = new MockZAMM();
        realDeployer = new ZAMMLiquidityDeployerModule();
        realCurveComputer = new CurveParamsComputer(address(this));
        masterRegistry = new MockMasterRegistry();

        // Deploy implementation and clone it (constructor guards implementation from direct init)
        ERC404ZAMMBondingInstance impl = new ERC404ZAMMBondingInstance();
        instance = ERC404ZAMMBondingInstance(payable(LibClone.clone(address(impl))));

        // Minimal tier config: one tier with a simple hash
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = keccak256("open");
        uint256[] memory caps = new uint256[](1);
        caps[0] = type(uint256).max;

        ERC404ZAMMBondingInstance.TierConfig memory tierConfig = ERC404ZAMMBondingInstance.TierConfig({
            tierType: ERC404ZAMMBondingInstance.TierType.VOLUME_CAP,
            passwordHashes: hashes,
            volumeCaps: caps,
            tierUnlockTimes: new uint256[](0)
        });

        BondingCurveMath.Params memory curve = BondingCurveMath.Params({
            initialPrice: 1e9,
            quarticCoeff: 0,
            cubicCoeff: 0,
            quadraticCoeff: 0,
            normalizationFactor: 1
        });

        // factory must match msg.sender of initialize for DN404Mirror linking
        vm.prank(factory);
        instance.initialize(
            "TestToken",
            "TEST",
            10_000 ether,       // maxSupply
            20,                  // 20% liquidity reserve
            curve,
            tierConfig,
            factory,
            globalMsgRegistry,
            vault,
            owner,
            "",                  // styleUri
            treasury,
            100,                 // bondingFeeBps (1%)
            200,                 // graduationFeeBps (2%)
            50,                  // creatorGraduationFeeBps (0.5%)
            factoryCreator,
            1e18,                // tokenUnit
            address(realDeployer),
            address(realCurveComputer),
            address(masterRegistry)
        );
    }

    function test_initialize_setsState() public view {
        assertEq(instance.factory(), factory);
        assertEq(address(instance.vault()), vault);
        assertFalse(instance.graduated());
        assertFalse(instance.bondingActive());
    }

    function test_setBondingActive_requiresOpenTime() public {
        vm.prank(owner);
        vm.expectRevert();
        instance.setBondingActive(true);
    }

    function test_bondingBuyAndSell() public {
        // Set open time + activate
        vm.prank(owner);
        instance.setBondingOpenTime(block.timestamp + 1);
        vm.warp(block.timestamp + 2);
        vm.prank(owner);
        instance.setBondingActive(true);

        // Buy
        uint256 amount = 100 ether;
        vm.deal(buyer, 10 ether);
        vm.prank(buyer);
        instance.buyBonding{value: 10 ether}(
            amount, 10 ether, false, bytes32(0), "", 0
        );
        assertGt(instance.balanceOf(buyer), 0);

        // Sell half
        uint256 balance = instance.balanceOf(buyer);
        vm.prank(buyer);
        instance.sellBonding(balance / 2, 0, bytes32(0), "", 0);
        assertLt(instance.balanceOf(buyer), balance);
    }

    // ── Graduation tests ──────────────────────────────────────────────────────

    function _setupGraduation() internal {
        zammAddr = address(zamm);

        // Fill bonding curve
        vm.prank(owner);
        instance.setBondingOpenTime(block.timestamp + 1);
        vm.warp(block.timestamp + 2);
        vm.prank(owner);
        instance.setBondingActive(true);

        uint256 cap = instance.MAX_SUPPLY() - instance.LIQUIDITY_RESERVE();
        uint256 cost = 100 ether; // simplified
        vm.deal(buyer, cost);
        vm.prank(buyer);
        instance.buyBonding{value: cost}(cap, cost, false, bytes32(0), "", 0);
    }

    function test_deployLiquidity_setsGraduated() public {
        _setupGraduation();

        instance.deployLiquidity(zammAddr, 30, 200); // feeOrHook=30, taxBps=200

        assertTrue(instance.graduated());
        assertEq(instance.zamm(), zammAddr);
        assertFalse(instance.bondingActive());
    }

    function test_deployLiquidity_setsTransferExemptions() public {
        _setupGraduation();
        instance.deployLiquidity(zammAddr, 30, 200);

        assertTrue(instance.transferExempt(address(instance)));
        assertTrue(instance.transferExempt(address(instance.liquidityDeployer())));
        assertTrue(instance.transferExempt(address(instance.vault())));
    }

    function test_deployLiquidity_revertsIfAlreadyDeployed() public {
        _setupGraduation();
        instance.deployLiquidity(zammAddr, 30, 200);

        vm.expectRevert();
        instance.deployLiquidity(zammAddr, 30, 200);
    }

    // ── Tax + sweep tests ─────────────────────────────────────────────────────

    function _graduate() internal {
        zammAddr = address(zamm);
        vm.prank(owner);
        instance.setBondingOpenTime(block.timestamp + 1);
        vm.warp(block.timestamp + 2);
        vm.prank(owner);
        instance.setBondingActive(true);

        // Set maturity time and warp past it so anyone can graduate
        vm.prank(owner);
        instance.setBondingMaturityTime(block.timestamp + 10);
        vm.warp(block.timestamp + 11);

        // Buy a small amount so reserve > 0
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        instance.buyBonding{value: 1 ether}(1 ether, 1 ether, false, bytes32(0), "", 0);

        // Graduate (permissionless since maturity has passed)
        instance.deployLiquidity(zammAddr, 30, 100); // 1% tax
    }

    function test_transferToZAMM_accumulatesTax() public {
        _graduate();

        uint256 buyerBalance = instance.balanceOf(buyer);
        assertGt(buyerBalance, 0, "buyer should have tokens after buy");
        uint256 sellAmount = buyerBalance / 2; // sell half

        uint256 taxBefore = instance.accumulatedTax();
        uint256 zammBalanceBefore = instance.balanceOf(zammAddr);
        vm.prank(buyer);
        instance.transfer(zammAddr, sellAmount); // triggers tax hook

        uint256 expectedTax = (sellAmount * 100) / 10000; // 1%
        assertEq(instance.accumulatedTax(), taxBefore + expectedTax);
        // ZAMM receives sellAmount - tax (check delta)
        assertEq(instance.balanceOf(zammAddr), zammBalanceBefore + sellAmount - expectedTax);
    }

    function test_transferFromZAMM_accumulatesTax() public {
        _graduate();

        uint256 amount = 10 ether;
        // Give ZAMM some tokens (exempt transfer from instance)
        vm.prank(address(instance));
        instance.transfer(zammAddr, amount); // exempt (instance is in transferExempt), no tax

        // Simulate a "buy": transfer from zamm to buyer
        uint256 taxBefore = instance.accumulatedTax();
        vm.prank(zammAddr);
        instance.transfer(buyer, amount);

        uint256 expectedTax = (amount * 100) / 10000;
        assertEq(instance.accumulatedTax(), taxBefore + expectedTax);
    }

    function test_transferExempt_noTax() public {
        _graduate();

        uint256 amount = 10 ether;
        // Instance -> ZAMM: exempt (instance is in transferExempt)
        uint256 taxBefore = instance.accumulatedTax();
        vm.prank(address(instance));
        instance.transfer(zammAddr, amount);
        assertEq(instance.accumulatedTax(), taxBefore); // no tax
    }

    function test_walletToWallet_noTax() public {
        _graduate();

        address other = makeAddr("other");
        uint256 buyerBalance = instance.balanceOf(buyer);
        vm.prank(buyer);
        instance.transfer(other, buyerBalance / 2);

        assertEq(instance.accumulatedTax(), 0); // no tax
    }

    function test_sweepTax_swapsToEthAndSendsToVault() public {
        _graduate();

        // Accumulate some tax by selling tokens to ZAMM
        uint256 buyerBalance = instance.balanceOf(buyer);
        vm.prank(buyer);
        instance.transfer(zammAddr, buyerBalance);
        uint256 accumulated = instance.accumulatedTax();
        assertGt(accumulated, 0);

        // Fund MockZAMM with ETH to return on swap
        vm.deal(zammAddr, 10 ether);
        zamm.setEthPerToken(1e15); // 0.001 ETH per token

        // vault is just an address in tests — it needs to accept ETH
        // MockVault: vault = makeAddr("vault") is an EOA, can receive ETH but has no receiveInstance()
        // We need to make vault accept the call — use a mock vault
        vm.mockCall(
            vault,
            abi.encodeWithSignature("receiveContribution(address,uint256,address)"),
            abi.encode()
        );

        instance.sweepTax();
        assertEq(instance.accumulatedTax(), 0);
    }

    function test_sweepTax_noopOnZeroBalance() public {
        _graduate();
        // No accumulated tax — should be a no-op
        instance.sweepTax();
        assertEq(instance.accumulatedTax(), 0);
    }

    // ── Vault migration tests ─────────────────────────────────────────────────

    function test_MigrateVault_UpdatesActiveVault() public {
        address newVault = makeAddr("newVault");
        vm.prank(owner);
        instance.migrateVault(newVault);
        assertEq(address(instance.vault()), newVault);
    }

    function test_ClaimAllFees_IteratesAllVaults() public {
        address vault1 = vault;
        address vault2 = makeAddr("vault2");

        // Mock registry to return two vaults
        vm.mockCall(
            address(masterRegistry),
            abi.encodeWithSignature("getInstanceVaults(address)", address(instance)),
            abi.encode(_twoVaults(vault1, vault2))
        );
        // Mock claimFees on both vaults (returns 0)
        vm.mockCall(vault1, abi.encodeWithSignature("claimFees()"), abi.encode(uint256(0)));
        vm.mockCall(vault2, abi.encodeWithSignature("claimFees()"), abi.encode(uint256(0)));

        vm.prank(owner);
        instance.claimAllFees(); // must not revert
    }

    function test_MigrateVault_RevertIfNotOwner() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert();
        instance.migrateVault(makeAddr("newVault"));
    }

    function _twoVaults(address a, address b) internal pure returns (address[] memory arr) {
        arr = new address[](2);
        arr[0] = a;
        arr[1] = b;
    }
}
