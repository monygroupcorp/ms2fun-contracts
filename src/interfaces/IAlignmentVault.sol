// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Currency} from "v4-core/types/Currency.sol";

/**
 * @title IAlignmentVault
 * @notice Standard interface for alignment vaults compatible with ms2fun ecosystem
 * @dev All vaults must implement this interface to be approved by governance
 *
 * Design Philosophy:
 * - Vaults receive alignment taxes from project instances
 * - Vaults track contributors as "benefactors" and issue proportional shares
 * - Benefactors can claim accumulated fees based on their share percentage
 * - Vaults are responsible for yield generation strategy (V4 LP, Aave, Curve, etc.)
 * - Instances remain vault-agnostic and interact only via this interface
 *
 * Compliance Requirements:
 * 1. Must accept ETH via receiveHookTax() and receive()
 * 2. Must track benefactor contributions and issue shares
 * 3. Must allow benefactors to claim proportional fees
 * 4. Must emit standard events for transparency
 * 5. Must declare vaultType() for governance classification
 */
interface IAlignmentVault {
    // ========== Events ==========

    /**
     * @notice Emitted when a benefactor contributes ETH to the vault
     * @param benefactor Address credited for the contribution
     * @param amount ETH amount received
     */
    event ContributionReceived(address indexed benefactor, uint256 amount);

    /**
     * @notice Emitted when a benefactor claims accumulated fees
     * @param benefactor Address that claimed fees
     * @param ethAmount ETH amount transferred to benefactor
     */
    event FeesClaimed(address indexed benefactor, uint256 ethAmount);

    /**
     * @notice Emitted when vault accumulates new fees from yield generation
     * @param amount New fees added to vault's accumulated total
     */
    event FeesAccumulated(uint256 amount);

    // ========== Fee Reception ==========

    /**
     * @notice Receive alignment taxes from V4 hooks with explicit benefactor attribution
     * @dev Called by project instances when routing fees to vault
     *      - V4 hooks call this after collecting swap taxes
     *      - ERC1155 instances call this during creator withdrawals
     *      - Must track 'benefactor' as the contributor (not msg.sender)
     *      - Must emit ContributionReceived event
     *
     * @param currency Currency of the tax (native ETH = address(0), or ERC20)
     * @param amount Amount of tax received (in wei or token units)
     * @param benefactor Address to credit for this contribution (the project instance)
     */
    function receiveHookTax(
        Currency currency,
        uint256 amount,
        address benefactor
    ) external payable;

    /**
     * @notice Receive native ETH contributions via fallback
     * @dev Must track msg.sender as benefactor when ETH sent directly
     *      Implementation should call _trackBenefactorContribution(msg.sender, msg.value)
     *      Used when instances send ETH without calling receiveHookTax()
     */
    receive() external payable;

    // ========== Fee Claiming ==========

    /**
     * @notice Claim accumulated fees for caller
     * @dev Must calculate proportional share based on benefactor's contribution
     *      Formula: claimable = (accumulatedFees × benefactorShares[caller]) ÷ totalShares
     *
     *      Multi-claim support:
     *      - Track shareValueAtLastClaim[benefactor] for delta calculation
     *      - Only pay unclaimed amount since last claim
     *      - Update shareValueAtLastClaim after transfer
     *
     * @return ethClaimed Amount of ETH transferred to caller
     */
    function claimFees() external returns (uint256 ethClaimed);

    /**
     * @notice Calculate claimable amount for benefactor without claiming
     * @dev Read-only version of claimFees() for UI/integration queries
     *      Should return total proportional share (not delta)
     *
     * @param benefactor Address to query
     * @return Amount of ETH claimable by this benefactor (total, not delta)
     */
    function calculateClaimableAmount(address benefactor) external view returns (uint256);

    // ========== Share Queries ==========

    /**
     * @notice Get benefactor's total historical contribution
     * @dev Used for leaderboards and "bragging rights"
     *      This is cumulative lifetime contribution, never decreases
     *
     * @param benefactor Address to query
     * @return Total ETH contributed by this benefactor (all-time)
     */
    function getBenefactorContribution(address benefactor) external view returns (uint256);

    /**
     * @notice Get benefactor's current share balance
     * @dev Shares represent proportional ownership of vault fees
     *      Share units are vault-specific (not standardized)
     *      Used for calculating fee claims: (accumulatedFees × shares) ÷ totalShares
     *
     * @param benefactor Address to query
     * @return Share balance in vault-specific units
     */
    function getBenefactorShares(address benefactor) external view returns (uint256);

    // ========== Vault Info ==========

    /**
     * @notice Get vault implementation type identifier
     * @dev Used by governance for classification and risk assessment
     *      Examples: "UniswapV4LP", "AaveYield", "CurveStable", "UniswapV5LP"
     *      Must be non-empty string
     *
     * @return Vault type identifier (human-readable string)
     */
    function vaultType() external view returns (string memory);

    /**
     * @notice Get vault description for frontend display
     * @dev Human-readable description of vault strategy and purpose
     *      Examples:
     *      - "Full-range liquidity provision on Uniswap V4 with auto-compounding"
     *      - "Low-risk stable yield via Aave ETH lending"
     *      - "Curve stablecoin pools with minimal impermanent loss"
     *
     * @return Vault description (1-2 sentences)
     */
    function description() external view returns (string memory);

    /**
     * @notice Get total accumulated fees in vault
     * @dev Represents total ETH available for benefactor claims
     *      Increases when yield is generated, decreases when fees claimed
     *
     * @return Total ETH fees accumulated (in wei)
     */
    function accumulatedFees() external view returns (uint256);

    /**
     * @notice Get total shares issued across all benefactors
     * @dev Used in proportional calculations: benefactorShare ÷ totalShares
     *      Increases when new shares issued during conversions
     *      May increase when dust is distributed
     *
     * @return Total shares across all benefactors (vault-specific units)
     */
    function totalShares() external view returns (uint256);
}
