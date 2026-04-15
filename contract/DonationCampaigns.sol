// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./DonationBase.sol";

abstract contract DonationCampaigns is DonationBase {
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

        if (creatorUniquenessEnabled) {
            require(
                !hasReceivedPayout[msg.sender],
                "DonationPlatform: creator already received a payout"
            );
        }

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

        _assertNotDuplicate(campaignId, msg.sender, donations[campaignId][msg.sender]);

        c.totalRaised                     += msg.value;
        donations[campaignId][msg.sender] += msg.value;

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

    function markFailed(uint256 campaignId) external campaignExists(campaignId) {
        Campaign storage c = campaigns[campaignId];
        require(c.status == CampaignStatus.Active,  "DonationPlatform: not active");
        require(block.timestamp >= c.deadline,       "DonationPlatform: deadline not reached");
        require(c.totalRaised < c.goal,              "DonationPlatform: goal was met");
        c.status = CampaignStatus.Failed;
        emit CampaignFailed(campaignId);
    }

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

    function withdraw(uint256 campaignId) external campaignExists(campaignId) {
        Campaign storage c = campaigns[campaignId];
        require(msg.sender == c.creator,               "DonationPlatform: not creator");
        require(c.status == CampaignStatus.Successful, "DonationPlatform: goal not met");
        require(c.withdrawalApproved,                  "DonationPlatform: not approved by trustee");

        uint256 amount = c.totalRaised;
        require(amount > 0, "DonationPlatform: nothing to withdraw");

        _assertReceiverGuards(c.creator, amount, campaignId);

        c.status      = CampaignStatus.Closed;
        c.totalRaised = 0;

        emit WithdrawalExecuted(campaignId, msg.sender, amount);

        (bool ok, ) = c.creator.call{value: amount}("");
        require(ok, "DonationPlatform: transfer failed");
    }

    function claimRefund(uint256 campaignId) external campaignExists(campaignId) {
        Campaign storage c = campaigns[campaignId];

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

        donations[campaignId][msg.sender] = 0;
        c.totalRaised                    -= amount;

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

    function getCampaign(uint256 campaignId)
        external
        view
        campaignExists(campaignId)
        returns (Campaign memory)
    {
        return campaigns[campaignId];
    }

    function getDonation(uint256 campaignId, address donor)
        external
        view
        returns (uint256)
    {
        return donations[campaignId][donor];
    }

    function timeRemaining(uint256 campaignId)
        external
        view
        campaignExists(campaignId)
        returns (uint256)
    {
        uint256 dl = campaigns[campaignId].deadline;
        return block.timestamp >= dl ? 0 : dl - block.timestamp;
    }

    function amountNeeded(uint256 campaignId)
        external
        view
        campaignExists(campaignId)
        returns (uint256)
    {
        Campaign storage c = campaigns[campaignId];
        return c.totalRaised >= c.goal ? 0 : c.goal - c.totalRaised;
    }

    function isCampaignPaidOut(uint256 campaignId, address receiver)
        external
        view
        returns (bool)
    {
        return _campaignPaidOut[campaignId][receiver];
    }
}
