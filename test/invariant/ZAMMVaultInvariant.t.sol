// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {ZAMMAlignmentVault, IZAMM} from "../../src/vaults/zamm/ZAMMAlignmentVault.sol";
import {MockZAMM} from "../mocks/MockZAMM.sol";
import {MockZRouter} from "../mocks/MockZRouter.sol";
import {MockEXECToken} from "../mocks/MockEXECToken.sol";
import {ZAMMVaultHandler} from "./handlers/ZAMMVaultHandler.sol";

contract ZAMMVaultInvariantTest is StdInvariant, Test {
    ZAMMAlignmentVault public vault;
    MockZAMM public mockZamm;
    MockZRouter public mockZRouter;
    MockEXECToken public alignmentToken;
    ZAMMVaultHandler public handler;

    address public treasury = address(0x99);
    address[] public actors;

    function setUp() public {
        alignmentToken = new MockEXECToken(10_000_000e18);
        mockZamm = new MockZAMM();
        mockZRouter = new MockZRouter();

        vm.deal(address(mockZamm), 1000 ether);
        vm.deal(address(mockZRouter), 1000 ether);
        alignmentToken.transfer(address(mockZamm), 1_000_000e18);
        alignmentToken.transfer(address(mockZRouter), 1_000_000e18);

        IZAMM.PoolKey memory poolKey = IZAMM.PoolKey({
            id0: 0,
            id1: 0,
            token0: address(0),
            token1: address(alignmentToken),
            feeOrHook: 30
        });

        ZAMMAlignmentVault impl = new ZAMMAlignmentVault();
        vault = ZAMMAlignmentVault(payable(LibClone.clone(address(impl))));
        vault.initialize(
            address(mockZamm),
            address(mockZRouter),
            address(alignmentToken),
            poolKey,
            treasury
        );

        actors.push(address(0xA11CE));
        actors.push(address(0xB0B));
        actors.push(address(0xCAFE));
        actors.push(address(0xDEAD));

        handler = new ZAMMVaultHandler(vault, mockZamm, actors);

        targetContract(address(handler));
    }

    // ── Invariant 1: sum(benefactorContribution[i]) == totalContributions ──

    function invariant_sharesSumEqualsTotal() public view {
        uint256 sumContributions;
        address[] memory a = handler.getActors();
        for (uint256 i = 0; i < a.length; i++) {
            sumContributions += vault.benefactorContribution(a[i]);
        }
        assertEq(
            sumContributions,
            vault.totalContributions(),
            "ZAMM: sum(benefactorContribution) != totalContributions"
        );
    }

    // ── Invariant 2: no phantom ETH ──
    // accumulatedProtocolFees + sum(claimable) <= address(vault).balance
    // MasterChef rounding can produce up to 1 wei of dust per benefactor per harvest,
    // so we allow a tolerance of (actors * conversions) wei.

    function invariant_noPhantomETH() public view {
        if (vault.totalContributions() == 0) return;

        uint256 sumClaimable;
        address[] memory a = handler.getActors();
        for (uint256 i = 0; i < a.length; i++) {
            sumClaimable += vault.calculateClaimableAmount(a[i]);
        }

        uint256 obligations = vault.accumulatedProtocolFees() + sumClaimable;
        // MasterChef accRewardPerContribution rounds down per-unit; the sum of per-benefactor
        // claims can exceed the actual ETH received by at most 1 wei per benefactor per harvest.
        uint256 dustTolerance = a.length * (handler.ghost_conversions() + 1);
        assertLe(
            obligations,
            address(vault).balance + dustTolerance,
            "ZAMM: phantom ETH - obligations exceed balance beyond rounding tolerance"
        );
    }

    // ── Invariant 3: totalPendingETH == balance when no LP deployed ──
    // pendingETH == address(this).balance when totalContributions == 0 (no LP yet)

    function invariant_pendingEqualsBalancePreLP() public view {
        if (vault.totalContributions() > 0) return;
        if (vault.pendingETH() == 0 && address(vault).balance == 0) return;

        assertEq(
            vault.pendingETH(),
            address(vault).balance,
            "ZAMM: pendingETH != balance before LP deployment"
        );
    }

    // ── Invariant 4: no dilution inversion ──
    // No benefactor's settled contribution should exceed their raw ETH input.
    // settled = contrib * deployETH / totalEth, and deployETH <= totalEth (conversion reward deducted),
    // so settled <= contrib always. Combined with invariant 1 (sum == total), this guarantees
    // no benefactor's share percentage exceeds their contribution percentage.

    function invariant_noDilutionInversion() public view {
        address[] memory a = handler.getActors();
        for (uint256 i = 0; i < a.length; i++) {
            uint256 settledContrib = vault.benefactorContribution(a[i]);
            uint256 rawContrib = handler.ghost_actorContributed(a[i]);

            assertLe(
                settledContrib,
                rawContrib,
                "ZAMM: dilution inversion - settled contribution exceeds raw input"
            );
        }

        // Also verify the global sum: totalContributions <= ghost_totalContributed
        assertLe(
            vault.totalContributions(),
            handler.ghost_totalContributed(),
            "ZAMM: total settled exceeds total contributed"
        );
    }

    // ── Invariant 5: pending accounting consistency ──

    function invariant_pendingSumConsistency() public view {
        uint256 sumPending;
        address[] memory a = handler.getActors();
        for (uint256 i = 0; i < a.length; i++) {
            sumPending += vault.pendingContribution(a[i]);
        }
        assertEq(
            sumPending,
            vault.pendingETH(),
            "ZAMM: sum(pendingContribution) != pendingETH"
        );
    }
}
