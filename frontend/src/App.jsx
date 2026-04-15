import { useState, useEffect } from 'react';
import { ethers } from 'ethers';
import { getSignerContract, getReadOnlyContract } from './ethereum/contract';
import CampaignList from './components/CampaignList';
import CreateCampaign from './components/CreateCampaign';
import ZakatPanel from './components/ZakatPanel';

function App() {
  const [account, setAccount] = useState('');
  const [isConnecting, setIsConnecting] = useState(false);
  const [errorMessage, setErrorMessage] = useState('');
  const [showCreate, setShowCreate] = useState(false);

  // Auto-check if already connected
  useEffect(() => {
    const checkIfWalletIsConnected = async () => {
      if (window.ethereum) {
        try {
          const accounts = await window.ethereum.request({ method: 'eth_accounts' });
          if (accounts.length > 0) {
            setAccount(accounts[0]);
          }
        } catch (err) {
          console.error(err);
        }
      }
    };
    checkIfWalletIsConnected();
  }, []);

  const connectWallet = async () => {
    try {
      setIsConnecting(true);
      setErrorMessage('');
      const contract = await getSignerContract();
      const addr = await contract.runner.getAddress();
      setAccount(addr);
    } catch (err) {
      setErrorMessage(err.message || 'Failed to connect wallet');
    } finally {
      setIsConnecting(false);
    }
  };

  return (
    <div className="app-container">
      <header>
        <div className="logo">IsalmiCharity</div>
        <div>
          {account ? (
            <div className="btn btn-outline">
              {`${account.substring(0, 6)}...${account.substring(account.length - 4)}`}
            </div>
          ) : (
            <button
              className="btn btn-primary"
              onClick={connectWallet}
              disabled={isConnecting}
            >
              {isConnecting ? 'Connecting...' : 'Connect Wallet'}
            </button>
          )}
        </div>
      </header>

      <main>
        {errorMessage && (
          <div className="glass-panel" style={{ borderColor: 'var(--error-color)', marginBottom: '2rem' }}>
            <p style={{ color: 'var(--error-color)' }}>{errorMessage}</p>
          </div>
        )}

        <section className="hero" style={{ textAlign: 'center', marginBottom: '4rem' }}>
          <h1>Transparent Giving on the Blockchain</h1>
          <p>Support verified campaigns directly with Ethereum. Zero middleman fees, 100% impact.</p>
        </section>

        <ZakatPanel />

        <section id="campaigns">
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: '2rem' }}>
            <h2>Active Campaigns</h2>
            {account && (
              <button
                className={showCreate ? "btn btn-outline" : "btn btn-primary"}
                onClick={() => setShowCreate(!showCreate)}
              >
                {showCreate ? 'Close Form' : 'Create Campaign'}
              </button>
            )}
          </div>

          {showCreate && <CreateCampaign onSuccess={() => setShowCreate(false)} />}

          <CampaignList connectedAccount={account} />
        </section>
      </main>
    </div>
  );
}

export default App;
