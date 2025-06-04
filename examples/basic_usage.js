/**
 * BasedBrains OTC Swap Example
 * 
 * This example demonstrates basic interaction with the OTC swap escrow contract
 * using ethers.js for frontend integration.
 */

const { ethers } = require('ethers');

// Contract ABI excerpts (simplified for demo)
const ESCROW_ABI = [
    "function createSwap(address tokenA, uint256 amountA, address tokenB, uint256 amountB, uint64 expiration) external returns (uint256)",
    "function acceptSwap(uint256 swapId) external",
    "function cancelSwap(uint256 swapId) external", 
    "function getSwapInfo(uint256 swapId) external view returns (tuple)",
    "function getActiveSwaps() external view returns (uint256[])",
    "function getTokenMarketData(address token) external view returns (uint256, uint256, uint256, uint256, uint256)",
    "event SwapCreated(uint256 indexed swapId, address indexed initiator, address tokenA, uint256 amountA, address tokenB, uint256 amountB, uint64 expiration)",
    "event SwapAccepted(uint256 indexed swapId, address indexed counterparty)",
    "event SwapCanceled(uint256 indexed swapId, address indexed caller)"
];

const ERC20_ABI = [
    "function approve(address spender, uint256 amount) external returns (bool)",
    "function balanceOf(address owner) external view returns (uint256)",
    "function allowance(address owner, address spender) external view returns (uint256)"
];

class OTCSwapClient {
    constructor(escrowAddress, provider, signer) {
        this.escrow = new ethers.Contract(escrowAddress, ESCROW_ABI, signer);
        this.provider = provider;
        this.signer = signer;
    }

    /**
     * Create a new token swap
     * @param {string} tokenA - Address of token being offered
     * @param {string} amountA - Amount of tokenA (in wei)
     * @param {string} tokenB - Address of token being requested  
     * @param {string} amountB - Amount of tokenB (in wei)
     * @param {number} expirationHours - Hours until expiration
     * @returns {Promise<object>} Transaction receipt with swap ID
     */
    async createSwap(tokenA, amountA, tokenB, amountB, expirationHours = 24) {
        try {
            // Calculate expiration timestamp
            const expiration = Math.floor(Date.now() / 1000) + (expirationHours * 3600);
            
            // Approve token spending first
            const tokenContract = new ethers.Contract(tokenA, ERC20_ABI, this.signer);
            const approveTx = await tokenContract.approve(this.escrow.address, amountA);
            await approveTx.wait();
            
            console.log(`✅ Approved ${amountA} tokens for escrow`);
            
            // Create the swap
            const tx = await this.escrow.createSwap(
                tokenA,
                amountA, 
                tokenB,
                amountB,
                expiration
            );
            
            const receipt = await tx.wait();
            
            // Extract swap ID from events
            const swapCreatedEvent = receipt.events?.find(e => e.event === 'SwapCreated');
            const swapId = swapCreatedEvent?.args?.swapId;
            
            console.log(`🎉 Swap created successfully! ID: ${swapId}`);
            
            return {
                swapId: swapId?.toString(),
                transactionHash: receipt.transactionHash,
                blockNumber: receipt.blockNumber
            };
            
        } catch (error) {
            console.error('Error creating swap:', error);
            throw error;
        }
    }

    /**
     * Accept an existing swap
     * @param {string} swapId - ID of the swap to accept
     * @returns {Promise<object>} Transaction receipt
     */
    async acceptSwap(swapId) {
        try {
            // Get swap details first
            const swapInfo = await this.escrow.getSwapInfo(swapId);
            
            // Approve tokenB spending
            const tokenContract = new ethers.Contract(swapInfo.tokenB, ERC20_ABI, this.signer);
            const approveTx = await tokenContract.approve(this.escrow.address, swapInfo.amountB);
            await approveTx.wait();
            
            console.log(`✅ Approved ${swapInfo.amountB} tokens for swap acceptance`);
            
            // Accept the swap
            const tx = await this.escrow.acceptSwap(swapId);
            const receipt = await tx.wait();
            
            console.log(`🤝 Swap ${swapId} accepted successfully!`);
            
            return {
                transactionHash: receipt.transactionHash,
                blockNumber: receipt.blockNumber
            };
            
        } catch (error) {
            console.error('Error accepting swap:', error);
            throw error;
        }
    }

    /**
     * Cancel your own swap
     * @param {string} swapId - ID of the swap to cancel
     * @returns {Promise<object>} Transaction receipt
     */
    async cancelSwap(swapId) {
        try {
            const tx = await this.escrow.cancelSwap(swapId);
            const receipt = await tx.wait();
            
            console.log(`❌ Swap ${swapId} canceled successfully`);
            
            return {
                transactionHash: receipt.transactionHash,
                blockNumber: receipt.blockNumber
            };
            
        } catch (error) {
            console.error('Error canceling swap:', error);
            throw error;
        }
    }

    /**
     * Get all active swap IDs
     * @returns {Promise<string[]>} Array of active swap IDs
     */
    async getActiveSwaps() {
        try {
            const swapIds = await this.escrow.getActiveSwaps();
            return swapIds.map(id => id.toString());
        } catch (error) {
            console.error('Error fetching active swaps:', error);
            throw error;
        }
    }

    /**
     * Get market data for a specific token
     * @param {string} tokenAddress - Address of the token
     * @returns {Promise<object>} Market data
     */
    async getTokenMarketData(tokenAddress) {
        try {
            const [buyCount, sellCount, lowestSell, highestBuy, totalVolume] = 
                await this.escrow.getTokenMarketData(tokenAddress);
            
            return {
                buyOrders: buyCount.toString(),
                sellOrders: sellCount.toString(), 
                lowestSellPrice: ethers.utils.formatEther(lowestSell),
                highestBuyPrice: ethers.utils.formatEther(highestBuy),
                totalVolume: ethers.utils.formatEther(totalVolume)
            };
            
        } catch (error) {
            console.error('Error fetching market data:', error);
            throw error;
        }
    }

    /**
     * Listen for swap events
     * @param {function} onSwapCreated - Callback for SwapCreated events
     * @param {function} onSwapAccepted - Callback for SwapAccepted events
     */
    setupEventListeners(onSwapCreated, onSwapAccepted) {
        this.escrow.on('SwapCreated', (swapId, initiator, tokenA, amountA, tokenB, amountB, expiration) => {
            if (onSwapCreated) {
                onSwapCreated({
                    swapId: swapId.toString(),
                    initiator,
                    tokenA,
                    amountA: ethers.utils.formatEther(amountA),
                    tokenB,
                    amountB: ethers.utils.formatEther(amountB),
                    expiration: new Date(expiration * 1000)
                });
            }
        });

        this.escrow.on('SwapAccepted', (swapId, counterparty) => {
            if (onSwapAccepted) {
                onSwapAccepted({
                    swapId: swapId.toString(),
                    counterparty
                });
            }
        });
    }
}

// Example usage
async function example() {
    // Connect to Ethereum (replace with your RPC URL)
    const provider = new ethers.providers.JsonRpcProvider('YOUR_RPC_URL');
    const signer = new ethers.Wallet('YOUR_PRIVATE_KEY', provider);
    
    // Initialize client (replace with actual deployed contract address)
    const escrowAddress = '0x...'; // Your deployed escrow contract
    const client = new OTCSwapClient(escrowAddress, provider, signer);
    
    // Example: Create a swap
    const tokenA = '0x...'; // USDC
    const tokenB = '0x...'; // WETH
    const amountA = ethers.utils.parseUnits('1000', 6); // 1000 USDC
    const amountB = ethers.utils.parseUnits('0.5', 18); // 0.5 WETH
    
    try {
        const result = await client.createSwap(
            tokenA,
            amountA,
            tokenB, 
            amountB,
            48 // 48 hours expiration
        );
        
        console.log('Swap created:', result);
        
        // Get market data
        const marketData = await client.getTokenMarketData(tokenA);
        console.log('Market data:', marketData);
        
    } catch (error) {
        console.error('Example failed:', error);
    }
}

// React hook example
function useOTCSwap(escrowAddress) {
    const [swaps, setSwaps] = useState([]);
    const [loading, setLoading] = useState(false);
    
    const createSwap = useCallback(async (tokenA, amountA, tokenB, amountB) => {
        setLoading(true);
        try {
            const client = new OTCSwapClient(escrowAddress, provider, signer);
            const result = await client.createSwap(tokenA, amountA, tokenB, amountB);
            // Refresh swaps list
            await fetchActiveSwaps();
            return result;
        } finally {
            setLoading(false);
        }
    }, [escrowAddress]);
    
    const fetchActiveSwaps = useCallback(async () => {
        try {
            const client = new OTCSwapClient(escrowAddress, provider, signer);
            const activeSwapIds = await client.getActiveSwaps();
            setSwaps(activeSwapIds);
        } catch (error) {
            console.error('Failed to fetch swaps:', error);
        }
    }, [escrowAddress]);
    
    return {
        swaps,
        loading,
        createSwap,
        fetchActiveSwaps
    };
}

module.exports = {
    OTCSwapClient,
    example,
    useOTCSwap
}; 