// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IDonationPlatform {

    enum CampaignStatus {
        Active,      // accepting donations
        Successful,  // goal reached; awaiting or approved for withdrawal
        Failed,      // deadline passed without meeting goal; refunds open
        Closed       // funds fully withdrawn
    }

    enum ZakatAsnaf {
        Fuqara,       // 0 — the poor
        Masakeen,     // 1 — the needy
        Amileen,      // 2 — Zakat administrators
        Muallafah,    // 3 — new Muslims / hearts to be reconciled
        Riqab,        // 4 — freeing captives
        Gharimeen,    // 5 — those in debt
        FiSabilillah, // 6 — in the cause of Allah
        IbnusSabil    // 7 — wayfarers / stranded travellers
    }

    struct Campaign {
        address payable creator;
        string          title;
        string          description;
        uint256         goal;                  // target in wei
        uint256         deadline;              // UNIX timestamp
        uint256         totalRaised;           // running escrow total
        CampaignStatus  status;
        bool            withdrawalApproved;    // set true by a trustee
        uint256         withdrawalRequestedAt; // 0 if none pending
        uint256         initiativeId;          // 0 = standalone; >0 = linked
    }

    struct Initiative {
        address admin;
        string  name;
        string  description;
        uint256 totalPooled; // aggregate across all linked campaigns + direct donations
        bool    active;
    }

    struct ZakatRecord {
        address    donor;       // address(0) when donor chose anonymity
        uint256    amount;
        ZakatAsnaf asnaf;
        uint256    timestamp;
        bool       distributed;
    }

    // Events
    event CampaignCreated(uint256 indexed campaignId, address indexed creator, string title, uint256 goal, uint256 deadline, uint256 indexed initiativeId);
    event DonationReceived(uint256 indexed campaignId, address indexed donor, uint256 amount, uint256 newTotal);
    event GoalReached(uint256 indexed campaignId, uint256 totalRaised);
    event WithdrawalRequested(uint256 indexed campaignId, address indexed creator);
    event WithdrawalApproved(uint256 indexed campaignId, address indexed trustee);
    event WithdrawalExecuted(uint256 indexed campaignId, address indexed creator, uint256 amount);
    event RefundClaimed(uint256 indexed campaignId, address indexed donor, uint256 amount);
    event CampaignFailed(uint256 indexed campaignId);

    event InitiativeCreated(uint256 indexed initiativeId, address indexed admin, string name);
    event InitiativeDonationReceived(uint256 indexed initiativeId, address indexed donor, uint256 amount);
    event InitiativeDeactivated(uint256 indexed initiativeId);

    event ZakatReceived(uint256 indexed recordId, uint256 amount, uint8 asnaf);
    event ZakatDistributed(uint256 indexed recordId, address indexed recipient, uint256 amount);
    event AsnafRecipientSet(uint8 indexed asnaf, address indexed recipient);
    event NisabThresholdUpdated(uint256 newThreshold);

    event MonthlyReceiverCapUpdated(uint256 newCap);
    event CreatorUniquenessToggled(bool enabled);
    event ReceiverCapExemptionSet(address indexed receiver, bool exempt);

    event TrusteeUpdated(address indexed account, bool status);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
}
