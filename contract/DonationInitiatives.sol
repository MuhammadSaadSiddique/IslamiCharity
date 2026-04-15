// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./DonationBase.sol";

abstract contract DonationInitiatives is DonationBase {
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

    function donateToInitiative(uint256 initiativeId)
        external
        payable
        whenNotPaused
        initiativeExists(initiativeId)
    {
        require(msg.value > 0, "DonationPlatform: donation must be > 0");

        Initiative storage ini = initiatives[initiativeId];
        require(ini.active, "DonationPlatform: initiative inactive");

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

    function getInitiative(uint256 initiativeId)
        external
        view
        initiativeExists(initiativeId)
        returns (Initiative memory)
    {
        return initiatives[initiativeId];
    }

    function getInitiativeCampaigns(uint256 initiativeId)
        external
        view
        initiativeExists(initiativeId)
        returns (uint256[] memory)
    {
        return initiativeCampaigns[initiativeId];
    }

    function getInitiativeDonation(uint256 initiativeId, address donor)
        external
        view
        returns (uint256)
    {
        return initiativeDonations[initiativeId][donor];
    }
}
