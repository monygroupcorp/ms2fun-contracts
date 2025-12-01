// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title LPPositionValuation
 * @notice Library for tracking LP position values and calculating benefactor stakes
 * @dev Key insight: Benefactor stakes are determined at conversion time by ETH contribution ratio
 *      The ratio is locked and never changes, regardless of LP value fluctuations
 */
library LPPositionValuation {
    // ========== Data Structures ==========

    /**
     * @notice Snapshot of a benefactor's ETH contribution and resulting LP stake
     * @dev Created at conversion time, frozen forever. Tracks claimed vs accrued fees.
     */
    struct BenefactorStake {
        address benefactor;                // The benefactor address
        uint256 ethContributedThisRound;   // ETH amount that went into this conversion
        uint256 stakePercent;              // Percentage of LP position owned (in 1e18 = 100%)
        uint256 snapshotTimestamp;         // When this stake was created
        uint256 totalFeesClaimed;          // Total fees this benefactor has claimed
        uint256 lastClaimTimestamp;        // When they last claimed fees
    }

    /**
     * @notice Metadata about an LP position across pool types
     * @dev Tracks one unified position shared by all benefactors
     */
    struct LPPositionMetadata {
        uint8 poolType;               // 0=V4, 1=V3, 2=V2
        address pool;                 // Pool contract address
        uint256 positionId;           // NFT ID for V3, salt hash for V4, 0 for V2
        address lpTokenAddress;       // Token contract for V2 LP tokens
        uint256 lpTokenBalance;       // For V2: amount of LP tokens held
        uint256 amount0;              // Current amount of token0 in position
        uint256 amount1;              // Current amount of token1 in position
        uint256 accumulatedFees0;     // Uncollected fees in token0
        uint256 accumulatedFees1;     // Uncollected fees in token1
        uint256 lastUpdated;          // Block timestamp of last value calculation
    }

    /**
     * @notice Breakdown of fees owed to a benefactor in terms of both pool tokens
     * @dev Used to inform conversion logic - vault will sell token0 to get ETH
     */
    struct BenefactorFeeBreakdown {
        uint256 token0Amount;         // Amount owed in token0 (non-ETH)
        uint256 token1Amount;         // Amount owed in token1 (ETH or primary token)
        uint256 token0ToSell;         // How much token0 should be sold for ETH
        uint256 ethEquivalent;        // Estimated ETH value of the payout
    }

    // ========== Note on State ==========
    // This library is stateless. The vault that uses it must maintain:
    // - mapping(address => BenefactorStake) benefactorStakes
    // - BenefactorStake[] allBenefactorStakes
    // - LPPositionMetadata currentLPPosition

    // ========== Core Functions ==========

    /**
     * @notice Create benefactor stakes after ETH → LP conversion
     * @dev This is called once per conversion. Stakes are frozen forever.
     * @param benefactorStakes Storage mapping to populate
     * @param allBenefactorStakes Storage array to populate
     * @param benefactors Array of benefactor addresses
     * @param ethContributions Array of ETH amounts contributed (must match benefactors length)
     */
    function createStakesFromETH(
        mapping(address => BenefactorStake) storage benefactorStakes,
        BenefactorStake[] storage allBenefactorStakes,
        address[] memory benefactors,
        uint256[] memory ethContributions
    ) internal returns (BenefactorStake[] memory stakes) {
        require(benefactors.length == ethContributions.length, "Length mismatch");
        require(benefactors.length > 0, "No benefactors");

        // Calculate total ETH
        uint256 totalETH = 0;
        for (uint256 i = 0; i < ethContributions.length; i++) {
            totalETH += ethContributions[i];
        }
        require(totalETH > 0, "No ETH to distribute");

        // Create stake for each benefactor
        stakes = new BenefactorStake[](benefactors.length);
        for (uint256 i = 0; i < benefactors.length; i++) {
            address benefactor = benefactors[i];
            uint256 contribution = ethContributions[i];

            // Calculate stake as percentage (in 1e18 for precision)
            // stake = (contribution / totalETH) * 1e18
            uint256 stakePercent = (contribution * 1e18) / totalETH;

            stakes[i] = BenefactorStake({
                benefactor: benefactor,
                ethContributedThisRound: contribution,
                stakePercent: stakePercent,
                snapshotTimestamp: block.timestamp,
                totalFeesClaimed: 0,
                lastClaimTimestamp: 0
            });

            // Store in mapping
            benefactorStakes[benefactor] = stakes[i];
            allBenefactorStakes.push(stakes[i]);
        }

        return stakes;
    }

    /**
     * @notice Calculate unclaimed fee share for a benefactor
     * @param benefactorStakes Storage mapping of benefactor stakes
     * @param benefactor The benefactor address
     * @param totalAccumulatedFees Total fees that have accumulated
     * @return unclaimedFees Amount of fees available to claim (total share - already claimed)
     */
    function calculateUnclaimedFees(
        mapping(address => BenefactorStake) storage benefactorStakes,
        address benefactor,
        uint256 totalAccumulatedFees
    ) internal view returns (uint256 unclaimedFees) {
        BenefactorStake memory stake = benefactorStakes[benefactor];
        require(stake.benefactor != address(0), "Benefactor not found");

        // Total fees owed to this benefactor
        // totalOwed = (stakePercent / 1e18) * totalAccumulatedFees
        uint256 totalOwed = (stake.stakePercent * totalAccumulatedFees) / 1e18;

        // Unclaimed = totalOwed - alreadyClaimed
        if (totalOwed <= stake.totalFeesClaimed) {
            return 0;
        }
        return totalOwed - stake.totalFeesClaimed;
    }

    /**
     * @notice Record that a benefactor has claimed fees
     * @param benefactorStakes Storage mapping of benefactor stakes
     * @param benefactor The benefactor address
     * @param amountClaimed Amount of fees being claimed
     */
    function recordFeeClaim(
        mapping(address => BenefactorStake) storage benefactorStakes,
        address benefactor,
        uint256 amountClaimed
    ) internal {
        BenefactorStake storage stake = benefactorStakes[benefactor];
        require(stake.benefactor != address(0), "Benefactor not found");

        stake.totalFeesClaimed += amountClaimed;
        stake.lastClaimTimestamp = block.timestamp;
    }

    /**
     * @notice Record LP position metadata after conversion
     * @param currentLPPosition Storage reference to LP position metadata
     * @param poolType Pool type (0=V4, 1=V3, 2=V2)
     * @param pool Pool contract address
     * @param positionId Position ID (NFT ID for V3, salt for V4, 0 for V2)
     * @param lpTokenAddress For V2: address of LP token contract
     * @param amount0 Amount of token0 in position
     * @param amount1 Amount of token1 in position
     */
    function recordLPPosition(
        LPPositionMetadata storage currentLPPosition,
        uint8 poolType,
        address pool,
        uint256 positionId,
        address lpTokenAddress,
        uint256 amount0,
        uint256 amount1
    ) internal {
        currentLPPosition.poolType = poolType;
        currentLPPosition.pool = pool;
        currentLPPosition.positionId = positionId;
        currentLPPosition.lpTokenAddress = lpTokenAddress;
        currentLPPosition.lpTokenBalance = 0;
        currentLPPosition.amount0 = amount0;
        currentLPPosition.amount1 = amount1;
        currentLPPosition.accumulatedFees0 = 0;
        currentLPPosition.accumulatedFees1 = 0;
        currentLPPosition.lastUpdated = block.timestamp;
    }

    /**
     * @notice Update LP token balance (for V2 positions)
     * @param currentLPPosition Storage reference to LP position metadata
     * @param lpTokenBalance Amount of LP tokens held
     */
    function updateLPTokenBalance(
        LPPositionMetadata storage currentLPPosition,
        uint256 lpTokenBalance
    ) internal {
        currentLPPosition.lpTokenBalance = lpTokenBalance;
        currentLPPosition.lastUpdated = block.timestamp;
    }

    /**
     * @notice Update position amount0 and amount1 (for all pool types)
     * @param currentLPPosition Storage reference to LP position metadata
     * @param amount0 New amount of token0
     * @param amount1 New amount of token1
     */
    function updatePositionAmounts(
        LPPositionMetadata storage currentLPPosition,
        uint256 amount0,
        uint256 amount1
    ) internal {
        currentLPPosition.amount0 = amount0;
        currentLPPosition.amount1 = amount1;
        currentLPPosition.lastUpdated = block.timestamp;
    }

    /**
     * @notice Update accumulated fees
     * @param currentLPPosition Storage reference to LP position metadata
     * @param fees0 Accumulated fees in token0
     * @param fees1 Accumulated fees in token1
     */
    function updateAccumulatedFees(
        LPPositionMetadata storage currentLPPosition,
        uint256 fees0,
        uint256 fees1
    ) internal {
        currentLPPosition.accumulatedFees0 = fees0;
        currentLPPosition.accumulatedFees1 = fees1;
        currentLPPosition.lastUpdated = block.timestamp;
    }

    // ========== View Functions ==========

    /**
     * @notice Get stake percentage for a benefactor
     * @param benefactorStakes Storage mapping of benefactor stakes
     * @param benefactor Address of benefactor
     * @return percentage Stake as percentage (in 1e18)
     */
    function getStakePercent(
        mapping(address => BenefactorStake) storage benefactorStakes,
        address benefactor
    ) internal view returns (uint256 percentage) {
        return benefactorStakes[benefactor].stakePercent;
    }

    /**
     * @notice Check if benefactor has a registered stake
     * @param benefactorStakes Storage mapping of benefactor stakes
     * @param benefactor Address to check
     * @return hasStake True if benefactor was part of last conversion
     */
    function hasStake(
        mapping(address => BenefactorStake) storage benefactorStakes,
        address benefactor
    ) internal view returns (bool hasStake) {
        return benefactorStakes[benefactor].benefactor != address(0);
    }

    /**
     * @notice Get all benefactor stakes from last conversion
     * @param allBenefactorStakes Storage array of all benefactor stakes
     * @return All stakes that are currently active
     */
    function getAllStakes(
        BenefactorStake[] storage allBenefactorStakes
    ) internal view returns (BenefactorStake[] memory) {
        return allBenefactorStakes;
    }

    /**
     * @notice Get current LP position metadata
     * @param currentLPPosition Storage reference to LP position metadata
     * @return Position metadata
     */
    function getLPPosition(
        LPPositionMetadata storage currentLPPosition
    ) internal view returns (LPPositionMetadata memory) {
        return currentLPPosition;
    }

    /**
     * @notice Get LP position type
     * @param currentLPPosition Storage reference to LP position metadata
     * @return poolType 0=V4, 1=V3, 2=V2
     */
    function getPoolType(
        LPPositionMetadata storage currentLPPosition
    ) internal view returns (uint8 poolType) {
        return currentLPPosition.poolType;
    }

    /**
     * @notice Calculate total value locked in LP position (in token1 terms, typically ETH)
     * @dev This is a simplified calculation. Real value would need price feeds.
     * @param currentLPPosition Storage reference to LP position metadata
     * @return totalValue Sum of amount0 + amount1 (assumes token0 and token1 are comparable)
     */
    function estimateTotalLPValue(
        LPPositionMetadata storage currentLPPosition
    ) internal view returns (uint256 totalValue) {
        // Simplified: assumes amount0 and amount1 are in same denomination
        // In production, would need proper price conversion
        return currentLPPosition.amount0 + currentLPPosition.amount1;
    }

    // ========== Utility Functions ==========

    /**
     * @notice Clear all stakes (for next conversion cycle)
     * @param allBenefactorStakes Storage array of all benefactor stakes
     * @param currentLPPosition Storage reference to LP position metadata
     */
    function clearStakes(
        BenefactorStake[] storage allBenefactorStakes,
        LPPositionMetadata storage currentLPPosition
    ) internal {
        while (allBenefactorStakes.length > 0) {
            allBenefactorStakes.pop();
        }
        currentLPPosition.poolType = 0;
        currentLPPosition.pool = address(0);
        currentLPPosition.positionId = 0;
        currentLPPosition.lpTokenAddress = address(0);
        currentLPPosition.lpTokenBalance = 0;
        currentLPPosition.amount0 = 0;
        currentLPPosition.amount1 = 0;
        currentLPPosition.accumulatedFees0 = 0;
        currentLPPosition.accumulatedFees1 = 0;
        currentLPPosition.lastUpdated = 0;
    }

    /**
     * @notice Verify conversion was recorded with stakes
     * @param allBenefactorStakes Storage array of all benefactor stakes
     * @return hasActiveStakes True if stakes exist from last conversion
     */
    function hasActiveStakes(
        BenefactorStake[] storage allBenefactorStakes
    ) internal view returns (bool hasActiveStakes) {
        return allBenefactorStakes.length > 0;
    }
}
