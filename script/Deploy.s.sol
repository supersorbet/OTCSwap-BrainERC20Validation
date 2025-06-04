// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/BFSwapEscrowV1.2.sol";

/**
 * @title Deployment Script for BasedBrains OTC Swap Escrow
 * @notice Professional deployment script with verification and configuration
 * @dev Handles both initial deployment and upgrades
 */
contract DeployScript is Script {
    // Configuration constants
    address constant BASED_BRAINS_MAINNET = 0xB0974F12C7BA2f1dC31f2C2545B71Ef1998815a4;
    address constant BASED_BRAINS_SEPOLIA = 0x0000000000000000000000000000000000000000; // Update if available
    
    uint8 constant DEFAULT_MAX_OPEN_SWAPS = 5;
    uint64 constant DEFAULT_MAX_EXPIRY = 604800; // 1 week
    uint16 constant DEFAULT_FEE_RATE = 69; // 0.69%
    
    // Events for tracking deployments
    event DeploymentCompleted(
        address indexed implementation,
        address indexed proxy,
        address indexed deployer,
        string network
    );
    
    event UpgradeCompleted(
        address indexed oldImplementation,
        address indexed newImplementation,
        address indexed proxy
    );

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("=== BasedBrains OTC Swap Escrow Deployment ===");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);
        console.log("Block number:", block.number);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy implementation contract
        ERC20SwapEscrowV1point2 implementation = new ERC20SwapEscrowV1point2();
        console.log("Implementation deployed at:", address(implementation));

        vm.stopBroadcast();
        
        // Verification outputs
        console.log("=== Deployment Summary ===");
        console.log("Implementation:", address(implementation));
        console.log("Deployer:", deployer);
        console.log("Chain:", getChainName(block.chainid));
        
        // Output for verification
        console.log("=== Verification Commands ===");
        console.log("Verify implementation with forge verify-contract");
        
        emit DeploymentCompleted(
            address(implementation),
            address(0), // No proxy in this simple deployment
            deployer,
            getChainName(block.chainid)
        );
    }
    
    /**
     * @notice Deploy a new implementation and upgrade existing proxy
     * @param proxyAddress Address of the existing proxy to upgrade
     */
    function upgrade(address proxyAddress) external {
        require(proxyAddress != address(0), "Invalid proxy address");
        
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("=== Upgrading OTC Swap Escrow ===");
        console.log("Proxy:", proxyAddress);
        console.log("Deployer:", deployer);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Get current implementation
        ERC20SwapEscrowV1point2 proxy = ERC20SwapEscrowV1point2(proxyAddress);
        address oldImplementation = getImplementation(proxyAddress);
        
        // Deploy new implementation
        ERC20SwapEscrowV1point2 newImplementation = new ERC20SwapEscrowV1point2();
        console.log("New implementation:", address(newImplementation));
        
        // Perform upgrade (assuming deployer is owner)
        proxy.upgradeTo(address(newImplementation));
        
        // Run any required reinitializers
        proxy.initializeV1point2();
        
        vm.stopBroadcast();
        
        console.log("Upgrade completed successfully");
        
        emit UpgradeCompleted(
            oldImplementation,
            address(newImplementation),
            proxyAddress
        );
    }
    
    /**
     * @notice Configure a deployed contract with initial settings
     * @param contractAddress Address of the deployed contract
     * @param treasuryAddress Address to receive fees
     * @param adminAddress Address to grant admin role
     */
    function configure(
        address contractAddress,
        address treasuryAddress,
        address adminAddress
    ) external {
        require(contractAddress != address(0), "Invalid contract address");
        require(treasuryAddress != address(0), "Invalid treasury address");
        require(adminAddress != address(0), "Invalid admin address");
        
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        console.log("=== Configuring OTC Swap Escrow ===");
        console.log("Contract:", contractAddress);
        console.log("Treasury:", treasuryAddress);
        console.log("Admin:", adminAddress);
        
        vm.startBroadcast(deployerPrivateKey);
        
        ERC20SwapEscrowV1point2 escrow = ERC20SwapEscrowV1point2(contractAddress);
        
        // Set treasury
        escrow.setTreasury(treasuryAddress);
        console.log("Treasury set");
        
        // Grant admin role
        escrow.grantRoles(adminAddress, 1); // ADMIN_ROLE = 1
        console.log("Admin role granted");
        
        // Set BasedBrains contract based on chain
        address basedBrainsAddress = getBasedBrainsAddress(block.chainid);
        if (basedBrainsAddress != address(0)) {
            escrow.updateBasedBrains(basedBrainsAddress);
            console.log("BasedBrains contract set");
        }
        
        // Configure parameters
        escrow.setMaxOpenSwaps(DEFAULT_MAX_OPEN_SWAPS);
        escrow.setMaxExpiryLimit(DEFAULT_MAX_EXPIRY);
        escrow.setFeeRate(DEFAULT_FEE_RATE);
        
        console.log("Parameters configured");
        
        vm.stopBroadcast();
        
        console.log("=== Configuration Complete ===");
    }
    
    /**
     * @notice Deploy and configure in a single transaction
     * @param treasuryAddress Address to receive fees
     * @param adminAddress Address to grant admin role
     */
    function deployAndConfigure(
        address treasuryAddress,
        address adminAddress
    ) external returns (address) {
        require(treasuryAddress != address(0), "Invalid treasury address");
        require(adminAddress != address(0), "Invalid admin address");
        
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("=== Full Deployment & Configuration ===");
        console.log("Deployer:", deployer);
        console.log("Treasury:", treasuryAddress);
        console.log("Admin:", adminAddress);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy implementation
        ERC20SwapEscrowV1point2 escrow = new ERC20SwapEscrowV1point2();
        
        // Initialize
        escrow.initialize();
        escrow.initializeV1point2();
        
        // Configure
        escrow.setTreasury(treasuryAddress);
        escrow.grantRoles(adminAddress, 1);
        
        // Set BasedBrains contract
        address basedBrainsAddress = getBasedBrainsAddress(block.chainid);
        if (basedBrainsAddress != address(0)) {
            escrow.updateBasedBrains(basedBrainsAddress);
        }
        
        vm.stopBroadcast();
        
        console.log("Deployment and configuration complete");
        console.log("Contract address:", address(escrow));
        
        return address(escrow);
    }
    
    // Helper functions
    
    function getChainName(uint256 chainId) internal pure returns (string memory) {
        if (chainId == 1) return "mainnet";
        if (chainId == 11155111) return "sepolia";
        if (chainId == 137) return "polygon";
        if (chainId == 42161) return "arbitrum";
        if (chainId == 10) return "optimism";
        if (chainId == 8453) return "base";
        return "unknown";
    }
    
    function getBasedBrainsAddress(uint256 chainId) internal pure returns (address) {
        if (chainId == 1) return BASED_BRAINS_MAINNET;
        if (chainId == 11155111) return BASED_BRAINS_SEPOLIA;
        return address(0);
    }
    
    function getImplementation(address proxy) internal view returns (address) {
        // Get implementation address from proxy storage slot
        bytes32 slot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        bytes32 impl;
        assembly {
            impl := sload(slot)
        }
        return address(uint160(uint256(impl)));
    }
}

/**
 * @title Deployment Configuration
 * @notice Environment-specific configuration helper
 */
contract DeploymentConfig {
    struct Config {
        address basedBrains;
        address treasury;
        address admin;
        uint16 feeRate;
        uint8 maxOpenSwaps;
        uint64 maxExpiry;
        string name;
    }
    
    function getConfig(uint256 chainId) external pure returns (Config memory) {
        if (chainId == 1) {
            return Config({
                basedBrains: 0xB0974F12C7BA2f1dC31f2C2545B71Ef1998815a4,
                treasury: address(0), // Set based on deployment requirements
                admin: address(0),    // Set based on deployment requirements
                feeRate: 69,          // 0.69%
                maxOpenSwaps: 5,
                maxExpiry: 604800,    // 1 week
                name: "mainnet"
            });
        }
        
        if (chainId == 11155111) {
            return Config({
                basedBrains: address(0), // Update if testnet deployment available
                treasury: address(0),
                admin: address(0),
                feeRate: 420,            // 4.20% for testing
                maxOpenSwaps: 10,        // Higher limit for testing
                maxExpiry: 86400,        // 1 day for testing
                name: "sepolia"
            });
        }
        
        // Default config
        return Config({
            basedBrains: address(0),
            treasury: address(0),
            admin: address(0),
            feeRate: 100,
            maxOpenSwaps: 5,
            maxExpiry: 604800,
            name: "unknown"
        });
    }
} 