// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./DonationBase.sol";

abstract contract DonationZakat is DonationBase {
    function donateZakat(ZakatAsnaf asnaf, bool isAnonymous)
        external
        payable
        whenNotPaused
    {
        require(msg.value >= nisabThreshold, "DonationPlatform: below nisab threshold");

        uint256 nsKey = type(uint256).max - uint8(asnaf);
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

    function distributeZakat(uint256 recordId) external onlyOwner {
        require(recordId < zakatRecordCount, "DonationPlatform: record not found");

        ZakatRecord storage r = zakatRecords[recordId];
        require(!r.distributed, "DonationPlatform: already distributed");

        address payable recipient = zakatAsnafRecipient[uint8(r.asnaf)];
        require(recipient != address(0), "DonationPlatform: asnaf recipient not set");
        require(zakatPool >= r.amount,   "DonationPlatform: insufficient Zakat pool");

        _assertReceiverGuards(recipient, r.amount, type(uint256).max);

        r.distributed  = true;
        zakatPool     -= r.amount;

        emit ZakatDistributed(recordId, recipient, r.amount);

        (bool ok, ) = recipient.call{value: r.amount}("");
        require(ok, "DonationPlatform: Zakat transfer failed");
    }

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

            if (monthlyReceiverCap > 0 && !isCapExempt[recipient]) {
                uint256 used = _monthlyReceived[recipient][mk];
                if (used + r.amount > monthlyReceiverCap) continue;
                _monthlyReceived[recipient][mk] = used + r.amount;
            }

            r.distributed = true;
            zakatPool    -= r.amount;
            if (!hasReceivedPayout[recipient]) hasReceivedPayout[recipient] = true;

            emit ZakatDistributed(rid, recipient, r.amount);

            (bool ok, ) = recipient.call{value: r.amount}("");
            if (!ok) {
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

    function getZakatRecord(uint256 recordId)
        external
        view
        returns (ZakatRecord memory)
    {
        require(recordId < zakatRecordCount, "DonationPlatform: record not found");
        return zakatRecords[recordId];
    }
}
