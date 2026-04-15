// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title  DonationPlatform (Final)
 * @author Your Team
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * FEATURE SUMMARY
 * ═══════════════════════════════════════════════════════════════════════════
 *
 *  1. MULTIPLE CAMPAIGNS
 *     Anyone (subject to creator-uniqueness policy) can open a campaign with
 *     a fundraising goal and a deadline.  All ETH is held in escrow inside
 *     this contract until explicitly withdrawn or refunded.
 *
 *  2. GOAL-BASED ESCROW
 *     Donations accumulate on-chain.  Funds are only releasable to the creator
 *     when the campaign reaches its goal.  If the deadline passes without the
 *     goal being met, donors may claim full refunds.
 *
 *  3. TRUSTEE ROLE
 *     Before a creator can withdraw, a designated trustee must explicitly
 *     approve the request.  This two-step flow prevents unilateral fund
 *     extraction and gives the platform an oversight layer.
 *
 *  4. DONOR DEDUPLICATION (v2)
 *     Every donate() call is fingerprinted with a keccak256 hash of
 *     (campaignId, donor, block.number, msg.value, cumulativeTotal).
 *     A per-block guard (one donation per donor per campaign per block)
 *     provides a cheap first line of defence; the hash check is the
 *     definitive replay barrier.
 *
 *  5. ZAKAT DONATIONS (v2)
 *     Islamic-finance-compliant donation path:
 *     • Minimum nisab threshold enforced.
 *     • Donor may choose anonymity (stored as address(0)).
 *     • Funds held in a dedicated zakatPool until the owner distributes
 *       them to pre-registered asnaf recipient wallets.
 *     • Covers all 8 Quranic categories (asnaf).
 *     • Batch distribution supported with per-record rollback on failure.
 *
 *  6. INITIATIVE-BASED CAMPAIGNS (v2)
 *     Campaigns can be grouped under a named Initiative.  Donors may give
 *     directly to the initiative pool (not tied to any single campaign), or
 *     donate to a specific linked campaign — both paths update the initiative's
 *     totalPooled counter atomically.  Refunds correctly decrement the pool.
 *
 *  7. RECEIVER DEDUPLICATION — PER CAMPAIGN (v3)
 *     A wallet address can only ever receive a withdrawal payout from a given
 *     campaign once.  _campaignPaidOut[campaignId][receiver] is set to true
 *     before the ETH transfer and checked on every subsequent attempt.
 *
 *  8. RECEIVER DEDUPLICATION — MONTHLY ETH CAP (v3)
 *     Every receiver (campaign creator OR Zakat asnaf wallet) has a global
 *     cap on total ETH received across all sources within a 30-day rolling
 *     window.  The month bucket key is block.timestamp / 30 days.
 *     Cap exemptions can be granted per-wallet by the owner.
 *
 *  9. CREATOR UNIQUENESS POLICY (v3)
 *     Optional policy (off by default, toggled by owner): once a wallet has
 *     received a campaign payout, it cannot register as creator of a new
 *     campaign.  Prevents one operator from draining the platform across
 *     multiple campaigns.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * ROLES
 * ═══════════════════════════════════════════════════════════════════════════
 *  owner    — deploys; manages trustees, asnaf recipients, caps, policies
 *  trustee  — approves withdrawal requests before creators can execute them
 *  creator  — opens campaigns and withdraws approved funds
 *  donor    — donates ETH; claims refunds if campaign fails
 */
contract DonationPlatform {

    // =========================================================================
    // TYPES
    // =========================================================================

    enum CampaignStatus {
        Active,      // accepting donations
        Successful,  // goal reached; awaiting or approved for withdrawal
        Failed,      // deadline passed without meeting goal; refunds open
        Closed       // funds fully withdrawn
    }

    /**
     * @notice The 8 Quranic categories (asnaf) eligible to receive Zakat.
     */
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

    // =========================================================================
    // STATE
    // =========================================================================

    // ── Access control ──────────────────────────────────────────────────────
    address public owner;
    bool    public paused;
    mapping(address => bool) public isTrustee;

    // ── Campaigns ───────────────────────────────────────────────────────────
    uint256 public campaignCount;
    mapping(uint256 => Campaign) public campaigns;

    // ── Donation ledger ─────────────────────────────────────────────────────
    /// campaignId => donor => total ETH donated (cumulative, post-dedup)
    mapping(uint256 => mapping(address => uint256)) public donations;

    // ── Donor deduplication ─────────────────────────────────────────────────
    /// Fingerprints of processed donation calls — prevents replays
    mapping(bytes32 => bool) private _processedDonations;
    /// donor => namespace key => last block number donated in (per-block guard)
    mapping(address => mapping(uint256 => uint256)) private _lastDonationBlock;

    // ── Initiatives ─────────────────────────────────────────────────────────
    uint256 public initiativeCount;
    mapping(uint256 => Initiative)                  public initiatives;
    /// initiativeId => ordered list of linked campaign IDs
    mapping(uint256 => uint256[])                   public initiativeCampaigns;
    /// initiativeId => donor => total ETH given to this initiative
    mapping(uint256 => mapping(address => uint256)) public initiativeDonations;

    // ── Zakat ───────────────────────────────────────────────────────────────
    uint256 public zakatRecordCount;
    mapping(uint256 => ZakatRecord)    public zakatRecords;
    /// asnaf index => designated recipient wallet
    mapping(uint8 => address payable)  public zakatAsnafRecipient;
    /// Undistributed ETH held for Zakat
    uint256 public zakatPool;
    /// Minimum donation accepted as Zakat (wei-equivalent of nisab)
    uint256 public nisabThreshold;

    // ── Receiver deduplication (v3) ─────────────────────────────────────────
    /// Maximum ETH a receiver may collect in one 30-day window (0 = disabled)
    uint256 public monthlyReceiverCap;
    /// When true, a wallet that has already received a payout cannot create new campaigns
    bool    public creatorUniquenessEnabled;
    /// receiver => month bucket key => ETH received in that window
    mapping(address => mapping(uint256 => uint256)) private _monthlyReceived;
    /// campaignId => receiver => already paid out for this campaign?
    mapping(uint256 => mapping(address => bool))    private _campaignPaidOut;
    /// receiver => has ever received any payout from this platform?
    mapping(address => bool) public hasReceivedPayout;
    /// Wallets exempt from the monthly cap (e.g. platform treasury, verified charities)
    mapping(address => bool) public isCapExempt;

    // =========================================================================
    // EVENTS
    // =========================================================================

    // Campaigns
    event CampaignCreated(
        uint256 indexed campaignId,
        address indexed creator,
        string          title,
        uint256         goal,
        uint256         deadline,
        uint256 indexed initiativeId
    );
    event DonationReceived(
        uint256 indexed campaignId,
        address indexed donor,
        uint256         amount,
        uint256         newTotal
    );
    event GoalReached(uint256 indexed campaignId, uint256 totalRaised);
    event WithdrawalRequested(uint256 indexed campaignId, address indexed creator);
    event WithdrawalApproved(uint256 indexed campaignId, address indexed trustee);
    event WithdrawalExecuted(
        uint256 indexed campaignId,
        address indexed creator,
        uint256         amount
    );
    event RefundClaimed(
        uint256 indexed campaignId,
        address indexed donor,
        uint256         amount
    );
    event CampaignFailed(uint256 indexed campaignId);

    // Initiatives
    event InitiativeCreated(
        uint256 indexed initiativeId,
        address indexed admin,
        string          name
    );
    event InitiativeDonationReceived(
        uint256 indexed initiativeId,
        address indexed donor,
        uint256         amount
    );
    event InitiativeDeactivated(uint256 indexed initiativeId);

    // Zakat
    event ZakatReceived(uint256 indexed recordId, uint256 amount, uint8 asnaf);
    event ZakatDistributed(
        uint256 indexed recordId,
        address indexed recipient,
        uint256         amount
    );
    event AsnafRecipientSet(uint8 indexed asnaf, address indexed recipient);
    event NisabThresholdUpdated(uint256 newThreshold);

    // Receiver guards
    event MonthlyReceiverCapUpdated(uint256 newCap);
    event CreatorUniquenessToggled(bool enabled);
    event ReceiverCapExemptionSet(address indexed receiver, bool exempt);

    // Admin
    event TrusteeUpdated(address indexed account, bool status);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Paused(address indexed by);
    event Unpaused(address indexed by);

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
    // CONSTRUCTOR
    // =========================================================================

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
        // monthlyReceiverCap  = 0  (cap disabled; owner enables via setMonthlyReceiverCap)
        // creatorUniquenessEnabled = false  (owner enables via setCreatorUniqueness)
        emit TrusteeUpdated(msg.sender, true);
    }

    // =========================================================================
    // INTERNAL HELPERS
    // =========================================================================

    /**
     * @dev Returns the 30-day bucket index for a given timestamp.
     *      Rolls over automatically every 30 days with no admin intervention.
     */
    function _monthKey(uint256 ts) internal pure returns (uint256) {
        return ts / 30 days;
    }

    /**
     * @dev Donor deduplication guard.
     *      Two layers:
     *        Layer 1 — per-block: one tx per donor per namespace key per block.
     *        Layer 2 — hash: keccak256(id, donor, block, value, cumulativeTotal).
     *                  The cumulative total acts as a monotonic nonce so each
     *                  new donation produces a unique hash even if all other
     *                  parameters repeat in a later block.
     *
     * @param nsKey   Namespace key (campaignId for campaigns, virtual id for
     *                initiatives/Zakat).
     * @param donor   msg.sender at call site.
     * @param nonce   Per-donor nonce (cumulative donation total before this tx).
     */
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

    /**
     * @dev Receiver duplication guard — called before EVERY outbound ETH transfer.
     *
     *      Check 1 — Per-campaign uniqueness:
     *        A wallet address can only be paid from a specific campaign once.
     *        Pass type(uint256).max as campaignId to skip this check (Zakat path).
     *
     *      Check 2 — Monthly ETH cap:
     *        Cumulative ETH received by this wallet in the current 30-day window
     *        must not exceed monthlyReceiverCap.  Disabled when cap == 0 or wallet
     *        is cap-exempt.
     *
     *      After both checks pass, marks the receiver as "has received payout"
     *      for the creator-uniqueness policy.
     *
     * @param receiver   Destination wallet.
     * @param amount     ETH being sent (wei).
     * @param campaignId Real campaign id, or type(uint256).max to skip check 1.
     */
    function _assertReceiverGuards(
        address receiver,
        uint256 amount,
        uint256 campaignId
    ) internal {
        // ── Check 1: per-campaign payout uniqueness ──
        if (campaignId != type(uint256).max) {
            require(
                !_campaignPaidOut[campaignId][receiver],
                "DonationPlatform: already paid out for this campaign"
            );
            _campaignPaidOut[campaignId][receiver] = true;
        }

        // ── Check 2: monthly ETH cap ──
        if (monthlyReceiverCap > 0 && !isCapExempt[receiver]) {
            uint256 mk    = _monthKey(block.timestamp);
            uint256 soFar = _monthlyReceived[receiver][mk];
            require(
                soFar + amount <= monthlyReceiverCap,
                "DonationPlatform: monthly receiver cap exceeded"
            );
            _monthlyReceived[receiver][mk] = soFar + amount;
        }

        // ── Mark receiver as having received a payout ──
        if (!hasReceivedPayout[receiver]) {
            hasReceivedPayout[receiver] = true;
        }
    }

    // =========================================================================
    // OWNER ADMINISTRATION
    // =========================================================================

    /**
     * @notice Grant or revoke trustee status.
     */
    function setTrustee(address account, bool status) external onlyOwner {
        require(account != address(0), "DonationPlatform: zero address");
        isTrustee[account] = status;
        emit TrusteeUpdated(account, status);
    }

    /**
     * @notice Transfer contract ownership to a new address.
     */
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "DonationPlatform: zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /**
     * @notice Pause the contract — disables campaign creation and all donations.
     */
    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    /**
     * @notice Unpause the contract.
     */
    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /**
     * @notice Update the Zakat nisab threshold.  Set to 0 to accept any amount.
     */
    function setNisabThreshold(uint256 threshold) external onlyOwner {
        nisabThreshold = threshold;
        emit NisabThresholdUpdated(threshold);
    }

    /**
     * @notice Assign a recipient wallet to a Zakat asnaf category.
     */
    function setAsnafRecipient(ZakatAsnaf asnaf, address payable recipient)
        external
        onlyOwner
    {
        require(recipient != address(0), "DonationPlatform: zero address");
        zakatAsnafRecipient[uint8(asnaf)] = recipient;
        emit AsnafRecipientSet(uint8(asnaf), recipient);
    }

    /**
     * @notice Set the maximum ETH any receiver may collect in a 30-day window.
     *         Pass 0 to disable the cap.
     * @param  cap  Amount in wei (e.g. 10 ether).
     */
    function setMonthlyReceiverCap(uint256 cap) external onlyOwner {
        monthlyReceiverCap = cap;
        emit MonthlyReceiverCapUpdated(cap);
    }

    /**
     * @notice Enable or disable the creator-uniqueness policy.
     *         When enabled, wallets that have received any payout cannot
     *         create new campaigns.
     */
    function setCreatorUniqueness(bool enabled) external onlyOwner {
        creatorUniquenessEnabled = enabled;
        emit CreatorUniquenessToggled(enabled);
    }

    /**
     * @notice Grant or revoke monthly-cap exemption for a wallet.
     *         Useful for the platform treasury or verified charity wallets.
     */
    function setCapExemption(address receiver, bool exempt) external onlyOwner {
        require(receiver != address(0), "DonationPlatform: zero address");
        isCapExempt[receiver] = exempt;
        emit ReceiverCapExemptionSet(receiver, exempt);
    }

    // =========================================================================
    // INITIATIVES
    // =========================================================================

    /**
     * @notice Create a named funding initiative that can group multiple campaigns.
     * @param  name        Short display name (e.g. "Ramadan Relief 2025").
     * @param  description Purpose of the initiative.
     * @return initiativeId  Assigned index (starts at 1).
     */
    function createInitiative(
        string calldata name,
        string calldata description
    ) external whenNotPaused returns (uint256 initiativeId) {
        require(bytes(name).length > 0, "DonationPlatform: empty name");

        initiativeId = ++initiativeCount;
        initiatives[initiativeId] = Initiative({
            admin:       msg.sender,
            name:        name,
            description: description,
            totalPooled: 0,
            active:      true
        });

        emit InitiativeCreated(initiativeId, msg.sender, name);
    }

    /**
     * @notice Deactivate an initiative.  Linked campaigns continue independently.
     *         Only the initiative admin or the contract owner may call this.
     */
    function deactivateInitiative(uint256 initiativeId)
        external
        initiativeExists(initiativeId)
    {
        Initiative storage ini = initiatives[initiativeId];
        require(
            msg.sender == ini.admin || msg.sender == owner,
            "DonationPlatform: not initiative admin"
        );
        ini.active = false;
        emit InitiativeDeactivated(initiativeId);
    }

    /**
     * @notice Donate ETH directly to an initiative pool without targeting a
     *         specific campaign.  Subject to donor deduplication guard.
     */
    function donateToInitiative(uint256 initiativeId)
        external
        payable
        whenNotPaused
        initiativeExists(initiativeId)
    {
        require(msg.value > 0, "DonationPlatform: donation must be > 0");

        Initiative storage ini = initiatives[initiativeId];
        require(ini.active, "DonationPlatform: initiative inactive");

        // Use a virtual namespace key above the uint128 campaign range
        uint256 nsKey = type(uint128).max + initiativeId;
        _assertNotDuplicate(
            nsKey,
            msg.sender,
            initiativeDonations[initiativeId][msg.sender]
        );

        ini.totalPooled                               += msg.value;
        initiativeDonations[initiativeId][msg.sender] += msg.value;

        emit InitiativeDonationReceived(initiativeId, msg.sender, msg.value);
    }

    // =========================================================================
    // CAMPAIGNS
    // =========================================================================

    /**
     * @notice Create a fundraising campaign.
     *
     * @param title        Human-readable campaign title (non-empty).
     * @param description  Campaign description.
     * @param goal         Target amount in wei (must be > 0).
     * @param duration     Seconds until the deadline (1 hour – 365 days).
     * @param initiativeId Pass 0 for a standalone campaign, or a valid
     *                     initiative id to link this campaign to that umbrella.
     * @return campaignId  Index assigned to the new campaign.
     */
    function createCampaign(
        string calldata title,
        string calldata description,
        uint256         goal,
        uint256         duration,
        uint256         initiativeId
    ) external whenNotPaused returns (uint256 campaignId) {
        require(bytes(title).length > 0, "DonationPlatform: empty title");
        require(goal > 0,                "DonationPlatform: goal must be > 0");
        require(duration >= 1 hours,     "DonationPlatform: duration too short");
        require(duration <= 365 days,    "DonationPlatform: duration too long");

        // Creator-uniqueness guard (optional policy)
        if (creatorUniquenessEnabled) {
            require(
                !hasReceivedPayout[msg.sender],
                "DonationPlatform: creator already received a payout"
            );
        }

        // Validate initiative link
        if (initiativeId > 0) {
            require(
                initiativeId <= initiativeCount,
                "DonationPlatform: initiative not found"
            );
            require(
                initiatives[initiativeId].active,
                "DonationPlatform: initiative inactive"
            );
        }

        campaignId = campaignCount++;
        campaigns[campaignId] = Campaign({
            creator:               payable(msg.sender),
            title:                 title,
            description:           description,
            goal:                  goal,
            deadline:              block.timestamp + duration,
            totalRaised:           0,
            status:                CampaignStatus.Active,
            withdrawalApproved:    false,
            withdrawalRequestedAt: 0,
            initiativeId:          initiativeId
        });

        if (initiativeId > 0) {
            initiativeCampaigns[initiativeId].push(campaignId);
        }

        emit CampaignCreated(
            campaignId,
            msg.sender,
            title,
            goal,
            block.timestamp + duration,
            initiativeId
        );
    }

    /**
     * @notice Donate ETH to a specific campaign.
     *
     *         • Donation is fingerprinted and blocked if it looks like a replay.
     *         • If the campaign is linked to an initiative, the initiative pool
     *           is updated atomically.
     *         • If the donation pushes totalRaised to or past goal, the campaign
     *           automatically transitions to Successful.
     */
    function donate(uint256 campaignId)
        external
        payable
        whenNotPaused
        campaignExists(campaignId)
    {
        require(msg.value > 0, "DonationPlatform: donation must be > 0");

        Campaign storage c = campaigns[campaignId];
        require(c.status == CampaignStatus.Active, "DonationPlatform: campaign not active");
        require(block.timestamp < c.deadline,       "DonationPlatform: campaign ended");

        // Donor deduplication — nonce is the donor's cumulative total before this tx
        _assertNotDuplicate(campaignId, msg.sender, donations[campaignId][msg.sender]);

        c.totalRaised                     += msg.value;
        donations[campaignId][msg.sender] += msg.value;

        // Propagate to linked initiative pool
        if (c.initiativeId > 0) {
            initiatives[c.initiativeId].totalPooled         += msg.value;
            initiativeDonations[c.initiativeId][msg.sender] += msg.value;
        }

        emit DonationReceived(campaignId, msg.sender, msg.value, c.totalRaised);

        if (c.totalRaised >= c.goal) {
            c.status = CampaignStatus.Successful;
            emit GoalReached(campaignId, c.totalRaised);
        }
    }

    /**
     * @notice Publicly callable function to mark an Active campaign as Failed
     *         once its deadline has passed without meeting the goal.
     *         Opens refund claims for all donors of that campaign.
     */
    function markFailed(uint256 campaignId) external campaignExists(campaignId) {
        Campaign storage c = campaigns[campaignId];
        require(c.status == CampaignStatus.Active,  "DonationPlatform: not active");
        require(block.timestamp >= c.deadline,       "DonationPlatform: deadline not reached");
        require(c.totalRaised < c.goal,              "DonationPlatform: goal was met");
        c.status = CampaignStatus.Failed;
        emit CampaignFailed(campaignId);
    }

    // =========================================================================
    // TRUSTEE-GATED WITHDRAWAL (3-step flow)
    // =========================================================================

    /**
     * @notice Step 1 — Creator signals intent to withdraw.
     *         Campaign must be in Successful status.
     */
    function requestWithdrawal(uint256 campaignId)
        external
        campaignExists(campaignId)
    {
        Campaign storage c = campaigns[campaignId];
        require(msg.sender == c.creator,               "DonationPlatform: not creator");
        require(c.status == CampaignStatus.Successful, "DonationPlatform: goal not met");
        require(!c.withdrawalApproved,                 "DonationPlatform: already approved");
        require(c.withdrawalRequestedAt == 0,          "DonationPlatform: request already pending");

        c.withdrawalRequestedAt = block.timestamp;
        emit WithdrawalRequested(campaignId, msg.sender);
    }

    /**
     * @notice Step 2 — Trustee approves the pending withdrawal request.
     */
    function approveWithdrawal(uint256 campaignId)
        external
        onlyTrustee
        campaignExists(campaignId)
    {
        Campaign storage c = campaigns[campaignId];
        require(c.status == CampaignStatus.Successful, "DonationPlatform: goal not met");
        require(c.withdrawalRequestedAt > 0,            "DonationPlatform: no pending request");
        require(!c.withdrawalApproved,                  "DonationPlatform: already approved");

        c.withdrawalApproved = true;
        emit WithdrawalApproved(campaignId, msg.sender);
    }

    /**
     * @notice Step 3 — Creator executes the approved withdrawal.
     *
     *         Receiver guards enforced before transfer:
     *           • _campaignPaidOut: blocks second payout for same campaign.
     *           • monthly cap: blocks payout if receiver has hit their 30-day limit.
     *
     *         Follows Checks-Effects-Interactions:
     *           status and totalRaised are zeroed BEFORE the ETH call.
     */
    function withdraw(uint256 campaignId) external campaignExists(campaignId) {
        Campaign storage c = campaigns[campaignId];
        require(msg.sender == c.creator,               "DonationPlatform: not creator");
        require(c.status == CampaignStatus.Successful, "DonationPlatform: goal not met");
        require(c.withdrawalApproved,                  "DonationPlatform: not approved by trustee");

        uint256 amount = c.totalRaised;
        require(amount > 0, "DonationPlatform: nothing to withdraw");

        // Receiver guards (per-campaign uniqueness + monthly cap)
        _assertReceiverGuards(c.creator, amount, campaignId);

        // Effects before interaction
        c.status      = CampaignStatus.Closed;
        c.totalRaised = 0;

        emit WithdrawalExecuted(campaignId, msg.sender, amount);

        (bool ok, ) = c.creator.call{value: amount}("");
        require(ok, "DonationPlatform: transfer failed");
    }

    // =========================================================================
    // DONOR REFUND
    // =========================================================================

    /**
     * @notice Claim a refund for a failed campaign.
     *
     *         If the campaign is still Active but the deadline has passed and
     *         the goal was not met, this function auto-marks it Failed before
     *         processing the refund — donors do not need to wait for anyone
     *         else to call markFailed() first.
     *
     *         If the campaign was linked to an initiative, the initiative pool
     *         is decremented by the refund amount.
     *
     *         Re-entrancy safe: donation balance is zeroed before the ETH call.
     */
    function claimRefund(uint256 campaignId) external campaignExists(campaignId) {
        Campaign storage c = campaigns[campaignId];

        // Auto-mark Failed if conditions are met
        if (
            c.status == CampaignStatus.Active  &&
            block.timestamp >= c.deadline      &&
            c.totalRaised < c.goal
        ) {
            c.status = CampaignStatus.Failed;
            emit CampaignFailed(campaignId);
        }

        require(c.status == CampaignStatus.Failed, "DonationPlatform: campaign not failed");

        uint256 amount = donations[campaignId][msg.sender];
        require(amount > 0, "DonationPlatform: no donation to refund");

        // Effects before interaction
        donations[campaignId][msg.sender] = 0;
        c.totalRaised                    -= amount;

        // Decrement initiative pool if linked
        if (c.initiativeId > 0) {
            Initiative storage ini = initiatives[c.initiativeId];
            if (ini.totalPooled >= amount) {
                ini.totalPooled -= amount;
            }
            if (initiativeDonations[c.initiativeId][msg.sender] >= amount) {
                initiativeDonations[c.initiativeId][msg.sender] -= amount;
            }
        }

        emit RefundClaimed(campaignId, msg.sender, amount);

        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "DonationPlatform: refund transfer failed");
    }

    // =========================================================================
    // ZAKAT
    // =========================================================================

    /**
     * @notice Submit a Zakat donation to a specific asnaf category.
     *
     *         Islamic finance rules enforced:
     *           • Amount must meet or exceed nisabThreshold.
     *           • Donor may choose full on-chain anonymity.
     *           • Funds sit in zakatPool escrow until owner distributes them.
     *           • One Zakat tx per donor per asnaf per block (dedup guard).
     *
     * @param asnaf     One of the 8 ZakatAsnaf categories.
     * @param isAnonymous Pass true to record donor as address(0).
     */
    function donateZakat(ZakatAsnaf asnaf, bool isAnonymous)
        external
        payable
        whenNotPaused
    {
        require(msg.value >= nisabThreshold, "DonationPlatform: below nisab threshold");

        // Deduplicate: virtual namespace key below uint256 max, one per asnaf
        uint256 nsKey = type(uint256).max - uint8(asnaf);
        // Nonce = zakatPool before this donation (global monotonic counter)
        _assertNotDuplicate(nsKey, msg.sender, zakatPool);

        uint256 recordId = zakatRecordCount++;
        zakatRecords[recordId] = ZakatRecord({
            donor:       isAnonymous ? address(0) : msg.sender,
            amount:      msg.value,
            asnaf:       asnaf,
            timestamp:   block.timestamp,
            distributed: false
        });

        zakatPool += msg.value;
        emit ZakatReceived(recordId, msg.value, uint8(asnaf));
    }

    /**
     * @notice Distribute a single Zakat record to its designated asnaf recipient.
     *
     *         Monthly cap guard is applied to the asnaf wallet.
     *         Per-campaign uniqueness check is skipped (Zakat sentinel id).
     *         Only the owner may call this.
     *
     * @param recordId  Index of the ZakatRecord to distribute.
     */
    function distributeZakat(uint256 recordId) external onlyOwner {
        require(recordId < zakatRecordCount, "DonationPlatform: record not found");

        ZakatRecord storage r = zakatRecords[recordId];
        require(!r.distributed, "DonationPlatform: already distributed");

        address payable recipient = zakatAsnafRecipient[uint8(r.asnaf)];
        require(recipient != address(0), "DonationPlatform: asnaf recipient not set");
        require(zakatPool >= r.amount,   "DonationPlatform: insufficient Zakat pool");

        // Monthly cap guard — pass sentinel to skip per-campaign uniqueness
        _assertReceiverGuards(recipient, r.amount, type(uint256).max);

        // Effects before interaction
        r.distributed  = true;
        zakatPool     -= r.amount;

        emit ZakatDistributed(recordId, recipient, r.amount);

        (bool ok, ) = recipient.call{value: r.amount}("");
        require(ok, "DonationPlatform: Zakat transfer failed");
    }

    /**
     * @notice Batch-distribute multiple Zakat records in one transaction.
     *
     *         Records that fail the monthly cap check are skipped (not reverted)
     *         so one over-cap asnaf wallet does not block the rest of the batch.
     *         Records whose ETH transfer fails are fully rolled back and skipped.
     *
     * @param recordIds  Array of ZakatRecord indices to distribute.
     */
    function distributeZakatBatch(uint256[] calldata recordIds) external onlyOwner {
        uint256 mk = _monthKey(block.timestamp);

        for (uint256 i = 0; i < recordIds.length; i++) {
            uint256 rid = recordIds[i];
            if (rid >= zakatRecordCount) continue;

            ZakatRecord storage r = zakatRecords[rid];
            if (r.distributed)  continue;

            address payable recipient = zakatAsnafRecipient[uint8(r.asnaf)];
            if (recipient == address(0)) continue;
            if (zakatPool < r.amount)    continue;

            // Monthly cap inline check — skip rather than revert
            if (monthlyReceiverCap > 0 && !isCapExempt[recipient]) {
                uint256 used = _monthlyReceived[recipient][mk];
                if (used + r.amount > monthlyReceiverCap) continue;
                _monthlyReceived[recipient][mk] = used + r.amount;
            }

            // Effects
            r.distributed = true;
            zakatPool    -= r.amount;
            if (!hasReceivedPayout[recipient]) hasReceivedPayout[recipient] = true;

            emit ZakatDistributed(rid, recipient, r.amount);

            (bool ok, ) = recipient.call{value: r.amount}("");
            if (!ok) {
                // Roll back all state changes for this record on failure
                r.distributed = false;
                zakatPool    += r.amount;
                if (monthlyReceiverCap > 0 && !isCapExempt[recipient]) {
                    uint256 used = _monthlyReceived[recipient][mk];
                    if (used >= r.amount) {
                        _monthlyReceived[recipient][mk] = used - r.amount;
                    }
                }
            }
        }
    }

    // =========================================================================
    // VIEW / QUERY HELPERS
    // =========================================================================

    /**
     * @notice Full Campaign struct for a given id.
     */
    function getCampaign(uint256 campaignId)
        external
        view
        campaignExists(campaignId)
        returns (Campaign memory)
    {
        return campaigns[campaignId];
    }

    /**
     * @notice Full Initiative struct for a given id.
     */
    function getInitiative(uint256 initiativeId)
        external
        view
        initiativeExists(initiativeId)
        returns (Initiative memory)
    {
        return initiatives[initiativeId];
    }

    /**
     * @notice Array of campaign ids linked to an initiative.
     */
    function getInitiativeCampaigns(uint256 initiativeId)
        external
        view
        initiativeExists(initiativeId)
        returns (uint256[] memory)
    {
        return initiativeCampaigns[initiativeId];
    }

    /**
     * @notice Total ETH donated by a specific address to a specific campaign.
     */
    function getDonation(uint256 campaignId, address donor)
        external
        view
        returns (uint256)
    {
        return donations[campaignId][donor];
    }

    /**
     * @notice Total ETH donated by a specific address to an initiative
     *         (across direct donations + all linked campaigns).
     */
    function getInitiativeDonation(uint256 initiativeId, address donor)
        external
        view
        returns (uint256)
    {
        return initiativeDonations[initiativeId][donor];
    }

    /**
     * @notice Full ZakatRecord for a given record id.
     */
    function getZakatRecord(uint256 recordId)
        external
        view
        returns (ZakatRecord memory)
    {
        require(recordId < zakatRecordCount, "DonationPlatform: record not found");
        return zakatRecords[recordId];
    }

    /**
     * @notice Seconds remaining until a campaign's deadline (0 if passed).
     */
    function timeRemaining(uint256 campaignId)
        external
        view
        campaignExists(campaignId)
        returns (uint256)
    {
        uint256 dl = campaigns[campaignId].deadline;
        return block.timestamp >= dl ? 0 : dl - block.timestamp;
    }

    /**
     * @notice ETH still needed for a campaign to reach its goal (0 if met).
     */
    function amountNeeded(uint256 campaignId)
        external
        view
        campaignExists(campaignId)
        returns (uint256)
    {
        Campaign storage c = campaigns[campaignId];
        return c.totalRaised >= c.goal ? 0 : c.goal - c.totalRaised;
    }

    /**
     * @notice ETH already received by a wallet in the current 30-day window.
     */
    function monthlyReceivedSoFar(address receiver)
        external
        view
        returns (uint256)
    {
        return _monthlyReceived[receiver][_monthKey(block.timestamp)];
    }

    /**
     * @notice Remaining ETH headroom for a receiver within the current month.
     *         Returns type(uint256).max when the cap is disabled or the wallet
     *         is cap-exempt.
     */
    function monthlyHeadroom(address receiver)
        external
        view
        returns (uint256)
    {
        if (monthlyReceiverCap == 0 || isCapExempt[receiver]) {
            return type(uint256).max;
        }
        uint256 used = _monthlyReceived[receiver][_monthKey(block.timestamp)];
        return used >= monthlyReceiverCap ? 0 : monthlyReceiverCap - used;
    }

    /**
     * @notice Whether a receiver wallet has already been paid out for a campaign.
     */
    function isCampaignPaidOut(uint256 campaignId, address receiver)
        external
        view
        returns (bool)
    {
        return _campaignPaidOut[campaignId][receiver];
    }

    // =========================================================================
    // FALLBACK — reject accidental ETH transfers
    // =========================================================================

    receive()  external payable { revert("DonationPlatform: use donate(), donateZakat(), or donateToInitiative()"); }
    fallback() external payable { revert("DonationPlatform: use donate(), donateZakat(), or donateToInitiative()"); }
}
