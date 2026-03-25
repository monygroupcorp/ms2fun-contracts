// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {ZAMMAlignmentVault, IZAMM} from "../../src/vaults/zamm/ZAMMAlignmentVault.sol";
import {MockZAMM} from "../mocks/MockZAMM.sol";
import {MockZRouter} from "../mocks/MockZRouter.sol";
import {MockEXECToken} from "../mocks/MockEXECToken.sol";

contract Finding3_ZAMMHarvestSameBlockTest is Test {
    ZAMMAlignmentVault public vault;
    MockZAMM public mockZamm;
    MockZRouter public mockZRouter;
    MockEXECToken public token;
    IZAMM.PoolKey public poolKey;

    address alice    = address(0xA);
    address treasury = address(0x99);

    function setUp() public {
        token = new MockEXECToken(1_000_000e18);
        mockZamm = new MockZAMM();
        mockZRouter = new MockZRouter();
        vm.deal(address(mockZamm), 100 ether);
        vm.deal(address(mockZRouter), 100 ether);
        token.transfer(address(mockZamm), 100_000e18);
        token.transfer(address(mockZRouter), 100_000e18);

        poolKey = IZAMM.PoolKey({id0: 0, id1: 0, token0: address(0), token1: address(token), feeOrHook: 30});

        ZAMMAlignmentVault impl = new ZAMMAlignmentVault();
        vault = ZAMMAlignmentVault(payable(LibClone.clone(address(impl))));
        vault.initialize(address(mockZamm), address(mockZRouter), address(token), poolKey, treasury);

        // Seed: contribute + convert
        vm.deal(alice, 100 ether);
        vm.prank(alice);
        vault.receiveContribution{value: 1 ether}(Currency.wrap(address(0)), 1 ether, alice);
        vault.convertAndAddLiquidity(0, 0, 0);

        // Simulate fee growth: inflate reserves so harvest detects fees
        mockZamm.setPool(vault.poolId(), 200 ether, 1000e18, 1000 ether);
    }

    /// @notice Two harvest calls in same block must revert on the second
    function test_harvest_revertsOnSameBlockCall() public {
        vault.harvest(0);

        vm.expectRevert(ZAMMAlignmentVault.HarvestSameBlock.selector);
        vault.harvest(0);
    }

    /// @notice Harvest in a subsequent block succeeds
    function test_harvest_succeedsInNextBlock() public {
        vault.harvest(0);

        vm.roll(block.number + 1);
        mockZamm.setPool(vault.poolId(), 200 ether, 1000e18, 1000 ether);
        vault.harvest(0);
    }
}
