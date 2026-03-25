// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {ZAMMAlignmentVault, IZAMM} from "../../src/vaults/zamm/ZAMMAlignmentVault.sol";
import {MockZAMM} from "../mocks/MockZAMM.sol";
import {MockZRouter} from "../mocks/MockZRouter.sol";
import {MockEXECToken} from "../mocks/MockEXECToken.sol";

contract Finding1_ZAMMUnboundedArrayTest is Test {
    ZAMMAlignmentVault public vault;
    MockZAMM public mockZamm;
    MockZRouter public mockZRouter;
    MockEXECToken public token;
    IZAMM.PoolKey public poolKey;

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
        vault.initialize(address(mockZamm), address(mockZRouter), address(token), poolKey, address(0x99));
    }

    /// @notice Contributions below MIN_CONTRIBUTION must revert
    function test_receiveContribution_revertsOnBelowMinimum() public {
        address b = address(0xBEEF);
        vm.deal(b, 1 ether);
        vm.expectRevert(ZAMMAlignmentVault.ContributionBelowMinimum.selector);
        vm.prank(b);
        vault.receiveContribution{value: 1 wei}(Currency.wrap(address(0)), 1, b);
    }

    /// @notice The (MAX_PENDING_BENEFACTORS + 1)th unique benefactor must revert
    function test_receiveContribution_revertsWhenCapExceeded() public {
        uint256 cap = vault.MAX_PENDING_BENEFACTORS();
        uint256 minContrib = vault.MIN_CONTRIBUTION();

        for (uint256 i = 0; i < cap; i++) {
            address b = address(uint160(0x1000 + i));
            vm.deal(b, minContrib + 1);
            vm.prank(b);
            vault.receiveContribution{value: minContrib}(Currency.wrap(address(0)), minContrib, b);
        }

        address overflow = address(uint160(0x1000 + cap));
        vm.deal(overflow, minContrib + 1);
        vm.expectRevert(ZAMMAlignmentVault.TooManyPendingBenefactors.selector);
        vm.prank(overflow);
        vault.receiveContribution{value: minContrib}(Currency.wrap(address(0)), minContrib, overflow);
    }

    /// @notice Same address contributing again is always allowed (no new array entry)
    function test_receiveContribution_sameAddressAlwaysAllowed() public {
        address b = address(0xBEEF);
        uint256 minContrib = vault.MIN_CONTRIBUTION();
        vm.deal(b, 10 ether);

        vm.prank(b);
        vault.receiveContribution{value: minContrib}(Currency.wrap(address(0)), minContrib, b);
        vm.prank(b);
        vault.receiveContribution{value: minContrib}(Currency.wrap(address(0)), minContrib, b);
    }
}
