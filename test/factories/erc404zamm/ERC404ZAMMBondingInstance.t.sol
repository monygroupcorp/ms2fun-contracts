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
import {MockVault} from "../../mocks/MockVault.sol";

contract ERC404ZAMMBondingInstanceTest is Test {
    ERC404ZAMMBondingInstance instance;
    MockZAMM zamm;
    ZAMMLiquidityDeployerModule realDeployer;
    CurveParamsComputer realCurveComputer;

    address owner = makeAddr("owner");
    address buyer = makeAddr("buyer");
    address treasury = makeAddr("treasury");
    MockVault mockVault;
    address factory = makeAddr("factory");
    address globalMsgRegistry = makeAddr("globalMsgRegistry");
    address factoryCreator = makeAddr("factoryCreator");
    address zammAddr;
    MockMasterRegistry masterRegistry;

    function setUp() public {
        zamm = new MockZAMM();
        realDeployer = new ZAMMLiquidityDeployerModule();
        realCurveComputer = new CurveParamsComputer(address(this));
        mockVault = new MockVault();
        masterRegistry = new MockMasterRegistry();

        // Deploy implementation and clone it (constructor guards implementation from direct init)
        ERC404ZAMMBondingInstance impl = new ERC404ZAMMBondingInstance();
        instance = ERC404ZAMMBondingInstance(payable(LibClone.clone(address(impl))));

        BondingCurveMath.Params memory curve = BondingCurveMath.Params({
            initialPrice: 1e9,
            quarticCoeff: 0,
            cubicCoeff: 0,
            quadraticCoeff: 0,
            normalizationFactor: 1
        });

        // factory must match msg.sender of initialize for DN404Mirror linking
        vm.startPrank(factory);
        instance.initialize(
            owner,
            address(mockVault),
            ERC404ZAMMBondingInstance.BondingParams({
                maxSupply: 10_000 ether,
                unit: 1e18,
                liquidityReservePercent: 20,
                curve: curve
            }),
            address(0) // no gating module
        );

        instance.initializeProtocol(ERC404ZAMMBondingInstance.ProtocolParams({
            globalMessageRegistry: globalMsgRegistry,
            protocolTreasury: treasury,
            masterRegistry: address(masterRegistry),
            liquidityDeployer: address(realDeployer),
            curveComputer: address(realCurveComputer),
            bondingFeeBps: 100
        }));

        instance.initializeMetadata("TestToken", "TEST", "");
        vm.stopPrank();
    }

    function test_initialize_setsState() public view {
        assertEq(instance.factory(), factory);
        assertEq(address(instance.vault()), address(mockVault));
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

        instance.deployLiquidity(zammAddr, 30); // feeOrHook=30

        assertTrue(instance.graduated());
        assertEq(instance.zamm(), zammAddr);
        assertFalse(instance.bondingActive());
    }

    function test_deployLiquidity_revertsIfAlreadyDeployed() public {
        _setupGraduation();
        instance.deployLiquidity(zammAddr, 30);

        vm.expectRevert();
        instance.deployLiquidity(zammAddr, 30);
    }

    function test_noTransferTaxAfterGraduation() public {
        // After graduation, transfers to ZAMM must NOT deduct tax
        _setupGraduation();
        instance.deployLiquidity(zammAddr, 30);

        uint256 buyerBalance = instance.balanceOf(buyer);
        assertGt(buyerBalance, 0);
        uint256 zammBalanceBefore = instance.balanceOf(zammAddr);
        vm.prank(buyer);
        instance.transfer(zammAddr, buyerBalance);
        // ZAMM receives exactly buyerBalance — no tax deduction
        assertEq(instance.balanceOf(zammAddr), zammBalanceBefore + buyerBalance);
    }

    function test_deployLiquidity_noTaxParam() public {
        // deployLiquidity() accepts only (_zamm, _feeOrHook) — no _taxBps
        _setupGraduation();
        instance.deployLiquidity(zammAddr, 30);
        assertTrue(instance.graduated());
    }

    // ── Vault migration tests ─────────────────────────────────────────────────

    function test_MigrateVault_UpdatesActiveVault() public {
        address newVault = makeAddr("newVault");
        vm.prank(owner);
        instance.migrateVault(newVault);
        assertEq(address(instance.vault()), newVault);
    }

    function test_ClaimAllFees_IteratesAllVaults() public {
        address vault1 = address(mockVault);
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
