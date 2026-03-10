// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {UniAlignmentVault} from "../../src/vaults/uni/UniAlignmentVault.sol";
import {TestableUniAlignmentVault} from "../helpers/TestableUniAlignmentVault.sol";
import {MockEXECToken} from "../mocks/MockEXECToken.sol";
import {MockZRouter} from "../mocks/MockZRouter.sol";
import {MockVaultPriceValidator} from "../mocks/MockVaultPriceValidator.sol";
import {MockAlignmentRegistry} from "../mocks/MockAlignmentRegistry.sol";
import {IVaultPriceValidator} from "../../src/interfaces/IVaultPriceValidator.sol";
import {IAlignmentRegistry} from "../../src/master/interfaces/IAlignmentRegistry.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {UniVaultHandler} from "./handlers/UniVaultHandler.sol";

contract UniVaultInvariantTest is StdInvariant, Test {
    UniAlignmentVault public vault;
    MockEXECToken public alignmentToken;
    MockZRouter public mockZRouter;
    MockVaultPriceValidator public mockValidator;
    MockAlignmentRegistry public mockAlignmentRegistry;
    UniVaultHandler public handler;

    address public owner = address(this);
    address public treasury = address(0x99);
    address[] public actors;

    uint256 constant TARGET_ID = 1;

    function setUp() public {
        alignmentToken = new MockEXECToken(10_000_000e18);
        mockZRouter = new MockZRouter();
        mockValidator = new MockVaultPriceValidator();
        mockAlignmentRegistry = new MockAlignmentRegistry();
        mockAlignmentRegistry.setTargetActive(TARGET_ID, true);
        mockAlignmentRegistry.setTokenInTarget(TARGET_ID, address(alignmentToken), true);

        vm.deal(address(mockZRouter), 1000 ether);
        alignmentToken.transfer(address(mockZRouter), 1_000_000e18);

        TestableUniAlignmentVault impl = new TestableUniAlignmentVault();
        vault = TestableUniAlignmentVault(payable(LibClone.clone(address(impl))));
        vault.initialize(
            address(this),
            address(0x1111111111111111111111111111111111111111), // mockWETH
            address(0x2222222222222222222222222222222222222222), // mockPoolManager
            address(alignmentToken),
            address(mockZRouter),
            3000,
            60,
            IVaultPriceValidator(address(mockValidator)),
            IAlignmentRegistry(address(mockAlignmentRegistry)),
            TARGET_ID
        );

        PoolKey memory mockPoolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(alignmentToken)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        vault.setV4PoolKey(mockPoolKey);
        vault.setProtocolTreasury(treasury);

        actors.push(address(0xA11CE));
        actors.push(address(0xB0B));
        actors.push(address(0xCAFE));
        actors.push(address(0xDEAD));

        handler = new UniVaultHandler(vault, actors);

        targetContract(address(handler));
    }

    // ── Invariant 1: sum(benefactorShares[i]) == totalShares ──

    function invariant_sharesSumEqualsTotal() public view {
        uint256 sumShares;
        address[] memory a = handler.getActors();
        for (uint256 i = 0; i < a.length; i++) {
            sumShares += vault.benefactorShares(a[i]);
        }
        assertEq(
            sumShares,
            vault.totalShares(),
            "Uni: sum(benefactorShares) != totalShares"
        );
    }

    // ── Invariant 2: no phantom ETH ──
    // accumulatedProtocolFees + sum(claimable) <= address(vault).balance

    function invariant_noPhantomETH() public view {
        if (vault.totalShares() == 0) return;
        if (vault.accumulatedFees() == 0) return;

        uint256 sumClaimable;
        address[] memory a = handler.getActors();
        for (uint256 i = 0; i < a.length; i++) {
            if (vault.benefactorShares(a[i]) == 0) continue;
            // Use the delta-based unclaimed amount (what would actually be paid)
            uint256 currentShareValue = (vault.accumulatedFees() * vault.benefactorShares(a[i])) / vault.totalShares();
            uint256 unclaimed = currentShareValue > vault.shareValueAtLastClaim(a[i])
                ? currentShareValue - vault.shareValueAtLastClaim(a[i])
                : 0;
            sumClaimable += unclaimed;
        }

        uint256 obligations = vault.accumulatedProtocolFees() + sumClaimable;
        assertLe(
            obligations,
            address(vault).balance,
            "Uni: phantom ETH - obligations exceed balance"
        );
    }

    // ── Invariant 3: totalPendingETH == balance when no LP deployed ──

    function invariant_pendingEqualsBalancePreLP() public view {
        if (vault.totalShares() > 0) return;
        if (vault.accumulatedFees() > 0) return;
        if (vault.totalPendingETH() == 0 && address(vault).balance == 0) return;

        assertEq(
            vault.totalPendingETH(),
            address(vault).balance,
            "Uni: totalPendingETH != balance before LP deployment"
        );
    }

    // ── Invariant 4: no dilution inversion ──
    // Share ordering must be monotonic with contribution ordering:
    // if benefactorTotalETH[a] >= benefactorTotalETH[b], then benefactorShares[a] >= benefactorShares[b]
    // (for actors who both have shares, i.e., have been through at least one conversion).
    // This is weaker than strict ratio equality but immune to double-rounding artifacts.
    //
    // Additionally: no actor's shares can exceed totalShares, and the sum equals totalShares
    // (covered by invariant 1).

    function invariant_noDilutionInversion() public view {
        if (vault.totalShares() == 0) return;

        address[] memory a = handler.getActors();

        // Check monotonicity among converted ETH (excluding pending):
        // if convertedETH[a] >= convertedETH[b], then shares[a] >= shares[b]
        // Only compare actors with no pending ETH (fully settled).
        for (uint256 i = 0; i < a.length; i++) {
            uint256 sharesI = vault.benefactorShares(a[i]);
            if (sharesI == 0) continue;
            if (vault.pendingETH(a[i]) > 0) continue; // skip actors with unconverted contributions

            uint256 convertedI = vault.benefactorTotalETH(a[i]) - vault.pendingETH(a[i]);

            for (uint256 j = i + 1; j < a.length; j++) {
                uint256 sharesJ = vault.benefactorShares(a[j]);
                if (sharesJ == 0) continue;
                if (vault.pendingETH(a[j]) > 0) continue;

                uint256 convertedJ = vault.benefactorTotalETH(a[j]) - vault.pendingETH(a[j]);

                if (convertedI >= convertedJ) {
                    if (sharesJ > sharesI) {
                        // Allow rounding tolerance: 1 share unit per conversion
                        assertLe(
                            sharesJ - sharesI,
                            handler.ghost_conversions(),
                            "Uni: dilution inversion - lower contributor has more shares"
                        );
                    }
                }
            }
        }
    }

    // ── Invariant 5: pending sum consistency ──

    function invariant_pendingSumConsistency() public view {
        uint256 sumPending;
        address[] memory a = handler.getActors();
        for (uint256 i = 0; i < a.length; i++) {
            sumPending += vault.pendingETH(a[i]);
        }
        assertEq(
            sumPending,
            vault.totalPendingETH(),
            "Uni: sum(pendingETH) != totalPendingETH"
        );
    }
}
