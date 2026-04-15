// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./DonationBase.sol";

abstract contract DonationAdmin is DonationBase {
    function setTrustee(address account, bool status) external onlyOwner {
        require(account != address(0), "DonationPlatform: zero address");
        isTrustee[account] = status;
        emit TrusteeUpdated(account, status);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "DonationPlatform: zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    function setNisabThreshold(uint256 threshold) external onlyOwner {
        nisabThreshold = threshold;
        emit NisabThresholdUpdated(threshold);
    }

    function setAsnafRecipient(ZakatAsnaf asnaf, address payable recipient) external onlyOwner {
        require(recipient != address(0), "DonationPlatform: zero address");
        zakatAsnafRecipient[uint8(asnaf)] = recipient;
        emit AsnafRecipientSet(uint8(asnaf), recipient);
    }

    function setMonthlyReceiverCap(uint256 cap) external onlyOwner {
        monthlyReceiverCap = cap;
        emit MonthlyReceiverCapUpdated(cap);
    }

    function setCreatorUniqueness(bool enabled) external onlyOwner {
        creatorUniquenessEnabled = enabled;
        emit CreatorUniquenessToggled(enabled);
    }

    function setCapExemption(address receiver, bool exempt) external onlyOwner {
        require(receiver != address(0), "DonationPlatform: zero address");
        isCapExempt[receiver] = exempt;
        emit ReceiverCapExemptionSet(receiver, exempt);
    }

    function monthlyReceivedSoFar(address receiver) external view returns (uint256) {
        return _monthlyReceived[receiver][_monthKey(block.timestamp)];
    }

    function monthlyHeadroom(address receiver) external view returns (uint256) {
        if (monthlyReceiverCap == 0 || isCapExempt[receiver]) {
            return type(uint256).max;
        }
        uint256 used = _monthlyReceived[receiver][_monthKey(block.timestamp)];
        return used >= monthlyReceiverCap ? 0 : monthlyReceiverCap - used;
    }
}
