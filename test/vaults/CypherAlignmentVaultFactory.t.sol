// test/vaults/CypherAlignmentVaultFactory.t.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "forge-std/Test.sol";
import "../../src/vaults/cypher/CypherAlignmentVaultFactory.sol";
import "../../src/vaults/cypher/CypherAlignmentVault.sol";

contract CypherAlignmentVaultFactoryTest is Test {
    CypherAlignmentVaultFactory factory;

    address positionManager = makeAddr("positionManager");
    address swapRouter = makeAddr("swapRouter");
    address weth = makeAddr("weth");
    address alignmentToken = makeAddr("alignmentToken");
    address treasury = makeAddr("treasury");
    address liquidityDeployer = makeAddr("deployer");

    function setUp() public {
        CypherAlignmentVault impl = new CypherAlignmentVault();
        factory = new CypherAlignmentVaultFactory(address(impl));
    }

    function test_createVault_deploysClone() public {
        CypherAlignmentVault vault = factory.createVault(
            positionManager, swapRouter, weth, alignmentToken,
            treasury, liquidityDeployer
        );
        assertNotEq(address(vault), address(0));
        assertEq(vault.alignmentToken(), alignmentToken);
        assertEq(vault.liquidityDeployer(), liquidityDeployer);
        assertEq(vault.protocolYieldCutBps(), 100);
    }

    function test_createVault_multipleVaultsDifferentAddresses() public {
        CypherAlignmentVault v1 = factory.createVault(
            positionManager, swapRouter, weth, alignmentToken,
            treasury, liquidityDeployer
        );
        CypherAlignmentVault v2 = factory.createVault(
            positionManager, swapRouter, weth, alignmentToken,
            treasury, liquidityDeployer
        );
        assertNotEq(address(v1), address(v2));
    }
}
