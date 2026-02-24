// test/vaults/UltraAlignmentCypherVault.t.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "forge-std/Test.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockAlgebraPositionManager, MockAlgebraSwapRouter} from "../mocks/MockCypherAlgebra.sol";
import {MockWETH} from "../mocks/MockWETH.sol";
import {TestableUltraAlignmentCypherVault} from "../helpers/TestableUltraAlignmentCypherVault.sol";
import {UltraAlignmentCypherVault} from "../../src/vaults/cypher/UltraAlignmentCypherVault.sol";
import {Currency} from "v4-core/types/Currency.sol";

contract UltraAlignmentCypherVaultTest is Test {
    TestableUltraAlignmentCypherVault vault;
    MockERC20 alignmentToken;
    MockWETH weth;
    MockAlgebraPositionManager positionManager;
    MockAlgebraSwapRouter swapRouter;

    address owner = address(this);
    address liquidityDeployer = makeAddr("liquidityDeployer");
    address protocolTreasury = makeAddr("treasury");
    address factoryCreator = makeAddr("creator");
    address alice = makeAddr("alice");

    function setUp() public {
        alignmentToken = new MockERC20("Alignment", "ALN");
        weth = new MockWETH();
        positionManager = new MockAlgebraPositionManager();
        swapRouter = new MockAlgebraSwapRouter();

        TestableUltraAlignmentCypherVault impl = new TestableUltraAlignmentCypherVault();
        vault = TestableUltraAlignmentCypherVault(payable(LibClone.clone(address(impl))));
        vault.initialize(
            address(positionManager),
            address(swapRouter),
            address(weth),
            address(alignmentToken),
            factoryCreator,
            100,  // 1% creator yield cut
            protocolTreasury,
            liquidityDeployer
        );
    }

    function test_initialize_setsConfig() public view {
        assertEq(address(vault.positionManager()), address(positionManager));
        assertEq(vault.alignmentToken(), address(alignmentToken));
        assertEq(vault.factoryCreator(), factoryCreator);
        assertEq(vault.liquidityDeployer(), liquidityDeployer);
        assertEq(vault.protocolYieldCutBps(), 500);
        assertEq(vault.creatorYieldCutBps(), 100);
    }

    function test_initialize_revertIfCalledTwice() public {
        vm.expectRevert();
        vault.initialize(
            address(positionManager), address(swapRouter), address(weth),
            address(alignmentToken), factoryCreator, 100, protocolTreasury, liquidityDeployer
        );
    }

    function test_registerPosition_onlyLiquidityDeployer() public {
        vm.expectRevert();
        vault.registerPosition(1, makeAddr("pool"), true, alice, 1 ether);

        vm.prank(liquidityDeployer);
        vault.registerPosition(1, makeAddr("pool"), true, alice, 1 ether);
        assertEq(vault.benefactorContribution(alice), 1 ether);
        assertEq(vault.totalContributions(), 1 ether);
    }

    function test_receiveContribution_tracksETH() public {
        vm.deal(address(this), 2 ether);
        vault.receiveContribution{value: 2 ether}(Currency.wrap(address(0)), 2 ether, alice);
        assertEq(vault.benefactorContribution(alice), 2 ether);
        assertEq(vault.totalContributions(), 2 ether);
    }

    function test_harvest_distributesFeesToBenefactors() public {
        // Register alice as benefactor
        vm.prank(liquidityDeployer);
        vault.registerPosition(1, makeAddr("pool"), true, alice, 1 ether);

        // tokenIsZero=true so alignment=token0, weth=token1
        vault.setPositionForTest(1, makeAddr("pool"), true);

        // Set up mock position with proper token addresses so collect() works
        positionManager.setPosition(1, address(alignmentToken), address(weth), address(vault));

        // Set up fees: alignment token fees (token0) and weth fees (token1)
        alignmentToken.mint(address(positionManager), 0.1e18);
        weth.mint(address(positionManager), 0.05e18);
        positionManager.setFees(1, 0.1e18, 0.05e18);

        // Give swapRouter weth to return from swap (alignment -> weth at 0.9 rate)
        weth.mint(address(swapRouter), 0.09e18);
        swapRouter.setRate(address(alignmentToken), address(weth), 0.9e18);

        // Give the weth contract enough ETH to cover withdrawals
        vm.deal(address(weth), 0.14e18);

        uint256 aliceBalBefore = alice.balance;
        vault.harvest();
        // Check accumulator updated
        assertGt(vault.accRewardPerContribution(), 0);

        // Alice can claim
        uint256 claimable = vault.calculateClaimableAmount(alice);
        assertGt(claimable, 0);
        vm.prank(alice);
        vault.claimFees();
        assertGt(alice.balance, aliceBalBefore);
    }

    function test_vaultType_returnsCypherLP() public view {
        assertEq(vault.vaultType(), "CypherLP");
    }

    function test_totalShares_equalsTotalContributions() public {
        vm.prank(liquidityDeployer);
        vault.registerPosition(1, makeAddr("pool"), true, alice, 3 ether);
        assertEq(vault.totalShares(), 3 ether);
    }
}
