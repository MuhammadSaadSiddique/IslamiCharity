import { ethers } from "ethers";

// Fallback/Demo Address: replace with actual Hardhat/Sepolia deployed address
export const CONTRACT_ADDRESS = import.meta.env.VITE_CONTRACT_ADDRESS || "0xd9145CCE52D386f254917e481eB44e9943F39138";

const contractABI = [
  // Read Methods
  "function campaignCount() view returns (uint256)",
  "function getCampaign(uint256 id) view returns (tuple(address creator, string title, string description, uint256 goal, uint256 deadline, uint256 totalRaised, uint8 status, bool withdrawalApproved, uint256 withdrawalRequestedAt, uint256 initiativeId))",
  "function zakatPool() view returns (uint256)",
  "function hasReceivedPayout(address) view returns (bool)",

  // Write Methods
  "function createCampaign(string title, string description, uint256 goal, uint256 duration, uint256 initiativeId) returns (uint256)",
  "function donate(uint256 campaignId) payable",
  "function donateZakat(uint8 asnaf, bool anonymous) payable",
  "function claimRefund(uint256 campaignId)",
  "function withdraw(uint256 campaignId)",
  "function requestWithdrawal(uint256 campaignId)",

  // Events
  "event CampaignCreated(uint256 indexed campaignId, address indexed creator, string title, uint256 goal, uint256 deadline, uint256 indexed initiativeId)",
  "event DonationReceived(uint256 indexed campaignId, address indexed donor, uint256 amount, uint256 newTotal)",
  "event GoalReached(uint256 indexed campaignId, uint256 totalRaised)",
  "event WithdrawalRequested(uint256 indexed campaignId, address indexed creator)"
];

/**
 * Gets a read-only instance of the contract.
 * Used for fetching data (campaigns, zakat pool, etc) without requiring a wallet connection.
 * @returns {ethers.Contract}
 */
export const getReadOnlyContract = async () => {
  // Use a fallback public provider or default local provider
  let provider;
  if (window.ethereum) {
    provider = new ethers.BrowserProvider(window.ethereum);
  } else {
    // Connect to localhost by default
    provider = new ethers.JsonRpcProvider("https://evm.wirefluid.com");
  }
  return new ethers.Contract(CONTRACT_ADDRESS, contractABI, provider);
};

/**
 * Gets a read-write instance of the contract with a connected Metamask signer.
 * Prompts the user to connect their wallet if not already connected.
 * @returns {Promise<ethers.Contract>}
 */
export const getSignerContract = async () => {
  if (!window.ethereum) {
    throw new Error("No crypto wallet found. Please install MetaMask.");
  }
  await window.ethereum.request({ method: "eth_requestAccounts" });

  const targetChainId = "0x16975"; // hex for 92533 (WireFluid Testnet)
  const currentChainId = await window.ethereum.request({ method: 'eth_chainId' });

  if (currentChainId !== targetChainId) {
    try {
      await window.ethereum.request({
        method: 'wallet_switchEthereumChain',
        params: [{ chainId: targetChainId }],
      });
    } catch (switchError) {
      // 4902 means the chain hasn't been added to MetaMask yet
      if (switchError.code === 4902) {
        try {
          await window.ethereum.request({
            method: 'wallet_addEthereumChain',
            params: [
              {
                chainId: targetChainId,
                chainName: 'WireFluid Testnet',
                nativeCurrency: { name: 'WIRE', symbol: 'WIRE', decimals: 18 },
                rpcUrls: ['https://evm.wirefluid.com'],
                blockExplorerUrls: ['https://wirefluidscan.com']
              }
            ],
          });
        } catch (addError) {
          throw new Error('Failed to add WireFluid testnet to your wallet.');
        }
      } else {
        throw new Error('Please switch to the WireFluid testnet in your wallet.');
      }
    }
  }

  const provider = new ethers.BrowserProvider(window.ethereum);
  const signer = await provider.getSigner();
  return new ethers.Contract(CONTRACT_ADDRESS, contractABI, signer);
};
