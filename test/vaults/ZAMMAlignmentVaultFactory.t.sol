// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ZAMMAlignmentVaultFactory} from "../../src/vaults/zamm/ZAMMAlignmentVaultFactory.sol";
import {ZAMMAlignmentVault, IZAMM} from "../../src/vaults/zamm/ZAMMAlignmentVault.sol";
import {MockZAMM} from "../mocks/MockZAMM.sol";
import {MockZRouter} from "../mocks/MockZRouter.sol";
import {MockEXECToken} from "../mocks/MockEXECToken.sol";
import {CREATEX} from "../../src/shared/CreateXConstants.sol";
import {CREATEX_BYTECODE} from "createx-forge/script/CreateX.d.sol";

contract ZAMMAlignmentVaultFactoryTest is Test {
    ZAMMAlignmentVaultFactory public factory;
    uint256 internal _saltCounter;
    MockZAMM public mockZamm;
    MockZRouter public mockZRouter;
    MockEXECToken public alignmentToken;

    address public treasury = address(0x99);

    IZAMM.PoolKey public poolKey;

    event VaultDeployed(address indexed vault, address indexed alignmentToken);

    function _nextSalt() internal returns (bytes32) {
        _saltCounter++;
        return bytes32(abi.encodePacked(address(factory), uint8(0x00), bytes11(uint88(_saltCounter))));
    }

    function setUp() public {
        vm.etch(CREATEX, CREATEX_BYTECODE);
        mockZamm = new MockZAMM();
        mockZRouter = new MockZRouter();
        alignmentToken = new MockEXECToken(1_000_000e18);

        poolKey = IZAMM.PoolKey({
            id0: 0,
            id1: 0,
            token0: address(0),
            token1: address(alignmentToken),
            feeOrHook: 30
        });

        factory = new ZAMMAlignmentVaultFactory(
            address(mockZamm),
            address(mockZRouter),
            treasury
        );
    }

    function test_deployVault_returnsAddress() public {
        address vault = factory.deployVault(_nextSalt(), address(alignmentToken), poolKey);
        assertTrue(vault != address(0));
    }

    function test_deployVault_isInitialized() public {
        address vault = factory.deployVault(_nextSalt(), address(alignmentToken), poolKey);
        ZAMMAlignmentVault v = ZAMMAlignmentVault(payable(vault));
        assertEq(v.alignmentToken(), address(alignmentToken));
        assertEq(v.zamm(), address(mockZamm));
        assertEq(v.protocolYieldCutBps(), 100);
    }

    function test_deployVault_emitsEvent() public {
        vm.expectEmit(false, false, false, false);
        emit VaultDeployed(address(0), address(alignmentToken));
        factory.deployVault(_nextSalt(), address(alignmentToken), poolKey);
    }

    function test_vaultImplementation_isShared() public {
        address impl = factory.vaultImplementation();
        assertTrue(impl != address(0));

        address v1 = factory.deployVault(_nextSalt(), address(alignmentToken), poolKey);

        MockEXECToken t2 = new MockEXECToken(1e18);
        IZAMM.PoolKey memory pk2 = IZAMM.PoolKey(0, 0, address(0), address(t2), 30);
        address v2 = factory.deployVault(_nextSalt(), address(t2), pk2);

        assertTrue(v1 != v2);
        assertTrue(v1 != impl);
    }
}
