// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {OwnableRoles} from "solady/src/auth/OwnableRoles.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "solady/src/utils/ReentrancyGuard.sol";

/// @title SwapEscrowETHZapper
/// @author @supersorbet
/// @notice External ETH wrapper for ERC20SwapEscrow contract
contract SwapEscrowETHZapper is ReentrancyGuard, OwnableRoles {
    using SafeTransferLib for address;

    error ZeroAddress();
    error ETHTransferFailed();
    error NotOwnerOrAdmin();
    error SwapNotFound();
    error FailedExecution();
    error WETHCallFailed();

    uint256 private constant ADMIN_ROLE = 1;
    bytes4 private constant WETH_DEPOSIT = 0xd0e30db0; ////deposit()
    bytes4 private constant WETH_WITHDRAW = 0x2e1a7d4d; ////withdraw(uint256)
    bytes4 private constant WETH_TRANSFER = 0xa9059cbb; ////transfer(address,uint256)

    bytes4 private constant ESCROW_CREATE_SWAP = 0xd5334a28; ////createSwap(address,uint256,address,uint256,uint64)
    bytes4 private constant ESCROW_GET_SWAP_INFO = 0x55e27080; ////getSwapInfo(uint256)
    bytes4 private constant ESCROW_ACCEPT_SWAP = 0xc21a3860; ////acceptSwap(uint256)

    /// @notice Main escrow contract address
    address public immutable escrowContract =
        0x1E89Dc58189e7E525a74ca5080150e16FF5762af;
    /// @notice WETH token address
    address public immutable wethToken =
        0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    /// @dev Swap tracker - maps swapId => claimed status for ETH swaps
    mapping(uint256 => bool) private claimedSwaps;

    constructor() {
        _initializeOwner(msg.sender);
    }

    /// @dev Required for receiving ETH from WETH withdrawals
    receive() external payable {}

    /// @notice Creates a swap by wrapping ETH to WETH and calling escrow
    /// @param tokenB Address of token to receive
    /// @param amountB Amount of tokenB to receive
    /// @param expiration Timestamp when the swap expires
    /// @return swapId The ID of the created swap
    function createETHSwap(
        address tokenB,
        uint256 amountB,
        uint64 expiration
    ) external payable nonReentrant returns (uint256 swapId) {
        uint256 ethAmount = msg.value;
        if (ethAmount == 0) {
            assembly {
                ////revert("AmountZero()")
                mstore(
                    0x00,
                    0x08c379a000000000000000000000000000000000000000000000000000000000
                )
                mstore(
                    0x04,
                    0x0000002000000000000000000000000000000000000000000000000000000000
                )
                mstore(
                    0x24,
                    0x000000094d617820455448000000000000000000000000000000000000000000
                )
                revert(0, 0x44)
            }
        }
        address _weth = wethToken;
        assembly {
            //// call weth.deposit{value: msg.value}()
            let success := call(gas(), _weth, ethAmount, 0, 0, 0, 0)
            if iszero(success) {
                //// WETHCallFailed()
                mstore(
                    0,
                    0x30871d2a00000000000000000000000000000000000000000000000000000000
                )
                revert(0, 4)
            }
        }
        _safeApprove(_weth, escrowContract, ethAmount);
        address _escrow = escrowContract;
        assembly {
            //// createSwap(address,uint256,address,uint256,uint64)
            mstore(0x00, ESCROW_CREATE_SWAP)
            mstore(0x04, _weth) ////tokenA (WETH)
            mstore(0x24, ethAmount) ////amountA
            mstore(0x44, tokenB) ////tokenB
            mstore(0x64, amountB) ////amountB
            mstore(0x84, expiration) ////expiration

            let success := call(
                gas(),
                _escrow,
                0, ////No ETH sent
                0x00, ////Input data starts at memory position 0
                0xa4, ////Input data size (4 + 32*5 = 164 bytes)
                0x00, ////Output starts at position 0
                0x20 ////Expected output is uint256 (32 bytes)
            )
            if iszero(success) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
            swapId := mload(0x00)
        }
        emit ETHSwapCreated(
            swapId,
            msg.sender,
            ethAmount,
            tokenB,
            amountB,
            expiration
        );
        return swapId;
    }

    /// @notice Accepts a swap with ETH where the swap is asking for WETH
    /// @param swapId ID of the swap to accept
    function acceptETHSwap(uint256 swapId) external payable nonReentrant {
        (
            address initiator,
            address tokenA,
            ,
            address tokenB,
            uint256 amountB,
            uint64 expiration,
            bool isFilled,
            bool isCanceled,

        ) = _getSwapInfo(swapId);
        if (tokenB != wethToken) revert("Not a WETH swap");
        if (isFilled) revert("Already filled");
        if (isCanceled) revert("Already canceled");
        if (block.timestamp > expiration) revert("Expired");
        if (msg.sender == initiator) revert("Initiator cannot accept");
        if (msg.value != amountB) revert("Incorrect ETH amount");
        address _weth = wethToken;
        assembly {
            ////call weth.deposit{value: msg.value}()
            let success := call(gas(), _weth, callvalue(), 0, 0, 0, 0)
            if iszero(success) {
                mstore(
                    0,
                    0x30871d2a00000000000000000000000000000000000000000000000000000000
                )
                revert(0, 4)
            }
        }
        _safeApprove(_weth, escrowContract, msg.value);
        address _escrow = escrowContract;
        assembly {
            mstore(0x00, ESCROW_ACCEPT_SWAP)
            mstore(0x04, swapId)
            let success := call(
                gas(),
                _escrow,
                0, ////No ETH sent
                0x00, ////Input data starts at memory position 0
                0x24, ////Input data size (4 + 32 = 36 bytes)
                0x00, ////Output data position
                0x00 ////No output expected
            )
            if iszero(success) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }

        emit ETHSwapAccepted(swapId, msg.sender, amountB, tokenA);
    }

    /// @notice Claims ETH from a swap that was filled where initiator offered WETH
    /// @param swapId ID of the swap to claim ETH from
    function claimETH(uint256 swapId) external nonReentrant {
        if (claimedSwaps[swapId]) revert("Already claimed");
        (
            ,
            ////initiator not used
            address tokenA,
            uint256 amountA, ////tokenB not used ////amountB not used ////expiration not used
            ,
            ,
            ,
            bool isFilled, ////isCanceled not used
            ,
            address counterparty
        ) = _getSwapInfo(swapId);

        if (!isFilled) revert("Not filled");
        if (counterparty != msg.sender) revert("Not counterparty");
        if (tokenA != wethToken) revert("Not a WETH swap");

        claimedSwaps[swapId] = true;

        address _weth = wethToken;
        uint256 _amountA = amountA;
        assembly {
            mstore(0x00, WETH_WITHDRAW)
            mstore(0x04, _amountA)
            let success := call(
                gas(),
                _weth,
                0, ////No ETH sent
                0x00, ////Input data starts at memory position 0
                0x24, ////Input data size (4 + 32 = 36 bytes)
                0x00, ////Output data position
                0x00 ////No output expected
            )

            if iszero(success) {
                mstore(
                    0,
                    0x30871d2a00000000000000000000000000000000000000000000000000000000
                )
                revert(0, 4)
            }
            success := call(
                gas(),
                caller(),
                _amountA, ////Send the ETH
                0, ////No input data
                0,
                0,
                0
            )

            if iszero(success) {
                mstore(
                    0,
                    0x90b8ec1800000000000000000000000000000000000000000000000000000000
                )
                revert(0, 4)
            }
        }

        emit ETHClaimed(swapId, msg.sender, amountA);
    }

    /// @dev Safely approves tokens with zero-first pattern for gas optimization
    /// @param token The token to approve
    /// @param spender The address to approve
    /// @param amount The amount to approve
    function _safeApprove(
        address token,
        address spender,
        uint256 amount
    ) internal {
        assembly {
            mstore(
                0x00,
                0x095ea7b300000000000000000000000000000000000000000000000000000000
            )
            mstore(0x04, spender)
            mstore(0x24, 0) //// 0 amount

            pop(call(gas(), token, 0, 0x00, 0x44, 0x00, 0x00))
            mstore(0x24, amount)

            let success := call(gas(), token, 0, 0x00, 0x44, 0x00, 0x20)
            if iszero(success) {
                mstore(
                    0,
                    0x7939f42400000000000000000000000000000000000000000000000000000000
                )
                revert(0, 4)
            }
        }
    }

    /// @dev Gets swap info from the escrow contract
    /// @param swapId Swap ID to query
    /// @return initiator Swap creator
    /// @return tokenA Token being offered
    /// @return amountA Amount of tokenA
    /// @return tokenB Token being requested
    /// @return amountB Amount of tokenB
    /// @return expiration Swap expiry timestamp
    /// @return isFilled Whether swap is filled
    /// @return isCanceled Whether swap is canceled
    /// @return counterparty Address that accepted the swap (if filled)
    function _getSwapInfo(uint256 swapId)
        internal
        view
        returns (
            address initiator,
            address tokenA,
            uint256 amountA,
            address tokenB,
            uint256 amountB,
            uint64 expiration,
            bool isFilled,
            bool isCanceled,
            address counterparty
        )
    {
        address _escrow = escrowContract;

        assembly {
            mstore(0x00, ESCROW_GET_SWAP_INFO)
            mstore(0x04, swapId)

            let success := staticcall(
                gas(),
                _escrow,
                0x00, ////Input data starts at memory position 0
                0x24, ////Input data size (4 + 32 = 36 bytes)
                0x00, ////Output data position
                0x120 ////Output size (9 * 32 = 288 bytes)
            )
            if iszero(success) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
            initiator := mload(0x00)
            tokenA := mload(0x20)
            amountA := mload(0x40)
            tokenB := mload(0x60)
            amountB := mload(0x80)
            expiration := mload(0xa0)
            isFilled := mload(0xc0)
            isCanceled := mload(0xe0)
            counterparty := mload(0x100)
        }
    }

    function rescueERC20(
        address token,
        uint256 amount,
        address destination
    ) external onlyOwnerOrAdmin {
        if (destination == address(0)) revert ZeroAddress();
        SafeTransferLib.safeTransfer(token, destination, amount);
    }

    function rescueETH(uint256 amount, address destination)
        external
        onlyOwnerOrAdmin
    {
        if (destination == address(0)) revert ZeroAddress();
        assembly {
            let success := call(gas(), destination, amount, 0, 0, 0, 0)
            if iszero(success) {
                mstore(
                    0,
                    0x90b8ec1800000000000000000000000000000000000000000000000000000000
                )
                revert(0, 4)
            }
        }
    }

    /// @dev Checks that the caller has the ADMIN_ROLE or is the contract owner.
    modifier onlyOwnerOrAdmin() {
        _checkRolesOrOwner(ADMIN_ROLE);
        _;
    }

    event ETHSwapCreated(
        uint256 indexed swapId,
        address indexed creator,
        uint256 ethAmount,
        address tokenB,
        uint256 amountB,
        uint64 expiration
    );

    event ETHSwapAccepted(
        uint256 indexed swapId,
        address indexed acceptor,
        uint256 ethAmount,
        address tokenReceived
    );

    event ETHClaimed(
        uint256 indexed swapId,
        address indexed claimer,
        uint256 amount
    );
}

/// @dev Minimal interface for the ERC20SwapEscrow contract
interface ISwapEscrow {
    function createSwap(
        address tokenA,
        uint256 amountA,
        address tokenB,
        uint256 amountB,
        uint64 expiration
    ) external returns (uint256 swapId);

    function acceptSwap(uint256 swapId) external;

    function getSwapInfo(uint256 swapId)
        external
        view
        returns (
            address initiator,
            address tokenA,
            uint256 amountA,
            address tokenB,
            uint256 amountB,
            uint64 expiration,
            bool isFilled,
            bool isCanceled,
            address counterparty
        );
}

/// @dev WETH interface - used for compilation validation
interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
    function transfer(address to, uint256 value) external returns (bool);
    function approve(address spender, uint256 value) external returns (bool);
}
