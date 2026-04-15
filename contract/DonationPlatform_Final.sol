// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./DonationAdmin.sol";
import "./DonationInitiatives.sol";
import "./DonationCampaigns.sol";
import "./DonationZakat.sol";

/**
 * @title  DonationPlatform (Final, Modularized)
 * @author Your Team
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * FEATURE SUMMARY
 * ═══════════════════════════════════════════════════════════════════════════
 *
 * This contract has been refactored into multiple modular base mixins for
 * standardization and separation of concerns.
 *
 * Inherits:
 *  - DonationAdmin: Owner configuration and roles management
 *  - DonationInitiatives: Grouping multiple campaigns under initiatives
 *  - DonationCampaigns: Core escrow, deduplication, trust-gated withdrawals
 *  - DonationZakat: Specialized Zakat collection and batch distribution
 */
contract DonationPlatform is
    DonationAdmin,
    DonationInitiatives,
    DonationCampaigns,
    DonationZakat
{
    /**
     * @param _nisabThreshold  Minimum Zakat donation in wei.
     *                         Example: pass 50000000000000000 for 0.05 ETH.
     *                         Set to 0 to disable the nisab check initially
     *                         (use setNisabThreshold() to enable later).
     */
    constructor(uint256 _nisabThreshold) {
        owner             = msg.sender;
        nisabThreshold    = _nisabThreshold;
        isTrustee[msg.sender] = true;
        
        // Disable cap and uniqueness implicitly by leaving variables logically false/0
        // monthlyReceiverCap = 0;
        // creatorUniquenessEnabled = false;

        emit TrusteeUpdated(msg.sender, true);
    }

    // =========================================================================
    // FALLBACK — reject accidental ETH transfers
    // =========================================================================

    receive()  external payable { revert("DonationPlatform: use donate(), donateZakat(), or donateToInitiative()"); }
    fallback() external payable { revert("DonationPlatform: use donate(), donateZakat(), or donateToInitiative()"); }
}
