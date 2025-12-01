// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "solady/auth/Ownable.sol";

/**
 * @title SimpleBeneficiary
 * @notice Phase 1 beneficiary module - simple fee receiver management
 * @dev This is a minimal module that the vault calls when fees accumulate.
 *
 * Purpose:
 * - Designate a receiver address for accumulated fees
 * - Allow owner to change receiver
 * - Track when fees are accumulated (for off-chain analytics)
 *
 * This contract is intentionally simple and focused.
 * Benefactor staking/distribution is deferred to Phase 2.
 *
 * Upgrade Path:
 * When ready for Phase 2, deploy VaultBenefactorDistribution with full staking logic
 * and call: vault.setBeneficiaryModule(newModule)
 * This contract will be replaced (but can keep running if needed).
 */
contract SimpleBeneficiary is Ownable {
    // Constants
    address public constant ZERO_ADDRESS = address(0);

    // State
    address public vault;
    address public receiver;

    // Events
    event ReceiverSet(address indexed newReceiver);
    event FeesAccumulated(uint256 amount);

    /**
     * @notice Initialize the module
     * @param _vault Address of UltraAlignmentVault
     * @param _initialReceiver Address that will receive fees (e.g., Treasury)
     */
    constructor(address _vault, address _initialReceiver) {
        require(_vault != address(0), "Invalid vault");
        require(_initialReceiver != address(0), "Invalid receiver");

        _initializeOwner(msg.sender);
        vault = _vault;
        receiver = _initialReceiver;
    }

    /**
     * @notice Called by vault when fees are accumulated
     * @dev This is the callback that UltraAlignmentVault invokes.
     *      In Phase 1, we just emit an event for tracking.
     *      In Phase 2, a new module will implement distribution logic here.
     *
     * @param amount Amount of fees accumulated (in wei)
     */
    function onFeeAccumulated(uint256 amount) external {
        require(msg.sender == vault, "Only vault can call");
        require(amount > 0, "Amount must be positive");

        // In Phase 1: Just track that fees came in
        // (Actual withdrawal is done separately by admin)
        emit FeesAccumulated(amount);
    }

    /**
     * @notice Set the receiver address for vault fee withdrawals
     * @param newReceiver Address that should receive fees
     *        Can be: Treasury multisig, DAO contract, burn address, etc.
     */
    function setReceiver(address newReceiver) external onlyOwner {
        require(newReceiver != address(0), "Invalid receiver");
        receiver = newReceiver;
        emit ReceiverSet(newReceiver);
    }

    /**
     * @notice Get current receiver address
     * @return The address designated to receive vault fees
     */
    function getReceiver() external view returns (address) {
        return receiver;
    }

    /**
     * @notice Get vault address
     * @return The address of the UltraAlignmentVault
     */
    function getVault() external view returns (address) {
        return vault;
    }

    /**
     * @notice Check if this module is valid
     * @dev Can be used by external systems to verify module integrity
     * @return true (always, if not reverted)
     */
    function isValid() external pure returns (bool) {
        return true;
    }
}

/**
 * ========== Phase 2 Upgrade Path ==========
 *
 * When you're ready to add benefactor staking (Phase 2):
 *
 * 1. Deploy VaultBenefactorDistribution:
 *    VaultBenefactorDistribution v2 = new VaultBenefactorDistribution(vault, ...);
 *
 * 2. Migrate receiver (optional):
 *    v2.setInitialReceiver(simpleBeneficiary.getReceiver());
 *
 * 3. Connect to vault:
 *    vault.setBeneficiaryModule(address(v2));
 *
 * 4. Result:
 *    - SimpleBeneficiary no longer called
 *    - VaultBenefactorDistribution now receives onFeeAccumulated() calls
 *    - Benefactors can start staking and earning fees
 *    - Vault code: 0 changes ✅
 *
 * ==========================================
 */
