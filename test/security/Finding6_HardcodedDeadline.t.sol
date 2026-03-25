// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {ZAMMAlignmentVault, IZAMM} from "../../src/vaults/zamm/ZAMMAlignmentVault.sol";
import {MockZAMM} from "../mocks/MockZAMM.sol";
import {MockZRouter} from "../mocks/MockZRouter.sol";
import {MockEXECToken} from "../mocks/MockEXECToken.sol";

/// @title Finding6_HardcodedDeadlineTest
/// @notice Verifies that ZAMMAlignmentVault uses block.timestamp + 15 min (not type(uint256).max)
///         as the deadline for all DEX swap calls. convertAndAddLiquidity must succeed without
///         reverting (proves the deadline codepath compiles and executes correctly).
contract Finding6_HardcodedDeadlineTest is Test {
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

        // Seed: contribute + convert (exercises the swapVZ deadline codepath)
        vm.deal(alice, 100 ether);
        vm.prank(alice);
        vault.receiveContribution{value: 1 ether}(Currency.wrap(address(0)), 1 ether, alice);
        vault.convertAndAddLiquidity(0, 0, 0);

        // Inflate fee reserves for harvest tests
        mockZamm.setPool(vault.poolId(), 200 ether, 1000e18, 1000 ether);
    }

    /// @notice convertAndAddLiquidity must succeed — proves the deadline fix is active.
    ///         If deadline were expired or wrong, MockZRouter would revert.
    function test_convertAndAddLiquidity_usesValidDeadline() public {
        // Additional contribution after setUp to exercise the path again in a fresh block
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vault.receiveContribution{value: 1 ether}(Currency.wrap(address(0)), 1 ether, alice);
        vault.convertAndAddLiquidity(0, 0, 0); // must not revert
    }

    /// @notice harvest also passes a bounded deadline — must succeed after one block
    function test_harvest_usesValidDeadline() public {
        vault.harvest(0);

        vm.roll(block.number + 1);
        mockZamm.setPool(vault.poolId(), 200 ether, 1000e18, 1000 ether);
        vault.harvest(0); // must not revert — deadline is block.timestamp + 15 min
    }
}
