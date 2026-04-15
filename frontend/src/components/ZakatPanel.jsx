import { useState, useEffect } from 'react';
import { getReadOnlyContract, getSignerContract } from '../ethereum/contract';
import { ethers } from 'ethers';

export default function ZakatPanel() {
  const [formData, setFormData] = useState({ amount: '0.05', asnaf: '0', anonymous: false });
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [error, setError] = useState('');
  const [zakatPool, setZakatPool] = useState('0');

  useEffect(() => {
    const fetchPool = async () => {
      try {
        const contract = await getReadOnlyContract();
        const pool = await contract.zakatPool();
        setZakatPool(ethers.formatEther(pool));
      } catch (err) {
        console.error("Error fetching zakat pool:", err);
      }
    };
    fetchPool();
  }, []);

  const handleSubmit = async (e) => {
    e.preventDefault();
    try {
      setIsSubmitting(true);
      setError('');
      
      const contract = await getSignerContract();
      
      const tx = await contract.donateZakat(
        Number(formData.asnaf),
        formData.anonymous,
        { value: ethers.parseEther(formData.amount.toString()) }
      );
      
      await tx.wait();
      
      // update pool
      const pool = await contract.zakatPool();
      setZakatPool(ethers.formatEther(pool));

    } catch (err) {
      console.error(err);
      setError(err.reason || err.message || 'Error donating Zakat');
    } finally {
      setIsSubmitting(false);
    }
  };

  return (
    <div className="glass-panel" style={{ marginBottom: '2rem', borderTop: '4px solid var(--primary-color)' }}>
      <h2>Zakat Fund</h2>
      <p style={{ marginBottom: '1rem' }}>Current Global Zakat Pool: <strong>{zakatPool} ETH</strong></p>
      
      <form onSubmit={handleSubmit} style={{ display: 'flex', gap: '1rem', flexWrap: 'wrap', alignItems: 'center' }}>
        <input 
          type="number" 
          name="amount" 
          placeholder="ETH Amount" 
          step="0.001"
          min="0"
          value={formData.amount} 
          onChange={(e) => setFormData({...formData, amount: e.target.value})} 
          required 
          style={{ width: '150px' }}
        />
        
        <select 
          value={formData.asnaf} 
          onChange={(e) => setFormData({...formData, asnaf: e.target.value})}
          style={{ padding: '1rem', borderRadius: '0.75rem', background: 'rgba(15, 23, 42, 0.5)', color: 'var(--text-primary)', border: '1px solid var(--border-color)'}}
        >
          <option value="0">Fuqara (The Poor)</option>
          <option value="1">Masakeen (The Needy)</option>
          <option value="2">Amileen (Administrators)</option>
          <option value="3">Muallafah (Reconciliation)</option>
          <option value="4">Riqab (Freeing Captives)</option>
          <option value="5">Gharimeen (Those in Debt)</option>
          <option value="6">FiSabilillah (Cause of Allah)</option>
          <option value="7">IbnusSabil (Wayfarers)</option>
        </select>

        <label style={{ display: 'flex', alignItems: 'center', gap: '0.5rem' }}>
          <input 
            type="checkbox" 
            checked={formData.anonymous} 
            onChange={(e) => setFormData({...formData, anonymous: e.target.checked})} 
            style={{ width: 'auto' }}
          />
          Donate Anonymously
        </label>
        
        <button type="submit" className="btn btn-primary" disabled={isSubmitting}>
          {isSubmitting ? 'Processing...' : 'Give Zakat'}
        </button>
      </form>
      {error && <p style={{ color: 'var(--error-color)', fontSize: '0.875rem', marginTop: '1rem' }}>{error}</p>}
    </div>
  );
}
