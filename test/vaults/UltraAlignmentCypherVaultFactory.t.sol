// test/vaults/UltraAlignmentCypherVaultFactory.t.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "forge-std/Test.sol";
import "../../src/vaults/cypher/UltraAlignmentCypherVaultFactory.sol";
import "../../src/vaults/cypher/UltraAlignmentCypherVault.sol";

contract UltraAlignmentCypherVaultFactoryTest is Test {
    UltraAlignmentCypherVaultFactory factory;

    address positionManager = makeAddr("positionManager");
    address swapRouter = makeAddr("swapRouter");
    address weth = makeAddr("weth");
    address alignmentToken = makeAddr("alignmentToken");
    address creator = makeAddr("creator");
    address treasury = makeAddr("treasury");
    address liquidityDeployer = makeAddr("deployer");

    function setUp() public {
        UltraAlignmentCypherVault impl = new UltraAlignmentCypherVault();
        factory = new UltraAlignmentCypherVaultFactory(address(impl));
    }

    function test_createVault_deploysClone() public {
        UltraAlignmentCypherVault vault = factory.createVault(
            positionManager, swapRouter, weth, alignmentToken,
            creator, 100, treasury, liquidityDeployer
        );
        assertNotEq(address(vault), address(0));
        assertEq(vault.alignmentToken(), alignmentToken);
        assertEq(vault.factoryCreator(), creator);
        assertEq(vault.liquidityDeployer(), liquidityDeployer);
    }

    function test_createVault_multipleVaultsDifferentAddresses() public {
        UltraAlignmentCypherVault v1 = factory.createVault(
            positionManager, swapRouter, weth, alignmentToken,
            creator, 100, treasury, liquidityDeployer
        );
        UltraAlignmentCypherVault v2 = factory.createVault(
            positionManager, swapRouter, weth, alignmentToken,
            creator, 200, treasury, liquidityDeployer
        );
        assertNotEq(address(v1), address(v2));
    }
}
