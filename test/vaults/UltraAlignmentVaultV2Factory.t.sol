// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {UltraAlignmentVaultV2Factory} from "../../src/vaults/UltraAlignmentVaultV2Factory.sol";
import {UltraAlignmentVaultV2, IZAMM} from "../../src/vaults/UltraAlignmentVaultV2.sol";
import {MockZAMM} from "../mocks/MockZAMM.sol";
import {MockZRouter} from "../mocks/MockZRouter.sol";
import {MockEXECToken} from "../mocks/MockEXECToken.sol";

contract UltraAlignmentVaultV2FactoryTest is Test {
    UltraAlignmentVaultV2Factory public factory;
    MockZAMM public mockZamm;
    MockZRouter public mockZRouter;
    MockEXECToken public alignmentToken;

    address public creator = address(0xC1EA);
    address public treasury = address(0x99);

    IZAMM.PoolKey public poolKey;

    event VaultDeployed(address indexed vault, address indexed alignmentToken, address indexed creator);

    function setUp() public {
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

        factory = new UltraAlignmentVaultV2Factory(
            address(mockZamm),
            address(mockZRouter),
            treasury
        );
    }

    function test_deployVault_returnsAddress() public {
        address vault = factory.deployVault(address(alignmentToken), poolKey, creator, 100);
        assertTrue(vault != address(0));
    }

    function test_deployVault_isInitialized() public {
        address vault = factory.deployVault(address(alignmentToken), poolKey, creator, 100);
        UltraAlignmentVaultV2 v = UltraAlignmentVaultV2(payable(vault));
        assertEq(v.alignmentToken(), address(alignmentToken));
        assertEq(v.factoryCreator(), creator);
        assertEq(v.zamm(), address(mockZamm));
    }

    function test_deployVault_emitsEvent() public {
        vm.expectEmit(false, false, false, false);
        emit VaultDeployed(address(0), address(alignmentToken), creator);
        factory.deployVault(address(alignmentToken), poolKey, creator, 100);
    }

    function test_deployVault_differentCreatorCuts() public {
        // 0% creator cut
        address v1 = factory.deployVault(address(alignmentToken), poolKey, creator, 0);
        assertEq(UltraAlignmentVaultV2(payable(v1)).creatorYieldCutBps(), 0);

        // 500bps (max)
        MockEXECToken t2 = new MockEXECToken(1e18);
        IZAMM.PoolKey memory pk2 = IZAMM.PoolKey(0, 0, address(0), address(t2), 30);
        address v2 = factory.deployVault(address(t2), pk2, creator, 500);
        assertEq(UltraAlignmentVaultV2(payable(v2)).creatorYieldCutBps(), 500);
    }

    function test_deployVault_revertExcessCreatorCut() public {
        vm.expectRevert();
        factory.deployVault(address(alignmentToken), poolKey, creator, 501);
    }

    function test_vaultImplementation_isShared() public {
        address impl = factory.vaultImplementation();
        assertTrue(impl != address(0));

        address v1 = factory.deployVault(address(alignmentToken), poolKey, creator, 100);

        MockEXECToken t2 = new MockEXECToken(1e18);
        IZAMM.PoolKey memory pk2 = IZAMM.PoolKey(0, 0, address(0), address(t2), 30);
        address v2 = factory.deployVault(address(t2), pk2, creator, 100);

        // Both are clones of the same implementation, addresses differ
        assertTrue(v1 != v2);
        assertTrue(v1 != impl);
    }
}
