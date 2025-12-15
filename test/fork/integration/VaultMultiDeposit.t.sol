// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ForkTestBase } from "../helpers/ForkTestBase.sol";

/**
 * @title VaultMultiDeposit
 * @notice Test vault behavior with multiple deposit cycles
 */
contract VaultMultiDepositTest is ForkTestBase {
    function setUp() public {
        loadAddresses();
    }

    function test_twoCycles_sharesDilution() public {
        // TODO: Two cycles, equal contributions get equal shares
        emit log_string("TODO: Two cycle shares dilution");
    }

    function test_threeCycles_proportionalShares() public {
        // TODO: Three cycles with different amounts
        emit log_string("TODO: Three cycle proportional shares");
    }

    function test_contributionAfterLiquidityGrows() public {
        // TODO: New contributor after LP growth
        emit log_string("TODO: Contribution after LP growth");
    }

    function test_claimAfterMultipleCycles_multiClaimSupport() public {
        // TODO: Multi-claim delta calculation
        emit log_string("TODO: Multi-claim support");
    }
}
