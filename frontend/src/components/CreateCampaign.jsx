import { useState } from 'react';
import { getSignerContract } from '../ethereum/contract';
import { ethers } from 'ethers';

export default function CreateCampaign({ onSuccess }) {
  const [formData, setFormData] = useState({
    title: '',
    description: '',
    goal: '',
    durationDays: '',
    initiativeId: '0'
  });
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [error, setError] = useState('');

  const handleChange = (e) => {
    setFormData({ ...formData, [e.target.name]: e.target.value });
  };

  const handleSubmit = async (e) => {
    e.preventDefault();
    try {
      setIsSubmitting(true);
      setError('');
      
      const contract = await getSignerContract();
      
      const goalWei = ethers.parseEther(formData.goal.toString());
      const durationSeconds = Number(formData.durationDays) * 24 * 60 * 60;
      
      const tx = await contract.createCampaign(
        formData.title,
        formData.description,
        goalWei,
        durationSeconds,
        Number(formData.initiativeId)
      );
      
      await tx.wait();
      
      setFormData({ title: '', description: '', goal: '', durationDays: '', initiativeId: '0' });
      if (onSuccess) onSuccess();
    } catch (err) {
      console.error(err);
      setError(err.reason || err.message || 'Error creating campaign');
    } finally {
      setIsSubmitting(false);
    }
  };

  return (
    <div className="glass-panel" style={{ marginBottom: '2rem', borderTop: '4px solid var(--secondary-color)' }}>
      <h2>Start a Campaign</h2>
      <form onSubmit={handleSubmit} style={{ display: 'flex', flexDirection: 'column', gap: '1rem' }}>
        <div>
          <input 
            type="text" 
            name="title" 
            placeholder="Campaign Title" 
            value={formData.title} 
            onChange={handleChange} 
            required 
          />
        </div>
        <div>
          <textarea 
            name="description" 
            placeholder="Campaign Description" 
            value={formData.description} 
            onChange={handleChange} 
            required 
            rows="3"
          />
        </div>
        <div style={{ display: 'flex', gap: '1rem' }}>
          <input 
            type="number" 
            name="goal" 
            placeholder="Goal (ETH)" 
            step="0.001"
            min="0.001"
            value={formData.goal} 
            onChange={handleChange} 
            required 
          />
          <input 
            type="number" 
            name="durationDays" 
            placeholder="Duration (Days)" 
            min="1"
            max="365"
            value={formData.durationDays} 
            onChange={handleChange} 
            required 
          />
        </div>
        <button type="submit" className="btn btn-primary" disabled={isSubmitting}>
          {isSubmitting ? 'Creating on Blockchain...' : 'Launch Campaign'}
        </button>
        {error && <p style={{ color: 'var(--error-color)', fontSize: '0.875rem' }}>{error}</p>}
      </form>
    </div>
  );
}
