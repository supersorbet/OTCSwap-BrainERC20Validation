// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";

library SwapMarketLib {
    /// @dev The provided token address is zero.
    error ZeroTokenAddress();
    /// @dev The provided batch size is too large.
    error BatchSizeTooLarge(uint256 provided, uint256 maximum);
    /// @dev Invalid token position parameter.
    error InvalidTokenPosition(uint8 provided);
    /// @dev Minimal struct interface for swap
    struct SwapView {
        address initiator;
        uint64 expiration;
        uint8 flags;
        address tokenA;
        address tokenB;
        address counterparty;
        uint256 amountA;
        uint256 amountB;
    }
    uint8 internal constant FLAG_FILLED = 1 << 0;
    uint8 internal constant FLAG_CANCELED = 1 << 1;
    uint256 internal constant MAX_BATCH_SIZE = 100;

    /// @notice Get market data for a specific token with extreme gas optimization
    /// @param swapCounter Total number of swaps
    /// @param getSwap Callback to get swap data
    /// @param token Token to analyze
    /// @return buyCount Swaps buying this token
    /// @return sellCount Swaps selling this token
    /// @return lowestSell Lowest sell price (1e18 precision)
    /// @return highestBuy Highest buy price (1e18 precision)
    /// @return totalVolume Total volume in token units
    function getTokenMarketData(
        uint256 swapCounter,
        function(uint256) internal view returns (SwapView memory) getSwap,
        address token
    )
        internal
        view
        returns (
            uint256 buyCount,
            uint256 sellCount,
            uint256 lowestSell,
            uint256 highestBuy,
            uint256 totalVolume
        )
    {
        if (token == address(0)) revert("zer0");
        lowestSell = type(uint256).max;
        uint256 currentTime = block.timestamp;
        for (uint256 i = 1; i <= swapCounter; ) {
            SwapView memory s = getSwap(i);
            bool isActive = (s.flags & (FLAG_FILLED | FLAG_CANCELED)) == 0 &&
                s.expiration > currentTime;
            if (isActive) {
                //// Selling tokenA
                if (s.tokenA == token) {
                    unchecked {
                        sellCount++;
                    }
                    if (s.amountA > 0) {
                        uint256 price;

                        /// @solidity memory-safe-assembly
                        assembly {
                            let amountA := mload(add(s, 0xE0)) //// s.amountA position
                            let amountB := mload(add(s, 0x100)) //// s.amountB position
                            if iszero(iszero(amountA)) {
                                //// if amountA != 0
                                let product := mul(amountB, 0xDE0B6B3A7640000) //// 1e18 in hex
                                price := div(product, amountA)
                                if lt(price, lowestSell) {
                                    lowestSell := price
                                }
                            }
                        }
                    }
                    unchecked {
                        totalVolume += s.amountA;
                    }
                }
                if (s.tokenB == token) {
                    unchecked {
                        buyCount++;
                    }
                    if (s.amountB > 0) {
                        //// Calc buy
                        uint256 price;

                        /// @solidity memory-safe-assembly
                        assembly {
                            //// price = (amountA * 1e18) / amountB, checking for division by zero
                            let amountA := mload(add(s, 0xE0)) //// s.amountA position
                            let amountB := mload(add(s, 0x100)) //// s.amountB position
                            if iszero(iszero(amountB)) {
                                //// if amountB != 0
                                //// Mul
                                let product := mul(amountA, 0xDE0B6B3A7640000) //// 1e18 in hex
                                price := div(product, amountB)
                                if gt(price, highestBuy) {
                                    highestBuy := price
                                }
                            }
                        }
                    }
                    unchecked {
                        totalVolume += s.amountB;
                    }
                }
            }
            unchecked {
                i++;
            }
        }
        if (lowestSell == type(uint256).max) {
            lowestSell = 0;
        }
        return (buyCount, sellCount, lowestSell, highestBuy, totalVolume);
    }

    /// @notice Get swaps involving a specific token with optimized implementation
    /// @param swapCounter Total number of swaps in the system
    /// @param getSwap Callback function to fetch swap data
    /// @param token The token address to search for
    /// @param onlyActive If true, only return active swaps
    /// @param maxResults Maximum number of results to return
    /// @return swapIds Array of matching swap IDs
    function getSwapsByToken(
        uint256 swapCounter,
        function(uint256) internal view returns (SwapView memory) getSwap,
        address token,
        bool onlyActive,
        uint256 maxResults
    ) internal view returns (uint256[] memory swapIds) {
        if (token == address(0)) revert ZeroTokenAddress();
        if (maxResults > MAX_BATCH_SIZE)
            revert BatchSizeTooLarge(maxResults, MAX_BATCH_SIZE);
        swapIds = new uint256[](maxResults);
        uint256 resultCount = 0;
        uint256 currentTime = block.timestamp;
        for (uint256 i = 1; i <= swapCounter && resultCount < maxResults; ) {
            SwapView memory s = getSwap(i);
            bool tokenMatches = (s.tokenA == token || s.tokenB == token);
            if (!tokenMatches) {
                unchecked {
                    i++;
                }
                continue;
            }
            if (onlyActive) {
                bool isActive = (s.flags & (FLAG_FILLED | FLAG_CANCELED)) ==
                    0 &&
                    s.expiration > currentTime;
                if (!isActive) {
                    unchecked {
                        i++;
                    }
                    continue;
                }
            }
            swapIds[resultCount] = i;
            unchecked {
                resultCount++;
                i++;
            }
        }
        assembly {
            mstore(swapIds, resultCount)
        }

        return swapIds;
    }

    /// @notice Advanced query for swaps by token with filters
    /// @param swapCounter Total swap count
    /// @param getSwap Callback to get swap data
    /// @param token Token address to search for
    /// @param minPrice Minimum price (scaled by 1e18)
    /// @param maxPrice Maximum price (scaled by 1e18)
    /// @param minAmount Minimum amount in token units
    /// @param tokenPosition 0=both sides, 1=tokenA, 2=tokenB
    /// @param maxResults Maximum results to return
    /// @return swapIds Array of matching swap IDs
    function getFilteredSwapsByToken(
        uint256 swapCounter,
        function(uint256) internal view returns (SwapView memory) getSwap,
        address token,
        uint256 minPrice,
        uint256 maxPrice,
        uint256 minAmount,
        uint8 tokenPosition,
        uint256 maxResults
    ) internal view returns (uint256[] memory swapIds) {
        if (token == address(0)) revert ZeroTokenAddress();
        if (tokenPosition > 2) revert InvalidTokenPosition(tokenPosition);
        if (maxResults > MAX_BATCH_SIZE)
            revert BatchSizeTooLarge(maxResults, MAX_BATCH_SIZE);

        swapIds = new uint256[](maxResults);
        uint256 resultCount = 0;
        uint256 currentTime = block.timestamp;
        for (uint256 i = 1; i <= swapCounter && resultCount < maxResults; ) {
            SwapView memory s = getSwap(i);
            bool isActive = (s.flags & (FLAG_FILLED | FLAG_CANCELED)) == 0 &&
                s.expiration > currentTime;

            if (!isActive) {
                unchecked {
                    i++;
                }
                continue;
            }
            bool isMatch = false;
            uint256 price = 0;
            uint256 amount = 0;

            if (tokenPosition <= 1 && s.tokenA == token) {
                isMatch = true;
                amount = s.amountA;
                //// Calc price if amts are valid
                if (s.amountA > 0 && s.amountB > 0) {
                    price = FixedPointMathLib.mulDiv(
                        s.amountB,
                        1e18,
                        s.amountA
                    );
                }
            } else if (tokenPosition == 0 || tokenPosition == 2) {
                if (s.tokenB == token) {
                    isMatch = true;
                    amount = s.amountB;
                    if (s.amountA > 0 && s.amountB > 0) {
                        price = FixedPointMathLib.mulDiv(
                            s.amountA,
                            1e18,
                            s.amountB
                        );
                    }
                }
            }
            if (isMatch) {
                //// price filter if min or max is set
                if (
                    (minPrice > 0 && price < minPrice) ||
                    (maxPrice > 0 && price > maxPrice)
                ) {
                    unchecked {
                        i++;
                    }
                    continue;
                }
                if (amount < minAmount) {
                    unchecked {
                        i++;
                    }
                    continue;
                }
                swapIds[resultCount] = i;
                unchecked {
                    resultCount++;
                }
            }
            unchecked {
                i++;
            }
        }
        assembly {
            mstore(swapIds, resultCount)
        }

        return swapIds;
    }
}
