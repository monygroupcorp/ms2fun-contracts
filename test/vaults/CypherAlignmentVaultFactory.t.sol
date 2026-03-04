// test/vaults/CypherAlignmentVaultFactory.t.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "forge-std/Test.sol";
import "../../src/vaults/cypher/CypherAlignmentVaultFactory.sol";
import "../../src/vaults/cypher/CypherAlignmentVault.sol";
import {CREATEX} from "../../src/shared/CreateXConstants.sol";
import {CREATEX_BYTECODE} from "createx-forge/script/CreateX.d.sol";

contract CypherAlignmentVaultFactoryTest is Test {
    CypherAlignmentVaultFactory factory;
    uint256 internal _saltCounter;

    address positionManager = makeAddr("positionManager");
    address swapRouter = makeAddr("swapRouter");
    address weth = makeAddr("weth");
    address alignmentToken = makeAddr("alignmentToken");
    address treasury = makeAddr("treasury");
    address liquidityDeployer = makeAddr("deployer");

    function _nextSalt() internal returns (bytes32) {
        _saltCounter++;
        return bytes32(abi.encodePacked(address(factory), uint8(0x00), bytes11(uint88(_saltCounter))));
    }

    function setUp() public {
        vm.etch(CREATEX, CREATEX_BYTECODE);
        CypherAlignmentVault impl = new CypherAlignmentVault();
        factory = new CypherAlignmentVaultFactory(address(impl));
    }

    function test_createVault_deploysClone() public {
        CypherAlignmentVault vault = factory.createVault(
            _nextSalt(),
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
            _nextSalt(),
            positionManager, swapRouter, weth, alignmentToken,
            treasury, liquidityDeployer
        );
        CypherAlignmentVault v2 = factory.createVault(
            _nextSalt(),
            positionManager, swapRouter, weth, alignmentToken,
            treasury, liquidityDeployer
        );
        assertNotEq(address(v1), address(v2));
    }
}
