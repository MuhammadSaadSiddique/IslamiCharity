import { useState, useEffect } from 'react';
import { getReadOnlyContract, getSignerContract } from '../ethereum/contract';
import { ethers } from 'ethers';

const CampaignCard = ({ id, campaign, refresh, connectedAccount }) => {
  const [isDonating, setIsDonating] = useState(false);
  const [donationAmount, setDonationAmount] = useState('0.01');
  const [error, setError] = useState('');

  const handleDonate = async () => {
    try {
      setIsDonating(true);
      setError('');
      const contract = await getSignerContract();
      const tx = await contract.donate(id, { value: ethers.parseEther(donationAmount.toString()) });
      await tx.wait(); // Wait for transaction confirmation
      refresh();
    } catch (err) {
      console.error(err);
      setError(err.reason || err.message || 'Donation failed');
    } finally {
      setIsDonating(false);
    }
  };

  const handleWithdrawRequest = async () => {
    try {
      setError('');
      const contract = await getSignerContract();
      const tx = await contract.requestWithdrawal(id);
      await tx.wait();
      refresh();
    } catch (err) {
      setError(err.reason || err.message);
    }
  };

  const handleWithdraw = async () => {
    try {
      setError('');
      const contract = await getSignerContract();
      const tx = await contract.withdraw(id);
      await tx.wait();
      refresh();
    } catch (err) {
      setError(err.reason || err.message);
    }
  };

  const progress = Number(ethers.formatEther(campaign.totalRaised)) / Number(ethers.formatEther(campaign.goal)) * 100;

  return (
    <div className="glass-panel" style={{ display: 'flex', flexDirection: 'column', gap: '1rem' }}>
      <h3 style={{ fontSize: '1.25rem', marginBottom: '0.25rem' }}>{campaign.title}</h3>
      <p style={{ flexGrow: 1, fontSize: '0.875rem' }}>{campaign.description}</p>
      
      <div className="progress-container">
        <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: '0.75rem', color: 'var(--text-secondary)' }}>
          <span>{ethers.formatEther(campaign.totalRaised)} ETH raised</span>
          <span>Goal: {ethers.formatEther(campaign.goal)} ETH</span>
        </div>
        <div style={{ width: '100%', height: '6px', background: 'var(--border-color)', borderRadius: '3px', overflow: 'hidden', marginTop: '0.5rem' }}>
          <div style={{ width: `${Math.min(progress, 100)}%`, height: '100%', background: 'var(--success-color)', transition: 'width 0.5s ease-out' }} />
        </div>
      </div>

      <div style={{ display: 'flex', gap: '0.5rem', marginTop: 'auto' }}>
        <input 
          type="number" 
          step="0.01" 
          min="0"
          value={donationAmount} 
          onChange={(e) => setDonationAmount(e.target.value)}
          placeholder="ETH"
          style={{ width: '40%', padding: '0.5rem', fontSize: '0.875rem' }}
        />
        <button 
          className="btn btn-primary" 
          style={{ width: '60%', padding: '0.5rem', fontSize: '0.875rem' }}
          onClick={handleDonate}
          disabled={isDonating || Number(campaign.status) !== 0} // Status 0 is Active
        >
          {isDonating ? 'Processing...' : Number(campaign.status) !== 0 ? 'Closed' : 'Donate'}
        </button>
      </div>

      {connectedAccount && connectedAccount.toLowerCase() === campaign.creator.toLowerCase() && (
        <div style={{ marginTop: '0.5rem', padding: '0.5rem', border: '1px solid var(--secondary-color)', borderRadius: '0.5rem' }}>
          <p style={{ fontSize: '0.75rem', marginBottom: '0.5rem', color: 'var(--text-secondary)' }}>Creator Controls</p>
          {Number(campaign.status) === 1 ? (
             campaign.withdrawalApproved ? (
               <button className="btn btn-primary" onClick={handleWithdraw} style={{ width: '100%', padding: '0.5rem' }}>Execute Withdraw</button>
             ) : (
               <button className="btn btn-outline" onClick={handleWithdrawRequest} style={{ width: '100%', padding: '0.5rem' }} disabled={campaign.withdrawalRequestedAt > 0}>
                 {campaign.withdrawalRequestedAt > 0 ? 'Withdrawal Pending' : 'Request Withdrawal'}
               </button>
             )
          ) : (
            <small style={{ color: 'var(--text-secondary)' }}>Goal must be met to withdraw.</small>
          )}
        </div>
      )}
      {error && <small style={{ color: 'var(--error-color)', fontSize: '0.75rem', marginTop: '-0.5rem' }}>{error}</small>}
    </div>
  );
};

export default function CampaignList({ connectedAccount }) {
  const [campaigns, setCampaigns] = useState([]);
  const [loading, setLoading] = useState(true);

  const fetchCampaigns = async () => {
    try {
      setLoading(true);
      const contract = await getReadOnlyContract();
      const count = await contract.campaignCount();
      
      const fetchedCampaigns = [];
      // Loop backwards to show newest first
      for (let i = Number(count) - 1; i >= 0; i--) {
        const c = await contract.getCampaign(i);
        fetchedCampaigns.push({ id: i, ...c });
      }
      setCampaigns(fetchedCampaigns);
    } catch (err) {
      console.error("Failed fetching campaigns:", err);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    fetchCampaigns();
  }, []);

  if (loading) {
    return (
      <div style={{ textAlign: 'center', padding: '3rem', color: 'var(--text-secondary)' }}>
        <p>Syncing blockchain data...</p>
      </div>
    );
  }

  if (campaigns.length === 0) {
    return (
      <div className="glass-panel" style={{ textAlign: 'center' }}>
        <p>No active campaigns found on this network.</p>
        <p style={{ fontSize: '0.875rem', color: 'var(--text-secondary)', marginTop: '0.5rem' }}>Connect your wallet and create one to get started.</p>
      </div>
    );
  }

  return (
    <div className="grid grid-cols-3">
      {campaigns.map((camp) => (
        <CampaignCard key={camp.id} id={camp.id} campaign={camp} refresh={fetchCampaigns} connectedAccount={connectedAccount} />
      ))}
    </div>
  );
}
