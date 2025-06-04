///SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../src/BFSwapEscrowV1.2.sol";
import "../src/xUUPSSwapLib.sol";

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    uint256 public totalSupply;
    
    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }
    
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
    
    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;
        return true;
    }
    
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

contract MockBasedBrains {
    uint256 public tokenCounter = 100;
    mapping(uint256 => address) private tokenAddresses;
    
    function setBrainERC20Address(uint256 tokenId, address tokenAddr) external {
        tokenAddresses[tokenId] = tokenAddr;
    }
    
    function getBrainERC20Address(uint256 tokenId) external view returns (address) {
        return tokenAddresses[tokenId];
    }
}

contract BFSwapEscrowV1point2Test is Test {
    ERC20SwapEscrowV1point2 public escrow;
    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockERC20 public specialToken;
    MockBasedBrains public basedBrains;
    
    address public owner = makeAddr("owner");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");
    address public admin = makeAddr("admin");
    address public treasury = makeAddr("treasury");
    
    uint256 constant INITIAL_BALANCE = 1000e18;
    uint256 constant SWAP_AMOUNT_A = 100e18;
    uint256 constant SWAP_AMOUNT_B = 200e18;
    
    event SwapCreated(
        uint256 indexed swapId,
        address indexed initiator,
        address tokenA,
        uint256 amountA,
        address tokenB,
        uint256 amountB,
        uint64 expiration
    );
    
    event SwapAccepted(uint256 indexed swapId, address indexed counterparty);
    event SwapCanceled(uint256 indexed swapId, address indexed caller);
    
    function setUp() public {
        ///Deploy mock contracts
        tokenA = new MockERC20("TokenA", "TKA");
        tokenB = new MockERC20("TokenB", "TKB");
        specialToken = new MockERC20("Special", "SPEC");
        basedBrains = new MockBasedBrains();
        
        ///Setup brain tokens
        basedBrains.setBrainERC20Address(1, address(tokenA));
        basedBrains.setBrainERC20Address(2, address(tokenB));
        
        ///Deploy escrow as owner
        vm.startPrank(owner);
        escrow = new ERC20SwapEscrowV1point2();
        escrow.initialize();
        escrow.initializeV1point2();
        
        ///Set up initial configuration
        escrow.updateBasedBrains(address(basedBrains));
        escrow.setTreasury(treasury);
        escrow.grantRoles(admin, 1); ///ADMIN_ROLE
        escrow.setSpecialToken(address(specialToken), true);
        vm.stopPrank();
        
        ///Mint to users
        tokenA.mint(user1, INITIAL_BALANCE);
        tokenB.mint(user2, INITIAL_BALANCE);
        specialToken.mint(user1, INITIAL_BALANCE);
        specialToken.mint(user2, INITIAL_BALANCE);
        
        ///Validate brain tokens as admin
        vm.prank(admin);
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = 1;
        tokenIds[1] = 2;
        escrow.addBrainERC20ByIDs(tokenIds);
    }
    
    function testInit() public {
        assertEq(escrow.owner(), owner);
        assertEq(address(escrow.basedBrainsContract()), address(basedBrains));
        assertEq(escrow.treasury(), treasury);
        assertTrue(escrow.isSpecialToken(address(specialToken)));
        assertTrue(escrow.isBrainERC20(address(tokenA)));
        assertTrue(escrow.isBrainERC20(address(tokenB)));
    }
    
    function testCreateSwap() public {
        uint64 expiration = uint64(block.timestamp + 1 days);
        
        vm.startPrank(user1);
        tokenA.approve(address(escrow), SWAP_AMOUNT_A);
        
        vm.expectEmit(true, true, false, true);
        emit SwapCreated(1, user1, address(tokenA), SWAP_AMOUNT_A, address(tokenB), SWAP_AMOUNT_B, expiration);
        
        uint256 swapId = escrow.createSwap(
            address(tokenA),
            SWAP_AMOUNT_A,
            address(tokenB),
            SWAP_AMOUNT_B,
            expiration
        );
        
        assertEq(swapId, 1);
        assertEq(tokenA.balanceOf(address(escrow)), SWAP_AMOUNT_A);
        assertEq(tokenA.balanceOf(user1), INITIAL_BALANCE - SWAP_AMOUNT_A);
        assertEq(escrow.openSwapCount(user1), 1);
        vm.stopPrank();
    }
    
    function testAcceptSwap() public {
        ///Create swap first
        uint64 expiration = uint64(block.timestamp + 1 days);
        
        vm.startPrank(user1);
        tokenA.approve(address(escrow), SWAP_AMOUNT_A);
        uint256 swapId = escrow.createSwap(
            address(tokenA),
            SWAP_AMOUNT_A,
            address(tokenB),
            SWAP_AMOUNT_B,
            expiration
        );
        vm.stopPrank();
        
        ///Accept swap
        vm.startPrank(user2);
        tokenB.approve(address(escrow), SWAP_AMOUNT_B);
        
        vm.expectEmit(true, true, false, false);
        emit SwapAccepted(swapId, user2);
        
        escrow.acceptSwap(swapId);
        
        ///Check balances - no fees for brain tokens
        assertEq(tokenA.balanceOf(user2), SWAP_AMOUNT_A);
        assertEq(tokenB.balanceOf(user1), SWAP_AMOUNT_B);
        assertEq(escrow.openSwapCount(user1), 0);
        vm.stopPrank();
    }
    
    function testCancelSwap() public {
        uint64 expiration = uint64(block.timestamp + 1 days);
        
        vm.startPrank(user1);
        tokenA.approve(address(escrow), SWAP_AMOUNT_A);
        uint256 swapId = escrow.createSwap(
            address(tokenA),
            SWAP_AMOUNT_A,
            address(tokenB),
            SWAP_AMOUNT_B,
            expiration
        );
        
        vm.expectEmit(true, true, false, false);
        emit SwapCanceled(swapId, user1);
        
        escrow.cancelSwap(swapId);
        
        ///Check tokens returned
        assertEq(tokenA.balanceOf(user1), INITIAL_BALANCE);
        assertEq(tokenA.balanceOf(address(escrow)), 0);
        assertEq(escrow.openSwapCount(user1), 0);
        vm.stopPrank();
    }
    
    function testSpecialTokenFees() public {
        uint64 expiration = uint64(block.timestamp + 1 days);
        
        ///Create swap with special tokens
        vm.startPrank(user1);
        specialToken.approve(address(escrow), SWAP_AMOUNT_A);
        uint256 swapId = escrow.createSwap(
            address(specialToken),
            SWAP_AMOUNT_A,
            address(tokenB), ///brain token
            SWAP_AMOUNT_B,
            expiration
        );
        vm.stopPrank();
        
        ///Accept swap
        vm.startPrank(user2);
        tokenB.approve(address(escrow), SWAP_AMOUNT_B);
        escrow.acceptSwap(swapId);
        vm.stopPrank();
        
        ///Check fee was applied to special token only
        uint256 expectedFee = (SWAP_AMOUNT_A * escrow.feeRateBps()) / 10000;
        assertEq(specialToken.balanceOf(treasury), expectedFee);
        assertEq(specialToken.balanceOf(user2), SWAP_AMOUNT_A - expectedFee);
        assertEq(tokenB.balanceOf(user1), SWAP_AMOUNT_B); ///No fee on brain token
    }
    
    function testRevertConditions() public {
        uint64 expiration = uint64(block.timestamp + 1 days);
        
        vm.startPrank(user1);
        tokenA.approve(address(escrow), SWAP_AMOUNT_A);
        
        ///Test zero address
        vm.expectRevert(ZeroAddress.selector);
        escrow.createSwap(address(0), SWAP_AMOUNT_A, address(tokenB), SWAP_AMOUNT_B, expiration);
        
        ///Test same token swap
        vm.expectRevert(SameTokenSwap.selector);
        escrow.createSwap(address(tokenA), SWAP_AMOUNT_A, address(tokenA), SWAP_AMOUNT_B, expiration);
        
        ///Test zero amount
        vm.expectRevert(AmountZero.selector);
        escrow.createSwap(address(tokenA), 0, address(tokenB), SWAP_AMOUNT_B, expiration);
        
        ///Test expiration in past
        vm.expectRevert(ExpirationInPast.selector);
        escrow.createSwap(address(tokenA), SWAP_AMOUNT_A, address(tokenB), SWAP_AMOUNT_B, uint64(block.timestamp - 1));
        
        vm.stopPrank();
    }
    
    function testPauseUnpause() public {
        vm.prank(admin);
        escrow.setPaused(true);
        
        vm.startPrank(user1);
        tokenA.approve(address(escrow), SWAP_AMOUNT_A);
        
        vm.expectRevert(ContractPaused.selector);
        escrow.createSwap(
            address(tokenA),
            SWAP_AMOUNT_A,
            address(tokenB),
            SWAP_AMOUNT_B,
            uint64(block.timestamp + 1 days)
        );
        vm.stopPrank();
        
        ///Unpause
        vm.prank(admin);
        escrow.setPaused(false);
        
        ///Should work now
        vm.startPrank(user1);
        escrow.createSwap(
            address(tokenA),
            SWAP_AMOUNT_A,
            address(tokenB),
            SWAP_AMOUNT_B,
            uint64(block.timestamp + 1 days)
        );
        vm.stopPrank();
    }
    
    function testGetActiveSwaps() public {
        uint64 expiration = uint64(block.timestamp + 1 days);
        
        ///Create multiple swaps
        vm.startPrank(user1);
        tokenA.approve(address(escrow), SWAP_AMOUNT_A * 3);
        
        escrow.createSwap(address(tokenA), SWAP_AMOUNT_A, address(tokenB), SWAP_AMOUNT_B, expiration);
        escrow.createSwap(address(tokenA), SWAP_AMOUNT_A, address(tokenB), SWAP_AMOUNT_B, expiration);
        escrow.createSwap(address(tokenA), SWAP_AMOUNT_A, address(tokenB), SWAP_AMOUNT_B, expiration);
        vm.stopPrank();
        
        uint256[] memory activeSwaps = escrow.getActiveSwaps();
        assertEq(activeSwaps.length, 3);
        assertEq(activeSwaps[0], 1);
        assertEq(activeSwaps[1], 2);
        assertEq(activeSwaps[2], 3);
    }
    
    function testGetUserOpenSwaps() public {
        uint64 expiration = uint64(block.timestamp + 1 days);
        
        vm.startPrank(user1);
        tokenA.approve(address(escrow), SWAP_AMOUNT_A * 2);
        
        escrow.createSwap(address(tokenA), SWAP_AMOUNT_A, address(tokenB), SWAP_AMOUNT_B, expiration);
        escrow.createSwap(address(tokenA), SWAP_AMOUNT_A, address(tokenB), SWAP_AMOUNT_B, expiration);
        vm.stopPrank();
        
        uint256[] memory userSwaps = escrow.getUserOpenSwaps(user1);
        assertEq(userSwaps.length, 2);
        assertEq(userSwaps[0], 1);
        assertEq(userSwaps[1], 2);
    }
    
    function testFuzzCreateSwap(uint256 amountA, uint256 amountB, uint32 timeOffset) public {
        ///Bound inputs to reasonable ranges
        amountA = bound(amountA, 1e18, 1000e18);
        amountB = bound(amountB, 1e18, 1000e18);
        timeOffset = uint32(bound(timeOffset, 1 hours, 7 days));
        
        ///Mint enough tokens
        tokenA.mint(user1, amountA);
        
        uint64 expiration = uint64(block.timestamp + timeOffset);
        
        vm.startPrank(user1);
        tokenA.approve(address(escrow), amountA);
        
        uint256 swapId = escrow.createSwap(
            address(tokenA),
            amountA,
            address(tokenB),
            amountB,
            expiration
        );
        
        assertEq(swapId, escrow.swapCounter());
        assertEq(tokenA.balanceOf(address(escrow)), amountA);
        vm.stopPrank();
    }
} 