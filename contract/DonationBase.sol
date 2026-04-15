// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IDonationPlatform.sol";

abstract contract DonationBase is IDonationPlatform {
    // ── Access control ──────────────────────────────────────────────────────
    address public owner;
    bool    public paused;
    mapping(address => bool) public isTrustee;

    // ── Campaigns ───────────────────────────────────────────────────────────
    uint256 public campaignCount;
    mapping(uint256 => Campaign) public campaigns;

    // ── Donation ledger ─────────────────────────────────────────────────────
    mapping(uint256 => mapping(address => uint256)) public donations;

    // ── Donor deduplication ─────────────────────────────────────────────────
    mapping(bytes32 => bool) internal _processedDonations;
    mapping(address => mapping(uint256 => uint256)) internal _lastDonationBlock;

    // ── Initiatives ─────────────────────────────────────────────────────────
    uint256 public initiativeCount;
    mapping(uint256 => Initiative)                  public initiatives;
    mapping(uint256 => uint256[])                   public initiativeCampaigns;
    mapping(uint256 => mapping(address => uint256)) public initiativeDonations;

    // ── Zakat ───────────────────────────────────────────────────────────────
    uint256 public zakatRecordCount;
    mapping(uint256 => ZakatRecord)    public zakatRecords;
    mapping(uint8 => address payable)  public zakatAsnafRecipient;
    uint256 public zakatPool;
    uint256 public nisabThreshold;

    // ── Receiver deduplication (v3) ─────────────────────────────────────────
    uint256 public monthlyReceiverCap;
    bool    public creatorUniquenessEnabled;
    mapping(address => mapping(uint256 => uint256)) internal _monthlyReceived;
    mapping(uint256 => mapping(address => bool))    internal _campaignPaidOut;
    mapping(address => bool) public hasReceivedPayout;
    mapping(address => bool) public isCapExempt;

    // =========================================================================
    // MODIFIERS
    // =========================================================================

    modifier onlyOwner() {
        require(msg.sender == owner, "DonationPlatform: not owner");
        _;
    }

    modifier onlyTrustee() {
        require(isTrustee[msg.sender], "DonationPlatform: not trustee");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "DonationPlatform: paused");
        _;
    }

    modifier campaignExists(uint256 id) {
        require(id < campaignCount, "DonationPlatform: campaign not found");
        _;
    }

    modifier initiativeExists(uint256 id) {
        require(id > 0 && id <= initiativeCount, "DonationPlatform: initiative not found");
        _;
    }

    // =========================================================================
    // INTERNAL HELPERS
    // =========================================================================

    function _monthKey(uint256 ts) internal pure returns (uint256) {
        return ts / 30 days;
    }

    function _assertNotDuplicate(
        uint256 nsKey,
        address donor,
        uint256 nonce
    ) internal {
        require(
            _lastDonationBlock[donor][nsKey] < block.number,
            "DonationPlatform: already donated this block"
        );
        bytes32 h = keccak256(
            abi.encodePacked(nsKey, donor, block.number, msg.value, nonce)
        );
        require(!_processedDonations[h], "DonationPlatform: duplicate donation");
        _processedDonations[h]          = true;
        _lastDonationBlock[donor][nsKey] = block.number;
    }

    function _assertReceiverGuards(
        address receiver,
        uint256 amount,
        uint256 campaignId
    ) internal {
        if (campaignId != type(uint256).max) {
            require(
                !_campaignPaidOut[campaignId][receiver],
                "DonationPlatform: already paid out for this campaign"
            );
            _campaignPaidOut[campaignId][receiver] = true;
        }

        if (monthlyReceiverCap > 0 && !isCapExempt[receiver]) {
            uint256 mk    = _monthKey(block.timestamp);
            uint256 soFar = _monthlyReceived[receiver][mk];
            require(
                soFar + amount <= monthlyReceiverCap,
                "DonationPlatform: monthly receiver cap exceeded"
            );
            _monthlyReceived[receiver][mk] = soFar + amount;
        }

        if (!hasReceivedPayout[receiver]) {
            hasReceivedPayout[receiver] = true;
        }
    }
}
