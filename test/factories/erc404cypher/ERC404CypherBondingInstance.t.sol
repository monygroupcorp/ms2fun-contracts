// test/factories/erc404cypher/ERC404CypherBondingInstance.t.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {ERC404CypherBondingInstance} from "../../../src/factories/erc404cypher/ERC404CypherBondingInstance.sol";
import {CypherLiquidityDeployerModule} from "../../../src/factories/erc404cypher/CypherLiquidityDeployerModule.sol";
import {UltraAlignmentCypherVault} from "../../../src/vaults/cypher/UltraAlignmentCypherVault.sol";
import {BondingCurveMath} from "../../../src/factories/erc404/libraries/BondingCurveMath.sol";
import {CurveParamsComputer} from "../../../src/factories/erc404/CurveParamsComputer.sol";
import {MockAlgebraFactory, MockAlgebraPositionManager, MockAlgebraSwapRouter} from "../../mocks/MockCypherAlgebra.sol";
import {MockWETH} from "../../mocks/MockWETH.sol";
import {MockMasterRegistry} from "../../mocks/MockMasterRegistry.sol";

contract ERC404CypherBondingInstanceTest is Test {
    ERC404CypherBondingInstance instance;
    CypherLiquidityDeployerModule liquidityDeployer;
    UltraAlignmentCypherVault vault;
    CurveParamsComputer realCurveComputer;
    MockAlgebraFactory algebraFactory;
    MockAlgebraPositionManager positionManager;
    MockAlgebraSwapRouter swapRouter;
    MockWETH weth;
    MockMasterRegistry masterRegistry;

    address owner = makeAddr("owner");
    address buyer = makeAddr("buyer");
    address treasury = makeAddr("treasury");
    address factory = makeAddr("factory");
    address globalMsgRegistry = makeAddr("globalMsgRegistry");
    address factoryCreator = makeAddr("factoryCreator");

    // 1:1 sqrtPriceX96
    uint160 constant SQRT_PRICE = 79228162514264337593543950336;

    function setUp() public {
        algebraFactory = new MockAlgebraFactory();
        positionManager = new MockAlgebraPositionManager();
        swapRouter = new MockAlgebraSwapRouter();
        weth = new MockWETH();
        liquidityDeployer = new CypherLiquidityDeployerModule();
        realCurveComputer = new CurveParamsComputer(address(this));
        masterRegistry = new MockMasterRegistry();

        // Deploy vault with deployer as liquidityDeployer
        UltraAlignmentCypherVault vaultImpl = new UltraAlignmentCypherVault();
        vault = UltraAlignmentCypherVault(payable(LibClone.clone(address(vaultImpl))));

        // Deploy instance
        ERC404CypherBondingInstance impl = new ERC404CypherBondingInstance();
        instance = ERC404CypherBondingInstance(payable(LibClone.clone(address(impl))));

        // Initialize vault with liquidityDeployer = deployer module
        vault.initialize(
            address(positionManager), address(swapRouter), address(weth),
            address(instance), factoryCreator, 100, treasury,
            address(liquidityDeployer)
        );

        // Minimal tier config
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = keccak256("open");
        uint256[] memory caps = new uint256[](1);
        caps[0] = type(uint256).max;

        ERC404CypherBondingInstance.TierConfig memory tierConfig = ERC404CypherBondingInstance.TierConfig({
            tierType: ERC404CypherBondingInstance.TierType.VOLUME_CAP,
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

        vm.prank(factory);
        instance.initialize(
            "CypherToken", "CYPH",
            10_000 ether,    // maxSupply
            20,              // 20% liquidity reserve
            curve,
            tierConfig,
            factory,
            globalMsgRegistry,
            address(vault),
            owner,
            "",              // styleUri
            treasury,
            100,             // bondingFeeBps
            200,             // graduationFeeBps
            50,              // creatorGraduationFeeBps
            factoryCreator,
            1e18,            // tokenUnit
            address(liquidityDeployer),
            address(realCurveComputer),
            address(masterRegistry),
            address(weth),
            address(algebraFactory),
            address(positionManager)
        );
    }

    function test_initialize_setsState() public view {
        assertEq(instance.factory(), factory);
        assertEq(address(instance.vault()), address(vault));
        assertFalse(instance.graduated());
        assertFalse(instance.bondingActive());
        assertEq(instance.weth(), address(weth));
        assertEq(instance.algebraFactory(), address(algebraFactory));
    }

    function test_setBondingActive_requiresOpenTime() public {
        vm.prank(owner);
        vm.expectRevert();
        instance.setBondingActive(true);
    }

    function test_buy_increasesReserve() public {
        vm.prank(owner);
        instance.setBondingOpenTime(block.timestamp + 1);
        vm.warp(block.timestamp + 2);
        vm.prank(owner);
        instance.setBondingActive(true);

        uint256 amount = 100 ether;
        vm.deal(buyer, 10 ether);
        vm.prank(buyer);
        instance.buyBonding{value: 10 ether}(amount, 10 ether, false, bytes32(0), "", 0);

        assertGt(instance.balanceOf(buyer), 0);
        assertGt(instance.reserve(), 0);
    }

    function test_sell_decreasesReserve() public {
        vm.prank(owner);
        instance.setBondingOpenTime(block.timestamp + 1);
        vm.warp(block.timestamp + 2);
        vm.prank(owner);
        instance.setBondingActive(true);

        uint256 amount = 100 ether;
        vm.deal(buyer, 10 ether);
        vm.prank(buyer);
        instance.buyBonding{value: 10 ether}(amount, 10 ether, false, bytes32(0), "", 0);

        uint256 reserveBefore = instance.reserve();
        uint256 balance = instance.balanceOf(buyer);
        vm.prank(buyer);
        instance.sellBonding(balance / 2, 0, bytes32(0), "", 0);
        assertLt(instance.reserve(), reserveBefore);
    }

    function test_deployLiquidity_graduatesInstance() public {
        // Setup and activate bonding
        vm.prank(owner);
        instance.setBondingOpenTime(block.timestamp + 1);
        vm.warp(block.timestamp + 2);
        vm.prank(owner);
        instance.setBondingActive(true);
        vm.prank(owner);
        instance.setBondingMaturityTime(block.timestamp + 10);
        vm.warp(block.timestamp + 11);

        // Buy some tokens to accumulate reserve
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        instance.buyBonding{value: 1 ether}(1 ether, 1 ether, false, bytes32(0), "", 0);

        // Graduate (permissionless since maturity passed)
        instance.deployLiquidity(SQRT_PRICE, 0);

        assertTrue(instance.graduated());
        assertFalse(instance.bondingActive());
        assertGt(vault.lpTokenId(), 0);
    }

    function test_deployLiquidity_revertsIfAlreadyDeployed() public {
        vm.prank(owner);
        instance.setBondingOpenTime(block.timestamp + 1);
        vm.warp(block.timestamp + 2);
        vm.prank(owner);
        instance.setBondingActive(true);
        vm.prank(owner);
        instance.setBondingMaturityTime(block.timestamp + 10);
        vm.warp(block.timestamp + 11);

        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        instance.buyBonding{value: 1 ether}(1 ether, 1 ether, false, bytes32(0), "", 0);
        instance.deployLiquidity(SQRT_PRICE, 0);

        vm.expectRevert();
        instance.deployLiquidity(SQRT_PRICE, 0);
    }

    function test_noTransferTax_walletToWallet() public {
        // Graduate the instance
        vm.prank(owner);
        instance.setBondingOpenTime(block.timestamp + 1);
        vm.warp(block.timestamp + 2);
        vm.prank(owner);
        instance.setBondingActive(true);
        vm.prank(owner);
        instance.setBondingMaturityTime(block.timestamp + 10);
        vm.warp(block.timestamp + 11);

        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        instance.buyBonding{value: 1 ether}(1 ether, 1 ether, false, bytes32(0), "", 0);
        instance.deployLiquidity(SQRT_PRICE, 0);

        // After graduation, wallet-to-wallet transfers should have no tax
        address other = makeAddr("other");
        uint256 buyerBalance = instance.balanceOf(buyer);
        assertGt(buyerBalance, 0);

        uint256 preBal = instance.balanceOf(other);
        vm.prank(buyer);
        instance.transfer(other, buyerBalance / 2);
        // other receives exact amount, no tax taken
        assertEq(instance.balanceOf(other), preBal + buyerBalance / 2);
    }
}
