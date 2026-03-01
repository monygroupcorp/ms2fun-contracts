// test/factories/erc404cypher/CypherLiquidityDeployerModule.t.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "forge-std/Test.sol";
import "../../../src/factories/erc404cypher/CypherLiquidityDeployerModule.sol";
import "../../../src/vaults/cypher/CypherAlignmentVault.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockWETH} from "../../mocks/MockWETH.sol";
import {MockAlgebraFactory, MockAlgebraPositionManager, MockAlgebraSwapRouter} from "../../mocks/MockCypherAlgebra.sol";

contract CypherLiquidityDeployerModuleTest is Test {
    CypherLiquidityDeployerModule deployer;
    CypherAlignmentVault vault;
    MockAlgebraFactory algebraFactory;
    MockAlgebraPositionManager positionManager;
    MockAlgebraSwapRouter swapRouter;
    MockERC20 token;
    MockWETH weth;

    address protocolTreasury = makeAddr("treasury");
    address factoryCreator = makeAddr("creator");
    address instance = makeAddr("instance");

    function setUp() public {
        algebraFactory = new MockAlgebraFactory();
        positionManager = new MockAlgebraPositionManager();
        swapRouter = new MockAlgebraSwapRouter();
        token = new MockERC20("Token", "TKN");
        weth = new MockWETH();

        deployer = new CypherLiquidityDeployerModule();

        CypherAlignmentVault impl = new CypherAlignmentVault();
        vault = CypherAlignmentVault(payable(LibClone.clone(address(impl))));
        vault.initialize(
            address(positionManager), address(swapRouter), address(weth),
            address(token), factoryCreator, 100, protocolTreasury,
            address(deployer)  // liquidityDeployer = this module
        );
    }

    function test_deployLiquidity_createsPoolAndMintsLP() public {
        uint256 ethReserve = 1 ether;
        uint256 tokenReserve = 1000e18;

        // Mint tokens to deployer module (simulating transfer from bonding instance)
        token.mint(address(deployer), tokenReserve);
        uint160 sqrtPriceX96 = 79228162514264337593543950336; // ~1:1 ratio

        vm.deal(address(this), ethReserve);
        (uint256 tokenId, address pool) = deployer.deployLiquidity{value: ethReserve}(
            CypherLiquidityDeployerModule.DeployParams({
                ethReserve: ethReserve,
                tokenReserve: tokenReserve,
                sqrtPriceX96: sqrtPriceX96,
                graduationFeeBps: 200,
                creatorGraduationFeeBps: 100,
                protocolTreasury: protocolTreasury,
                factoryCreator: factoryCreator,
                token: address(token),
                weth: address(weth),
                vault: address(vault),
                algebraFactory: address(algebraFactory),
                positionManager: address(positionManager),
                instance: instance
            })
        );

        assertGt(tokenId, 0);
        assertNotEq(pool, address(0));
        assertEq(vault.lpTokenId(), tokenId);
        assertEq(vault.lpPool(), pool);
        // instance is registered with ethToLP as contribution (ethReserve minus fees)
        assertGt(vault.benefactorContribution(instance), 0);
    }

    function test_deployLiquidity_paysGraduationFees() public {
        token.mint(address(deployer), 1000e18);
        uint256 ethReserve = 1 ether;

        vm.deal(address(this), ethReserve);
        uint256 treasuryBefore = protocolTreasury.balance;
        uint256 creatorBefore = factoryCreator.balance;

        deployer.deployLiquidity{value: ethReserve}(
            CypherLiquidityDeployerModule.DeployParams({
                ethReserve: ethReserve,
                tokenReserve: 1000e18,
                sqrtPriceX96: 79228162514264337593543950336,
                graduationFeeBps: 200,
                creatorGraduationFeeBps: 100,
                protocolTreasury: protocolTreasury,
                factoryCreator: factoryCreator,
                token: address(token),
                weth: address(weth),
                vault: address(vault),
                algebraFactory: address(algebraFactory),
                positionManager: address(positionManager),
                instance: instance
            })
        );

        // Protocol gets 2% = 0.02 ETH, creator gets 1% = 0.01 ETH
        assertEq(protocolTreasury.balance - treasuryBefore, 0.02 ether);
        assertEq(factoryCreator.balance - creatorBefore, 0.01 ether);
    }
}
