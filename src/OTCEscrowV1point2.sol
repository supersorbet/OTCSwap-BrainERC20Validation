// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {UUPSUpgradeable} from "solady/src/utils/UUPSUpgradeable.sol";
import {Initializable} from "solady/src/utils/Initializable.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";
import {OwnableRoles} from "solady/src/auth/OwnableRoles.sol";
import {ReentrancyGuard} from "solady/src/utils/ReentrancyGuard.sol";
import {LibBit, LibBitmap} from "solady/src/utils/LibBitmap.sol";
import {SwapMarketLib} from "./xUUPSSwapLib.sol";

/*⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️
⚒️⁂            ERRORS & CONSTANTS            ⚒️⁂
⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️*/

 error ZeroAddress();
 error BlacklistedToken();
 error AmountZero();
 error ExpirationInPast();
 error SwapAlreadyFilled();
 error SwapAlreadyCanceled();
 error SwapExpired();
 error InitiatorCannotAccept();
 error NotInitiator();
 error NotAdminOrOwner();
 error ContractPaused();
 error EMSActive();
 error NotInEMSShutdown();
 error TokenNotValidated(address token);
 error BrainTokenAmountTooLow(address token, uint256 provided, uint256 minimum);
 error TooManyOpenSwaps(address sender, uint256 count);
 error ExpiryTooFar(uint256 maxAllowedTimestamp);
 error BatchSizeTooLarge(uint256 provided, uint256 maximum);
 error InvalidTokenStandard();
 error SameTokenSwap();
 error NoSwapAvailable();
 error ArrayLengthMismatch();
 error SwapNotFound();
 error FeeTooHigh();

//// 🛠️🛠️🛠️🛠️ Bit Flags for Swap State 🛠️🛠️🛠️🛠️
uint8 constant FLAG_FILLED = 1 << 0;
uint8 constant FLAG_CANCELED = 1 << 1;

////🛠️🛠️🛠️🛠️ Role Constant 🛠️🛠️🛠️🛠️
uint256 constant ADMIN_ROLE = 1;

//// 🛠️🛠️🛠️🛠️ Config Constants 🛠️🛠️🛠️🛠️
uint8 constant DEFAULT_MAX_OPEN_SWAPS = 5;
uint256 constant MAX_BATCH_SIZE = 1024;
uint256 constant MIN_BYTECODE_SIZE = 10;

/// @title OTCEscrowV1point2 ˗
/// @author @supersorbet˗
/// @notice Trustless escrow/OTC for P2P ERC20 swaps indexing BasedAIBrains
/// @dev UUPS offering: 💭ˎˊ˗
/// @dev - ERC20-to-ERC20 direct swaps with expiration mechanics
/// @dev - Strict token validation through a BasedBrains registry
/// @dev - Extended views for fully on-chain swap insights and analytics
/// @dev
/// @dev Ability to create, accept, and cancel token swaps in a secure non-custodial manner.
/// @dev Each swap order specifies an amount of tokenA in exchange for tokenB, with a designated expiration time.
/// @dev Bitmap and assembly-based optimized logic [avg -80% on tracking & storage ops compared to standard mapping practices],
/// @dev ensuring efficient, cost-effective swaps for participants.
contract OTCEscrowV1point2 is
    ReentrancyGuard,
    OwnableRoles,
    UUPSUpgradeable,
    Initializable
{
    using SafeTransferLib for address;
    using FixedPointMathLib for uint256;
    using LibBitmap for LibBitmap.Bitmap;
    using SwapMarketLib for *;

    /*⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂
    ⚒️⁂⁂               STORAGE VARS                ⚒️⁂⁂
    ⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⁷*/

    /// @dev Tracks processed token IDs for the BasedBrains system (avoids double-processing).
    LibBitmap.Bitmap private processedBitmap;

    /// @notice Mapping of token => whether this token is recognized as a "brain" ERC20.
    mapping(address => bool) public isBrainERC20;

    /// @dev Tracks the last tokenId checked in the BasedBrains contract for iteration purposes.
    uint256 public lastCheckedTokenId;

    /// @notice Array of all validated brain ERC20 tokens.
    address[] public brainERC20List;

    /// @dev Mapping of token => index in the brainERC20List array.
    mapping(address => uint256) private brainERC20Index;

    /// @notice Sequential counter for swap IDs.
    uint256 public swapCounter;
    /// @dev Mapping of swapId => Swap.
    mapping(uint256 => Swap) public swaps;

    /// @notice Per-user tracking of open swaps.
    /// @dev userOpenSwaps[user] is an array of that user’s active swapIds.
    mapping(address => uint256[]) private userOpenSwaps;

    /// @dev Mapping from user => swapId => index in userOpenSwaps[user].
    mapping(address => mapping(uint256 => uint256)) private swapToUserIndex;

    /// @notice Tracks how many open swaps a user has at any given time.
    mapping(address => uint8) public openSwapCount;

    /// @notice Maximum number of open swaps a user may have at once.
    uint8 public maxOpenSwaps;

    /// @notice Maximum allowed expiration offset (e.g. 1 week).
    uint64 public maxExpiryLimit;

    /// @notice Minimum required amount for swaps involving brain tokens.
    uint256 public brainTokenMinimumAmount;

    /// @notice Reference to an external BasedBrains contract.
    IBasedBrains public basedBrainsContract;

    /// @notice Array of special tokens.
    address[] public specialTokenList;

    /// @notice Mapping to check if a token is special (non-brain but still allowed).
    mapping(address => bool) public isSpecialToken;

    /// @dev Tracks the index of each token in specialTokenList.
    mapping(address => uint256) private specialTokenIndex;

    /// @notice Mapping of token => blacklisted status.
    mapping(address => bool) public blacklistedTokens;

    /// @notice Fee rate in basis points9
    uint16 public feeRateBps = 69; //// 0.69%

    /// @notice Address that receives fee transfers.
    address public treasury;

    /// @notice Global pause flag; if true, creation/accept is disallowed.
    bool public paused;

    /// @notice ems shutdown flag; if true, only `emsWithdraw` is allowed.
    bool public shutdownActive;

    /*⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂
    ⚒️⁂⁂                 SWAP STRUCTS                   ⚒️⁂⁂
    ⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂*/

    /// @notice Storage container for a single token swap transaction.
    /// @dev Optimized storage layout in 6 slots:
    ///      Slot 0: initiator (20 bytes) | expiration (8 bytes) | flags (1 byte) | (3 bytes padding)
    ///      Slot 1: tokenA (20 bytes) - the token being offered
    ///      Slot 2: tokenB (20 bytes) - the token being requested
    ///      Slot 3: counterparty (20 bytes) - who accepted the swap (if filled)
    ///      Slot 4: amountA (32 bytes) - amount of tokenA being offered
    ///      Slot 5: amountB (32 bytes) - amount of tokenB being requested
    struct Swap {
        address initiator;
        uint64 expiration;
        uint8 flags;
        address tokenA;
        address tokenB;
        address counterparty;
        uint256 amountA;
        uint256 amountB;
    }

    /// @notice Additional metadata for each token: brain or special.
    struct TokenData {
        bool isBrain;
        bool isSpecial;
    }

    /// @notice Detailed information about a swap for external display and user interfaces.
    /// @dev Combines core swap data with derived fields like fee calculations and time remaining.
    struct SwapInfo {
        uint256 swapId; /// Unique swap identifier
        address initiator; /// Who created the swap
        address tokenA; /// Token being offered
        TokenData tokenAData; /// Additional token A info
        uint256 amountA; /// Amount of token A
        uint256 tokenAFee; /// Fee amount for token A
        uint256 tokenAAfterFee; /// Net amount after fee for token A
        address tokenB; /// Token being requested
        TokenData tokenBData; /// Additional token B info
        uint256 amountB; /// Amount of token B
        uint256 tokenBFee; /// Fee amount for token B
        uint256 tokenBAfterFee; /// Net amount after fee for token B
        uint64 expiration; /// Raw expiration timestamp
        bool isExpired; /// Whether the swap has expired
        bool isFilled; /// Whether the swap has been filled
        bool isCanceled; /// Whether the swap has been canceled
        address counterparty; /// Who filled the swap [if filled]
        uint64 remainingTime; /// Seconds until expiration
    }

    LibBitmap.Bitmap private emptyProcessedBitmap;///added in V1.2

    /// @dev Storage gap for future upgrades
    uint256[49] private __gap;

    /*⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂
    ⚒️⁂⁂                MODIFIERS                  ⚒️⁂⁂
    ⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⁷*/

    /// @dev Checks that the caller has the ADMIN_ROLE or is the contract owner.
    modifier onlyAdminOrOwner() {
        _checkRolesOrOwner(ADMIN_ROLE);
        _;
    }
    /// @dev Ensures the contract is not paused.
    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }
    /// @dev Ensures the contract is not under  shutdown.
    modifier whenOperational() {
        if (shutdownActive) revert EMSActive();
        _;
    }
    /// @dev Validates that a swapId is within known bounds.
    modifier validSwapId(uint256 swapId) {
        if (swapId == 0 || swapId > swapCounter) revert NoSwapAvailable();
        _;
    }

    /*⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂
    ⚒️⁂           CONSTRUCTOR//INIT            ⚒️⁂
    ⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂*/

    /// @dev Empty constructor disables initializers on the implementation contract.
    constructor() {
        _disableInitializers();
        basedBrainsContract = IBasedBrains(
            0xB0974F12C7BA2f1dC31f2C2545B71Ef1998815a4
        );
    }

    /// @notice initializer
    ///      sets msg.sender as owner, sets a known BasedBrains address,
    ////        && defaults for feeRate, expiry, etc.
    function initialize() external initializer {
        _initializeOwner(msg.sender);
        maxOpenSwaps = DEFAULT_MAX_OPEN_SWAPS;
        maxExpiryLimit = 604800; //// 1 week
        feeRateBps = 420; //// 4.20%
        basedBrainsContract = IBasedBrains(
            0xB0974F12C7BA2f1dC31f2C2545B71Ef1998815a4
        );
    }

    /// @dev Authorize upgrade - only owner can upgrade the implementation
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyOwner
    {}

    /// @notice Initializes V1.2 storage and functionality
    /// @dev Uses reinitializer modifier to ensure it can only be called once per implementation
    function initializeV1point2() external reinitializer(2) {
        ////new bitmap for unactivated brainERC20s
        emit UpgradeInitialized(2);
    }

    /*⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂
    ⚒️⁂                  BITMAP                      ⚒️⁂
    ⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⁷*/

    /// @notice Checks if a given tokenId has been processed.
    function isProcessed(uint256 tokenId) internal view returns (bool) {
        return processedBitmap.get(tokenId);
    }

    /// @notice Marks a given tokenId as processed.
    function setProcessed(uint256 tokenId) internal {
        ////set bit (one SSTORE).
        if (!processedBitmap.get(tokenId)) {
            processedBitmap.set(tokenId);
        }
    }

    /// @notice processing logic that tracks empty tokens
    /// @param tokenId The ID to process
    /// @param tokenAddr The current address for token ID [[may be zero]]
    /// @dev Updates both the main processed bitmap and the empty token bitmap
    function _processTokenId(uint256 tokenId, address tokenAddr) internal {
        if (!processedBitmap.get(tokenId)) {
            processedBitmap.set(tokenId);
            ////if zero addr, mark it in empty/unactivated bitmap
            if (tokenAddr == address(0)) {
                emptyProcessedBitmap.set(tokenId);
            }
        }
    }

    //////  @notice 🧠 Batch-validate tokens using the BasedBrains registry.
    ///       1️⃣ Iterate over the token IDs within [startId..endId).
    ///       2️⃣ For each unprocessed ID, retrieve its token address from BasedBrains.
    ///          - assembly reading bitmap checks and updates for gas efficiency.
    ///       3️⃣ If valid, store and emit BrainTokenValidated, else mark as empty.
    ///  @param batchSize The number of token IDs to process in this batch.
    function populateBrainERC20s(uint256 batchSize) external onlyAdminOrOwner {
        if (batchSize > MAX_BATCH_SIZE)
            revert BatchSizeTooLarge(batchSize, MAX_BATCH_SIZE);
        uint256 maxTokens = basedBrainsContract.tokenCounter();
        uint256 startId = lastCheckedTokenId;
        uint256 endId = (startId + batchSize > maxTokens)
            ? maxTokens
            : startId + batchSize;
        uint256 initialGas = gasleft();
        uint256 processedId = startId;
        uint256 validTokensFound = 0;
        for (uint256 tokenId = startId; tokenId < endId; ) {
            uint256 wordPos = tokenId / 256;
            uint256 bitPos = tokenId % 256;
            bool alreadyProcessed;
            /// @solidity memory-safe-assembly
            assembly {
                // Prepare memory for keccak256: [wordPos, processedBitmap.slot]
                mstore(0x00, wordPos)
                mstore(0x20, processedBitmap.slot)
                let slotKey := keccak256(0x00, 0x40)
                let word := sload(slotKey)
                let mask := shl(bitPos, 1)
                alreadyProcessed := gt(and(word, mask), 0)
            }
            if (alreadyProcessed) {
                processedId = tokenId + 1;
                unchecked { ++tokenId; }
                continue;
            }
            address tokenAddr = basedBrainsContract.getBrainERC20Address(tokenId);
            /// @solidity memory-safe-assembly
            assembly {
                // Prepare memory for keccak256: [wordPos, processedBitmap.slot]
                mstore(0x00, wordPos)
                mstore(0x20, processedBitmap.slot)
                let slotKey := keccak256(0x00, 0x40)
                let word := sload(slotKey)
                let mask := shl(bitPos, 1)
                sstore(slotKey, or(word, mask))
                // If tokenAddr is zero, mark in emptyProcessedBitmap
                if iszero(tokenAddr) {
                    // Prepare memory for keccak256: [wordPos, emptyProcessedBitmap.slot]
                    mstore(0x00, wordPos)
                    mstore(0x20, emptyProcessedBitmap.slot)
                    let empSlotKey := keccak256(0x00, 0x40)
                    let empWord := sload(empSlotKey)
                    sstore(empSlotKey, or(empWord, mask))
                }
            }
            // If non-zero and not already known, check `_isValidERC20`
            if (tokenAddr != address(0) && !isBrainERC20[tokenAddr]) {
                if (_isValidERC20(tokenAddr)) {
                    isBrainERC20[tokenAddr] = true;
                    brainERC20List.push(tokenAddr);
                    brainERC20Index[tokenAddr] = brainERC20List.length - 1;
                    validTokensFound++;
                    emit BrainTokenValidated(tokenAddr, tokenId);
                }
            }
            processedId = tokenId + 1;
            unchecked { ++tokenId; }
            if (gasleft() < initialGas / 4) {
                break;
            }
        }
        lastCheckedTokenId = processedId;
        emit BrainTokensBatchProcessed(startId, processedId - 1, validTokensFound);
    }

    /// @notice Rechecks previously empty tokens to see if they now have addresses
    /// @param startId First token ID to check
    /// @param count Number of consecutive IDs to check
    /// @return activated Number of newly activated tokens found
    /// @dev Only processes token IDs that were previously marked as empty
    function recheckEmptyTokens(uint256 startId, uint256 count)
        external
        onlyAdminOrOwner
        returns (uint256 activated)
    {
        if (count > MAX_BATCH_SIZE)
            revert BatchSizeTooLarge(count, MAX_BATCH_SIZE);
        uint256 initialGas = gasleft();
        activated = 0;
        for (uint256 i = 0; i < count && gasleft() > initialGas / 4; ) {
            uint256 tokenId = startId + i;
            if (emptyProcessedBitmap.get(tokenId)) {
                address tokenAddr = basedBrainsContract.getBrainERC20Address(
                    tokenId
                );
                if (
                    tokenAddr != address(0) &&
                    !isBrainERC20[tokenAddr] &&
                    _isValidERC20(tokenAddr)
                ) {
                    isBrainERC20[tokenAddr] = true;
                    brainERC20List.push(tokenAddr);
                    brainERC20Index[tokenAddr] = brainERC20List.length - 1;
                    emptyProcessedBitmap.unset(tokenId);

                    activated++;
                    emit BrainTokenValidated(tokenAddr, tokenId);
                }
            }
            unchecked {
                ++i;
            }
        }
        emit EmptyTokensRechecked(startId, count, activated);
        return activated;
    }

    /// @notice Allows anyone to submit a newly activated token for validation
    /// @param tokenId ID of a token that may have been empty but is now activated
    /// @return success Whether the token was successfully activated
    /// @dev Creates an incentive for users to help maintain token registry
    function submitActivatedB_ERC20(uint256 tokenId)
        external returns (bool success)
    {
        if ( !processedBitmap.get(tokenId) || !emptyProcessedBitmap.get(tokenId)
        ) { return false;
        } address tokenAddr = basedBrainsContract.getBrainERC20Address(tokenId);
        if (tokenAddr == address(0) || !_isValidERC20(tokenAddr) ||
            isBrainERC20[tokenAddr]
        ) { return false;
        }
        isBrainERC20[tokenAddr] = true;
        brainERC20List.push(tokenAddr);
        brainERC20Index[tokenAddr] = brainERC20List.length - 1;

        emptyProcessedBitmap.unset(tokenId);
        emit BrainTokenValidated(tokenAddr, tokenId);
        emit UserActivatedToken(msg.sender, tokenId, tokenAddr);

        return true;
    }

    /// @notice Performs multiple static calls to the contract itself, reverting if any subcall reverts.
    /// @param data The array of encoded function calls.
    /// @return results The array of results from each subcall.
    function multicall(bytes[] calldata data)
        external
        view
        returns (bytes[] memory results)
    {
        /// @solidity memory-safe-assembly
        assembly {
            let len := data.length
            results := mload(0x40) //// allocate results array
            mstore(results, len)
            let offsets := add(results, 0x20)
            let memPtr := add(offsets, shl(5, len))
            for {
                let i := 0
            } lt(i, len) {
                i := add(i, 1)
            } {
                let dataOffset := calldataload(add(data.offset, shl(5, i)))
                let callLen := calldataload(dataOffset)
                let callPtr := add(dataOffset, 0x20)
                let success := staticcall(
                    gas(),
                    address(),
                    callPtr,
                    callLen,
                    0,
                    0
                )
                let retSize := returndatasize()
                if iszero(success) {
                    returndatacopy(0, 0, retSize)
                    revert(0, retSize)
                }
                mstore(add(offsets, shl(5, i)), sub(memPtr, add(results, 0x20)))
                mstore(memPtr, retSize)
                returndatacopy(add(memPtr, 0x20), 0, retSize)

                memPtr := and(add(add(memPtr, retSize), 0x3f), not(0x1f)) //// align to 32 bytes
            }
            mstore(0x40, memPtr) //// update free memory pointer
            return(results, sub(memPtr, results))
        }
    }

    /*⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⁂⚒️⁂⁂
    ⚒️⁂⁂          CORE ESCROW LOGIC            ⚒️⁂⁂
    ⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️*/

    /// @notice Creates a new swap by depositing `tokenA`.
    /// @dev :
    ///      1️⃣ Validate input tokens and amounts.
    ///      2️⃣ Ensure expiration is within limits.
    ///      3️⃣ Track swap details in optimized storage.
    ///      └─ 📦 Uses packed storage
    /// @param tokenA Token address offered by swap creator.
    /// @param amountA Amount of `tokenA` offered.
    /// @param tokenB Requested token address in return.
    /// @param amountB Required amount of `tokenB`.
    /// @param expiration Swap expiration timestamp
    /// @return swapId Unique identifier of the created swap.
    function createSwap(
        address tokenA,
        uint256 amountA,
        address tokenB,
        uint256 amountB,
        uint64 expiration
    )
        external
        nonReentrant
        whenNotPaused
        whenOperational
        returns (uint256 swapId)
    {
        if (tokenA == address(0) || tokenB == address(0)) revert ZeroAddress();
        if (tokenA == tokenB) revert SameTokenSwap();
        if (amountA == 0 || amountB == 0) revert AmountZero();
        if (blacklistedTokens[tokenA] || blacklistedTokens[tokenB])
            revert BlacklistedToken();
        if (!(isBrainERC20[tokenA] || isSpecialToken[tokenA]))
            revert TokenNotValidated(tokenA);
        if (!(isBrainERC20[tokenB] || isSpecialToken[tokenB]))
            revert TokenNotValidated(tokenB);
        if (isBrainERC20[tokenA] && amountA < brainTokenMinimumAmount)
            revert BrainTokenAmountTooLow(
                tokenA,
                amountA,
                brainTokenMinimumAmount
            );
        if (isBrainERC20[tokenB] && amountB < brainTokenMinimumAmount)
            revert BrainTokenAmountTooLow(
                tokenB,
                amountB,
                brainTokenMinimumAmount
            );
        if (expiration <= block.timestamp) revert ExpirationInPast();
        if (expiration > block.timestamp + maxExpiryLimit)
            revert ExpiryTooFar(block.timestamp + maxExpiryLimit);
        if (openSwapCount[msg.sender] >= maxOpenSwaps)
            revert TooManyOpenSwaps(msg.sender, openSwapCount[msg.sender]);

        swapId = ++swapCounter;
        swaps[swapId] = Swap(
            msg.sender,
            expiration,
            0,
            tokenA,
            tokenB,
            address(0),
            amountA,
            amountB
        );
        _addUserSwap(msg.sender, swapId);
        SafeTransferLib.safeTransferFrom(
            tokenA,
            msg.sender,
            address(this),
            amountA
        );

        emit SwapCreated(
            swapId,
            msg.sender,
            tokenA,
            amountA,
            tokenB,
            amountB,
            expiration
        );
    }

    /// @notice 🤝 Accepts a swap by depositing tokenB and receiving tokenA.
    /// @dev Follows checks-effects-interactions pattern and updates state before transfers.
    ///      Fees are only applied to special tokens, not to brain tokens.
    /// @param _swapId The unique swap ID to accept.
    function acceptSwap(uint256 _swapId)
        external
        nonReentrant
        whenNotPaused
        whenOperational
        validSwapId(_swapId)
    {
        Swap storage s = swaps[_swapId];
        uint8 status;
        if ((s.flags & FLAG_FILLED) != 0) status = 1;
        else if ((s.flags & FLAG_CANCELED) != 0) status = 2;
        else if (block.timestamp > s.expiration) status = 3;
        else if (msg.sender == s.initiator) status = 4;
        if (status != 0) {
            if (status == 1) revert SwapAlreadyFilled();
            else if (status == 2) revert SwapAlreadyCanceled();
            else if (status == 3) revert SwapExpired();
            else revert InitiatorCannotAccept();
        }
        s.flags |= FLAG_FILLED;
        s.counterparty = msg.sender;
        _removeUserSwap(s.initiator, _swapId);
        uint256 tokenAFeeAmount = _calculateFee(s.tokenA, s.amountA);
        uint256 tokenBFeeAmount = _calculateFee(s.tokenB, s.amountB);
        SafeTransferLib.safeTransferFrom(
            s.tokenB,
            msg.sender,
            address(this),
            s.amountB
        );
        if (tokenAFeeAmount > 0 && treasury != address(0)) {
            SafeTransferLib.safeTransfer(s.tokenA, treasury, tokenAFeeAmount);
            SafeTransferLib.safeTransfer(
                s.tokenA,
                msg.sender,
                s.amountA - tokenAFeeAmount
            );
            emit FeesCollected(s.tokenA, tokenAFeeAmount, _swapId);
        } else {
            SafeTransferLib.safeTransfer(s.tokenA, msg.sender, s.amountA);
        }
        if (tokenBFeeAmount > 0 && treasury != address(0)) {
            SafeTransferLib.safeTransfer(s.tokenB, treasury, tokenBFeeAmount);
            SafeTransferLib.safeTransfer(
                s.tokenB,
                s.initiator,
                s.amountB - tokenBFeeAmount
            );
            emit FeesCollected(s.tokenB, tokenBFeeAmount, _swapId);
        } else {
            SafeTransferLib.safeTransfer(s.tokenB, s.initiator, s.amountB);
        }
        emit SwapAccepted(_swapId, msg.sender);
    }

    /// @notice ❌ Cancel open swap to retrieve deposited tokens.
    /// @dev :
    ///      1️⃣ Ensure caller is swap initiator and swap is active.
    ///      2️⃣ Mark swap as canceled and update state.
    ///      3️⃣ Refund deposited tokens to initiator.
    /// @param _swapId ID of swap to cancel.
    function cancelSwap(uint256 _swapId)
        external
        nonReentrant
        validSwapId(_swapId)
    {
        Swap storage s = swaps[_swapId];
        if ((s.flags & FLAG_FILLED) != 0) revert SwapAlreadyFilled();
        if ((s.flags & FLAG_CANCELED) != 0) revert SwapAlreadyCanceled();
        if (msg.sender != s.initiator) revert NotInitiator();
        s.flags |= FLAG_CANCELED;
        _removeUserSwap(s.initiator, _swapId);

        SafeTransferLib.safeTransfer(s.tokenA, s.initiator, s.amountA);
        emit SwapCanceled(_swapId, msg.sender);
    }

    /*⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂
    ⚒️⁂⁂              VIEWS && INTERNAL            ⚒️⁂⁂
    ⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⁷*/

    /// @notice Returns the IDs of all currently active swaps in a single pass.
    /// @dev Uses a single loop and assembly to shrink the array size after counting.
    function getActiveSwaps() external view returns (uint256[] memory) {
        uint256[] memory temp = new uint256[](swapCounter);
        uint256 currentTime = block.timestamp;
        uint256 count;
        for (uint256 i = 1; i <= swapCounter; ) {
            Swap storage s = swaps[i];
            bool isActive;
            /// @solidity memory-safe-assembly
            assembly {
                // Slot 0 of the Swap is s.slot
                let data := sload(s.slot)
                // The flags are the topmost byte of that 256-bit word
                let flags := and(shr(248, data), 0xFF)
                // The expiration is the next 64 bits below that
                let expiration := and(shr(192, data), 0xFFFFFFFFFFFFFFFF)
                isActive := and(
                    eq(and(flags, 3), 0),
                    gt(expiration, currentTime)
                )
            }
            if (isActive) {
                temp[count++] = i;
            }
            unchecked {
                ++i;
            }
        }
        assembly {
            mstore(temp, count)
        }
        return temp;
    }

    /// @notice Validates internal consistency of a user's open swaps.
    /// @param user The address to validate
    /// @return isValid True if user swap state is consistent, false otherwise
    function validateUserState(address user)
        external
        view
        onlyAdminOrOwner
        returns (bool isValid)
    {
        uint256[] storage userSwapsData = userOpenSwaps[user];
        uint8 count = openSwapCount[user];
        if (count != userSwapsData.length) return false;
        for (uint256 i = 0; i < userSwapsData.length; i++) {
            uint256 sId = userSwapsData[i];
            if (swapToUserIndex[user][sId] != i) return false;
            Swap storage s = swaps[sId];
            if (s.initiator != user) return false;
            if ((s.flags & (FLAG_FILLED | FLAG_CANCELED)) != 0) return false;
            if (s.expiration <= block.timestamp) return false;
        }
        return true;
    }

    /// @notice Get all open swap IDs for a specific user
    /// @param user The user address to query
    /// @return swapIds Array of open swap IDs for the user
    function getUserOpenSwaps(address user)
        external
        view
        returns (uint256[] memory swapIds)
    {
        uint256 length = openSwapCount[user];
        if (length == 0) {
            return new uint256[](0);
        }
        //// all valid open swaps
        swapIds = new uint256[](length);
        uint256[] storage userSwaps = userOpenSwaps[user];
        for (uint256 i = 0; i < length; ) {
            swapIds[i] = userSwaps[i];
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Returns the details for an array of swap IDs.
    /// @param ids An array of swap IDs.
    /// @return swapsOut An array of Swap structs.
    function getSwapDetails(uint256[] calldata ids)
        external
        view
        returns (Swap[] memory swapsOut)
    {
        if (ids.length > MAX_BATCH_SIZE)
            revert BatchSizeTooLarge(ids.length, MAX_BATCH_SIZE);
        swapsOut = new Swap[](ids.length);
        for (uint256 i = 0; i < ids.length; ) {
            if (ids[i] == 0 || ids[i] > swapCounter) {
                ////invalid IDs
                unchecked {
                    ++i;
                }
                continue;
            }
            swapsOut[i] = swaps[ids[i]];
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Get detailed information about a single swap
    /// @param swapId The ID of the swap to query
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
        )
    {
        if (swapId == 0 || swapId > swapCounter) revert NoSwapAvailable();
        Swap storage s = swaps[swapId];
        initiator = s.initiator;
        tokenA = s.tokenA;
        amountA = s.amountA;
        tokenB = s.tokenB;
        amountB = s.amountB;
        expiration = s.expiration;
        isFilled = (s.flags & FLAG_FILLED) != 0;
        isCanceled = (s.flags & FLAG_CANCELED) != 0;
        counterparty = s.counterparty;
    }

    /// @notice Get all swaps (including filled/canceled) for a user
    /// @param user Address to query
    /// @param includeCreated Include swaps created by user
    /// @param includeAccepted Include swaps accepted by user
    /// @return createdSwaps Swaps created by user
    /// @return acceptedSwaps Swaps accepted by user
    function getUserHistory(
        address user,
        bool includeCreated,
        bool includeAccepted
    )
        external
        view
        returns (uint256[] memory createdSwaps, uint256[] memory acceptedSwaps)
    {
        uint256 createdCount = 0;
        uint256 acceptedCount = 0;

        if (includeCreated) {
            for (uint256 i = 1; i <= swapCounter; i++) {
                if (swaps[i].initiator == user) {
                    createdCount++;
                }
            }
        }
        if (includeAccepted) {
            for (uint256 i = 1; i <= swapCounter; i++) {
                if (
                    (swaps[i].flags & FLAG_FILLED) != 0 &&
                    swaps[i].counterparty == user
                ) {
                    acceptedCount++;
                }
            }
        }
        createdSwaps = new uint256[](createdCount);
        acceptedSwaps = new uint256[](acceptedCount);
        if (includeCreated) {
            uint256 index = 0;
            for (uint256 i = 1; i <= swapCounter; i++) {
                if (swaps[i].initiator == user) {
                    createdSwaps[index++] = i;
                }
            }
        }
        if (includeAccepted) {
            uint256 index = 0;
            for (uint256 i = 1; i <= swapCounter; i++) {
                if (
                    (swaps[i].flags & FLAG_FILLED) != 0 &&
                    swaps[i].counterparty == user
                ) {
                    acceptedSwaps[index++] = i;
                }
            }
        }
    }

    /// @notice Get swaps by status
    /// @param statusFlags Bitmap of statuses: 1=active, 2=filled, 4=canceled, 8=expired
    /// @param maxResults Maximum number of results to return (0 for no limit)
    /// @return swapIds Array of matching swap IDs
    function getSwapsByStatus(uint8 statusFlags, uint256 maxResults)
        external
        view
        returns (uint256[] memory swapIds)
    {
        uint256 resultCount = 0;
        uint256 currentTime = block.timestamp;
        for (uint256 i = 1; i <= swapCounter; i++) {
            Swap storage s = swaps[i];
            bool isActive = (s.flags & (FLAG_FILLED | FLAG_CANCELED)) == 0 &&
                s.expiration > currentTime;
            bool isFilled = (s.flags & FLAG_FILLED) != 0;
            bool isCanceled = (s.flags & FLAG_CANCELED) != 0;
            bool isExpired = (s.flags & (FLAG_FILLED | FLAG_CANCELED)) == 0 &&
                s.expiration <= currentTime;
            bool matches = ((statusFlags & 1) != 0 && isActive) ||
                ((statusFlags & 2) != 0 && isFilled) ||
                ((statusFlags & 4) != 0 && isCanceled) ||
                ((statusFlags & 8) != 0 && isExpired);

            if (matches) {
                resultCount++;
                if (maxResults > 0 && resultCount >= maxResults) break;
            }
        }
        if (maxResults > 0 && resultCount > maxResults) {
            resultCount = maxResults;
        }
        swapIds = new uint256[](resultCount);
        uint256 index = 0;
        for (uint256 i = 1; i <= swapCounter && index < resultCount; i++) {
            Swap storage s = swaps[i];
            bool isActive = (s.flags & (FLAG_FILLED | FLAG_CANCELED)) == 0 &&
                s.expiration > currentTime;
            bool isFilled = (s.flags & FLAG_FILLED) != 0;
            bool isCanceled = (s.flags & FLAG_CANCELED) != 0;
            bool isExpired = (s.flags & (FLAG_FILLED | FLAG_CANCELED)) == 0 &&
                s.expiration <= currentTime;
            bool matches = ((statusFlags & 1) != 0 && isActive) ||
                ((statusFlags & 2) != 0 && isFilled) ||
                ((statusFlags & 4) != 0 && isCanceled) ||
                ((statusFlags & 8) != 0 && isExpired);

            if (matches) {
                swapIds[index++] = i;
            }
        }
    }

    /// @notice Get the fee that would be applied to a specific token amount
    /// @param token The token address
    /// @param amount The amount to calculate fee on
    /// @return feeAmount The fee amount that would be deducted
    /// @return netAmount The net amount after fee deduction
    function getApplicableFee(address token, uint256 amount)
        external
        view
        returns (uint256 feeAmount, uint256 netAmount)
    {
        feeAmount = _calculateFee(token, amount);
        netAmount = amount - feeAmount;
    }

    /// @notice Calculate the fee amount for a token in a swap
    /// @param token The token to check
    /// @param amount The amount to calculate fee on
    /// @return feeAmount The calculated fee amount
    function _calculateFee(address token, uint256 amount)
        internal
        view
        returns (uint256 feeAmount)
    {
        if (isBrainERC20[token] || feeRateBps == 0 || treasury == address(0)) {
            return 0;
        }
        if (isSpecialToken[token]) {
            feeAmount = FixedPointMathLib.mulDiv(amount, feeRateBps, 10000);
        }
        return feeAmount;
    }

    /// @notice Gets token metadata for a given token address
    /// @param token The token address to query
    /// @return data Token metadata
    function _getTokenData(address token)
        internal
        view
        returns (TokenData memory data)
    {
        data.isBrain = isBrainERC20[token];
        data.isSpecial = isSpecialToken[token];
    }

    /// @notice Validates brain tokens by specific token IDs
    /// @param tokenIds Array of token IDs to validate
    /// @return validFound Number of valid tokens found and added
    /// @dev Allows targeted validation of specific tokens
    function addBrainERC20ByIDs(uint256[] calldata tokenIds)
        external
        onlyAdminOrOwner
        returns (uint256 validFound)
    {
        if (tokenIds.length > MAX_BATCH_SIZE)
            revert BatchSizeTooLarge(tokenIds.length, MAX_BATCH_SIZE);
        validFound = 0;
        uint256 initialGas = gasleft();
        for (
            uint256 i = 0;
            i < tokenIds.length && gasleft() > initialGas / 4;

        ) {
            uint256 tokenId = tokenIds[i];
            address tokenAddr = basedBrainsContract.getBrainERC20Address(
                tokenId
            );
            _processTokenId(tokenId, tokenAddr);
            if (
                tokenAddr != address(0) &&
                !isBrainERC20[tokenAddr] &&
                _isValidERC20(tokenAddr)
            ) {
                isBrainERC20[tokenAddr] = true; ////add to validated list
                brainERC20List.push(tokenAddr);
                brainERC20Index[tokenAddr] = brainERC20List.length - 1;
                validFound++;
                emit BrainTokenValidated(tokenAddr, tokenId);
            }
            unchecked {
                ++i;
            }
        }
        emit BatchTokenIDsProcessed(tokenIds.length, validFound);
        return validFound;
    }

    /// @notice Removes a validated brain ERC20 token. Only admin/owner may call.
    /// @param token The token address to remove.
    function removeBrainERC20(address token) external onlyAdminOrOwner {
        if (!isBrainERC20[token]) return;
        isBrainERC20[token] = false;
        uint256 index = brainERC20Index[token];
        uint256 lastIndex = brainERC20List.length - 1;
        if (index != lastIndex) {
            address lastToken = brainERC20List[lastIndex];
            brainERC20List[index] = lastToken;
            brainERC20Index[lastToken] = index;
        }
        brainERC20List.pop();
        delete brainERC20Index[token];
        emit BrainTokenRemoved(token);
    }

    /// @notice Returns all active special tokens.
    function getSpecialTokens() external view returns (address[] memory) {
        return specialTokenList;
    }

    /// @notice Returns all validated brain ERC20 tokens.
    /// @return An array of validated token addresses.
    function getAllBrainERC20s() external view returns (address[] memory) {
        return brainERC20List;
    }

    /// @notice Checks if the given address appears to be a valid ERC20 token
    /// @param token The token address to check
    /// @return True if the token passes basic ERC20 validation checks
    function _isValidERC20(address token) internal view returns (bool) {
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(token)
        }
        return codeSize >= MIN_BYTECODE_SIZE;
    }

    /// @notice Returns a SwapMarketLib-compatible view of a given swap.
    /// @param swapId The ID of the swap to retrieve.
    /// @return sView A struct containing the swap's basic fields.
    function _getSwapForLib(uint256 swapId)
        internal
        view
        returns (Swap memory sView)
    {
        if (swapId == 0 || swapId > swapCounter) {
            return
                Swap({
                    initiator: address(0),
                    expiration: 0,
                    flags: 0,
                    tokenA: address(0),
                    tokenB: address(0),
                    counterparty: address(0),
                    amountA: 0,
                    amountB: 0
                });
        }
        return swaps[swapId];
    }

    /// @notice Adds a swap ID to a user's open swaps tracking.
    /// @dev Updates multiple state mappings to maintain swap-to-user indices.
    ///      Increments the user's open swap counter.
    /// @param user The address of the user (swap initiator)
    /// @param swapId The swap ID to add to the user's open swaps
    function _addUserSwap(address user, uint256 swapId) internal {
        userOpenSwaps[user].push(swapId);
        uint256 index = userOpenSwaps[user].length - 1;
        swapToUserIndex[user][swapId] = index;
        unchecked {
            openSwapCount[user] += 1;
        }
    }

    /// @notice Removes a swap ID from a user's open swaps tracking.
    /// @dev Uses the swap-to-index mapping to efficiently remove from the array.
    ///      Moves the last element to the removed position if not the last element.
    ///      Updates all relevant mappings and counters.
    /// @param user The address of the user (swap initiator)
    /// @param swapId The swap ID to remove from the user's open swaps
    function _removeUserSwap(address user, uint256 swapId) internal {
        uint256 swapIndex = swapToUserIndex[user][swapId];
        uint256 lastIndex = userOpenSwaps[user].length - 1;
        if (swapIndex != lastIndex) {
            //// Move last element to deleted position
            uint256 lastSwapId = userOpenSwaps[user][lastIndex];
            userOpenSwaps[user][swapIndex] = lastSwapId;
            swapToUserIndex[user][lastSwapId] = swapIndex;
        }
        userOpenSwaps[user].pop();
        delete swapToUserIndex[user][swapId];
        if (openSwapCount[user] > 0) {
            unchecked {
                openSwapCount[user] -= 1;
            }
        }
    }

    /// @notice Returns complete data for all of a user's open swaps in one call
    /// @param user The user address to query
    /// @return userSwaps An array of swap details for the user's open swaps
    function getUserSwapsWithDetails(address user)
        external
        view
        returns (SwapInfo[] memory userSwaps)
    {
        uint256[] memory swapIds = this.getUserOpenSwaps(user);
        userSwaps = new SwapInfo[](swapIds.length);
        for (uint256 i = 0; i < swapIds.length; ) {
            uint256 swapId = swapIds[i];
            Swap storage s = swaps[swapId];
            TokenData memory tokenAData = _getTokenData(s.tokenA);
            TokenData memory tokenBData = _getTokenData(s.tokenB);
            uint256 tokenAFee = _calculateFee(s.tokenA, s.amountA);
            uint256 tokenBFee = _calculateFee(s.tokenB, s.amountB);

            userSwaps[i] = SwapInfo({
                swapId: swapId,
                initiator: s.initiator,
                tokenA: s.tokenA,
                tokenAData: tokenAData,
                amountA: s.amountA,
                tokenAFee: tokenAFee,
                tokenAAfterFee: s.amountA - tokenAFee,
                tokenB: s.tokenB,
                tokenBData: tokenBData,
                amountB: s.amountB,
                tokenBFee: tokenBFee,
                tokenBAfterFee: s.amountB - tokenBFee,
                expiration: s.expiration,
                isExpired: block.timestamp > s.expiration,
                isFilled: (s.flags & FLAG_FILLED) != 0,
                isCanceled: (s.flags & FLAG_CANCELED) != 0,
                counterparty: s.counterparty,
                remainingTime: s.expiration > block.timestamp
                    ? s.expiration - uint64(block.timestamp)
                    : 0
            });

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Retrieves all swap IDs involving a specific token.
    /// @param token The token address to query swaps for
    /// @param onlyActive If true, only return active (not filled, canceled, or expired) swaps
    /// @param maxResults Maximum number of swap IDs to return (0 for no limit)
    /// @return swapIds Array of matching swap IDs
    function getSwapsByToken(
        address token,
        bool onlyActive,
        uint256 maxResults
    ) external view returns (uint256[] memory swapIds) {
        if (token == address(0)) revert ZeroAddress();
        if (maxResults > MAX_BATCH_SIZE) revert("toolarge");
        swapIds = new uint256[](maxResults);
        uint256 currentTime = block.timestamp;
        uint256 resultCount = 0;
        for (uint256 i = 1; i <= swapCounter; i++) {
            if (maxResults != 0 && resultCount >= maxResults) break;
            Swap memory s = _getSwapForLib(i);
            bool tokenMatches = (s.tokenA == token || s.tokenB == token);
            if (!tokenMatches) continue;

            if (onlyActive) {
                bool isActive = ((s.flags & (FLAG_FILLED | FLAG_CANCELED)) ==
                    0) && (s.expiration > currentTime);
                if (!isActive) continue;
            }

            swapIds[resultCount] = i;
            resultCount++;
        }
        assembly {
            mstore(swapIds, resultCount)
        }
        return swapIds;
    }

    /// @notice Retrieves market data statistics for a specific token.
    /// @param token The token address to query market data for.
    /// @return buyCount The number of active buy orders for this token.
    /// @return sellCount The number of active sell orders for this token.
    /// @return lowestSell The lowest price offered in sell orders (scaled by 1e18).
    /// @return highestBuy The highest price offered in buy orders (scaled by 1e18).
    /// @return totalVolume The total token volume across all relevant swaps.
    function getTokenMarketData(address token)
        external
        view
        returns (
            uint256 buyCount,
            uint256 sellCount,
            uint256 lowestSell,
            uint256 highestBuy,
            uint256 totalVolume
        )
    {
        if (token == address(0)) revert("zero");
        lowestSell = type(uint256).max;
        uint256 currentTime = block.timestamp;
        for (uint256 i = 1; i <= swapCounter; i++) {
            Swap memory s = _getSwapForLib(i);
            bool isActive = ((s.flags & (FLAG_FILLED | FLAG_CANCELED)) == 0) &&
                (s.expiration > currentTime);
            if (!isActive) continue;
            if (s.tokenA == token) {
                sellCount++;
                totalVolume += s.amountA;
                if (s.amountA > 0) {
                    uint256 price = (s.amountB * 1e18) / s.amountA;
                    if (price < lowestSell) {
                        lowestSell = price;
                    }
                }
            }
            if (s.tokenB == token) {
                buyCount++;
                totalVolume += s.amountB;
                if (s.amountB > 0) {
                    uint256 price = (s.amountA * 1e18) / s.amountB;
                    if (price > highestBuy) {
                        highestBuy = price;
                    }
                }
            }
        }
        if (lowestSell == type(uint256).max) {
            lowestSell = 0;
        }
    }

    /*⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂
    ⚒️⁂⁂               CONFIG && +                 ⚒️⁂⁂
    ⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⁷*/

    /// @notice Administrative function to clean up old, completed swaps to free storage.
    /// @dev Only owner or admin can call this function.
    ///      Only clears swaps that are filled or canceled AND older than the retention period.
    ///      Completely removes the swap data from storage for gas refunds.
    /// @param swapIds Array of swap IDs to clear
    function cleanExpired(uint256[] calldata swapIds)
        external
        onlyAdminOrOwner
    {
        uint256 cleared = 0;
        uint256 currentTime = block.timestamp;
        uint256 minRetentionPeriod = 800085 seconds; //// 9.260243 days
        for (uint256 i = 0; i < swapIds.length; i++) {
            uint256 swapId = swapIds[i];
            if (swapId == 0 || swapId > swapCounter) continue;
            Swap storage s = swaps[swapId];
            if (
                (s.flags & (FLAG_FILLED | FLAG_CANCELED)) == 0 ||
                s.expiration + minRetentionPeriod > currentTime
            ) {
                continue;
            }
            delete swaps[swapId];
            cleared++;
        }
        emit ExpiredSwapsCleared(cleared);
    }

    /// @notice Updates the address of the BasedBrains contract.
    /// @param newBasedBrains The new BasedBrains contract address.
    /// @dev Only callable by the owner.
    function updateBasedBrains(address newBasedBrains) external onlyOwner {
        if (newBasedBrains == address(0)) revert ZeroAddress();
        basedBrainsContract = IBasedBrains(newBasedBrains);
        emit BasedBrainsUpdated(newBasedBrains);
    }

    /// @notice Removes a token from the blacklist (allows trading).
    /// @param token The address of the token to remove from the blacklist.
    /// @dev Only callable by admin or owner.
    function unBlacklistToken(address token) external onlyAdminOrOwner {
        if (token == address(0)) revert ZeroAddress();
        blacklistedTokens[token] = false;
        emit BlacklistUpdated(token, false);
    }

    /// @notice Batch update blacklist status for multiple tokens
    /// @param tokens Array of token addresses
    /// @param blacklistStatuses Array of boolean flags (true = blacklisted)
    function updateBlacklist(
        address[] calldata tokens,
        bool[] calldata blacklistStatuses
    ) external onlyAdminOrOwner {
        if (tokens.length != blacklistStatuses.length)
            revert ArrayLengthMismatch();
        if (tokens.length > MAX_BATCH_SIZE)
            revert BatchSizeTooLarge(tokens.length, MAX_BATCH_SIZE);

        uint256 len = tokens.length;
        for (uint256 i = 0; i < len; ) {
            if (tokens[i] == address(0)) revert ZeroAddress();
            blacklistedTokens[tokens[i]] = blacklistStatuses[i];
            emit BlacklistUpdated(tokens[i], blacklistStatuses[i]);
            unchecked {
                ++i;
            }
        }

        emit BatchBlacklistUpdated(len);
    }

    /// @notice Updates the minimum token amount required for swaps involving brain tokens.
    /// @param amount The new minimum required amount, specified in token units.
    function setBrainTokenMinAmt(uint256 amount) external onlyAdminOrOwner {
        brainTokenMinimumAmount = amount;
    }

    /// @notice Activates or deactivates a special token.
    /// @param token The token address.
    /// @param active True to activate, false to deactivate.
    /// @dev Only callable by the owner.
    function setSpecialToken(address token, bool active) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (active && !_isValidERC20(token)) revert InvalidTokenStandard();
        isSpecialToken[token] = active;
        if (active) {
            if (
                specialTokenList.length == 0 ||
                specialTokenList[specialTokenIndex[token]] != token
            ) {
                specialTokenList.push(token);
                specialTokenIndex[token] = specialTokenList.length - 1;
            }
        } else {
            if (
                specialTokenList.length > 0 &&
                specialTokenList[specialTokenIndex[token]] == token
            ) {
                uint256 index = specialTokenIndex[token];
                uint256 lastIndex = specialTokenList.length - 1;
                if (index != lastIndex) {
                    address lastToken = specialTokenList[lastIndex];
                    specialTokenList[index] = lastToken;
                    specialTokenIndex[lastToken] = index;
                }
                specialTokenList.pop();
                delete specialTokenIndex[token];
            }
        }
        emit SpecialTokenUpdated(token, active);
    }

    /// @notice Allows the owner or admin to update the maximum number of open swaps allowed per address.
    /// @param newMax The new maximum number of open swaps.
    function setMaxOpenSwaps(uint8 newMax) external onlyAdminOrOwner {
        maxOpenSwaps = newMax;
        emit MaxOpenSwapsUpdated(newMax);
    }

    /// @notice Updates the maximum expiry limit (offset from block.timestamp) allowed for a swap.
    /// @param newLimit The new maximum expiry limit in seconds.
    function setMaxExpiryLimit(uint64 newLimit) external onlyAdminOrOwner {
        maxExpiryLimit = newLimit;
        emit ExpiryLimitUpdated(newLimit);
    }

    /// @notice Pauses or unpauses the contract functionality
    /// @param _paused True to pause, false to unpause
    function setPaused(bool _paused) external onlyAdminOrOwner {
        paused = _paused;
        emit PauseStatusChanged(_paused);
    }

    /// @notice Activates or deactivates shutdown
    /// @param _ems True to activate shutdown, false to deactivate
    function setEMSShutdown(bool _ems) external onlyAdminOrOwner {
        shutdownActive = _ems;
        emit EMSShutdownStatusChanged(_ems);
    }

    /// @notice Set the fee rate in basis points (1/100 of a percent)
    /// @param _feeRateBps New fee rate (50 = 0.5%)
    function setFeeRate(uint16 _feeRateBps) external onlyOwner {
        if (_feeRateBps > 500) revert FeeTooHigh();
        feeRateBps = _feeRateBps;
    }

    /// @notice Set the treasury address that receives fees
    /// @param _treasury New treasury address
    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ZeroAddress();
        treasury = _treasury;
    }

    /// @notice Allows the initiator to withdraw tokenA
    /// @param _swapId The unique swap ID.
    /// @dev Can only be called when   shutdown is active.
    function emsWithdraw(uint256 _swapId)
        external
        nonReentrant
        validSwapId(_swapId)
    {
        if (!shutdownActive) revert NotInEMSShutdown();
        Swap storage s = swaps[_swapId];
        if ((s.flags & FLAG_FILLED) != 0) revert SwapAlreadyFilled();
        if ((s.flags & FLAG_CANCELED) != 0) revert SwapAlreadyCanceled();
        if (msg.sender != s.initiator) revert NotInitiator();

        s.flags |= FLAG_CANCELED;
        _removeUserSwap(s.initiator, _swapId);
        SafeTransferLib.safeTransfer(s.tokenA, s.initiator, s.amountA);

        emit EMSWithdrawal(_swapId, s.initiator);
    }

    /// @notice Withdraws stuck ETH from the contract to a specified address.
    /// @param to The address to receive the withdrawn ETH.
    /// @param amount The amount of ETH (in wei) to withdraw.
    function plungeETH(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert(unicode"❌zero");
        (bool success, ) = to.call{value: amount}("");
        if (!success) revert(unicode"💀💀💀");
    }

    /// @notice Withdraws stuck ERC20 tokens from the contract to a specified address.
    /// @dev Disallows withdrawing tokens marked as brain or special.
    /// @param token The ERC20 token address to withdraw.
    /// @param to The address to receive the withdrawn tokens.
    /// @param amount The amount of tokens to withdraw.
    function plungeERC20(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner {
        if (to == address(0)) revert(unicode"❌zero");
        if (isBrainERC20[token] || isSpecialToken[token]) {
            revert(unicode"💀💀💀");
        }
        SafeTransferLib.safeTransfer(token, to, amount);
    }

    /*⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂
    ⚒️⁂⁂                  EVENTS                   ⚒️⁂⁂
    ⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⚒️⁂⁂⁷*/

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
    event EMSShutdownStatusChanged(bool status);
    event PauseStatusChanged(bool status);
    event EMSWithdrawal(uint256 indexed swapId, address indexed initiator);
    event BrainTokenValidated(address indexed token, uint256 indexed tokenId);
    event BrainTokenRemoved(address indexed token);
    event BasedBrainsUpdated(address indexed newBasedBrains);

    event BatchTokenIDsProcessed(uint256 processed, uint256 valid);
    event SpecialTokenUpdated(address indexed token, bool active);
    event BrainTokensBatchProcessed(
        uint256 startId,
        uint256 endId,
        uint256 validTokensFound
    );
    /// @notice Emitted when empty tokens are rechecked for activation
    /// @param startId First token ID that was checked
    /// @param count Number of token IDs checked
    /// @param activated Number of newly activated tokens found
    event EmptyTokensRechecked(
        uint256 startId,
        uint256 count,
        uint256 activated
    );

    /// @notice Emitted when a user successfully submits an activated token
    /// @param submitter Address of the user who submitted the token
    /// @param tokenId The token ID that was activated
    /// @param tokenAddr The token address that was validated
    event UserActivatedToken(
        address indexed submitter,
        uint256 tokenId,
        address tokenAddr
    );
    event MaxOpenSwapsUpdated(uint8 newMax);
    event BatchBlacklistUpdated(uint256 count);
    /// @notice Emitted whenever a token's blacklist status is updated.
    event BlacklistUpdated(address indexed token, bool blacklisted);
    event FeeRateUpdated(uint16 newFeeRateBps);
    event treasuryUpdated(address newtreasury);
    event FeesCollected(address token, uint256 feeAmount, uint256 swapId);
    event FeesWithdrawn(address token, uint256 amount, address recipient);
    event ExpiryLimitUpdated(uint64 newLimit);
    event ExpiredSwapsCleared(uint256 count);
    /// @notice Emitted when a new version is initialized
    /// @param version The version number that was initialized
    event UpgradeInitialized(uint256 version);

    receive() external payable {}
}

interface IBasedBrains {
    function tokenCounter() external view returns (uint256);

    function getBrainERC20Address(uint256 tokenId)
        external
        view
        returns (address);
}
