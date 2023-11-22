pragma solidity ^0.8.21;

import {BaseHook} from "periphery-next/BaseHook.sol";
import {ERC1155} from "openzeppelin-contracts/contracts/token/ERC1155/ERC1155.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol"; // PoolKeys are structs used to represent a unique pool 
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {ABDKMath64x64} from "abdk-libraries-solidity/ABDKMath64x64.sol";
import "hardhat/console.sol";





contract LimitOrderHook is BaseHook, ERC1155 {

    // Initialize BaseHook and ERC1155 parent contracts in the constructor 
    constructor(
        IPoolManager _poolManager, 
        string memory _uri
    ) BaseHook(_poolManager) ERC1155(_uri){}

    // Required override function for BaseHook to let the PoolManager know which hooks are implemented
    function getHooksCalls() public pure override returns (Hooks.Calls memory){
        return Hooks.Calls({
            beforeInitialize: false,
            afterInitialize: true,
            beforeModifyPosition: false,
            afterModifyPosition: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false
        });
    }

    // Use the PoolIdLibrary for PoolKey to add the `.toId()` function on a PoolKey
    // which hashes the PoolKey struct into a bytes32 value
    using PoolIdLibrary for PoolKey;

    using CurrencyLibrary for Currency;

    using FixedPointMathLib for uint256;

    // Create a mapping to store the last known tickLower value for a given Pool
    mapping(PoolId poolId => int24 tickLower) public tickLowerLasts;

    // Create a nested mapping to store the take-profit orders placed by users
    //Since a take-profit order is placed for a specific PoolId, at a specific tick, 
    //in a specific zeroForOne direction, for a certain amount of tokens
    // The mapping is PoolId => tickLower => zeroForOne => amount
    // PoolId => (...) specifies the ID of the pool the order is for
    // tickLower => (...) specifies the tickLower value of the order i.e. sell when price is greater than or equal to this tick
    // zeroForOne => (...) specifies whether the order is swapping Token 0 for Token 1 (true), or vice versa (false)
    // amount specifies the amount of the token being sold
    mapping(PoolId poolId => mapping(int24 tickLower => mapping(bool zeroForOne => int256 amount))) public takeProfitPositions;

    // ERC1155 state
    // tokenIdExists is a mapping to store whether a given tokenId (i.e. a take-profit order) exists given a token id
    mapping(uint256 tokenId => bool exists) public tokenIdExists;
    // tokenIdClaimable is a mapping that stores how many swapped tokens are claimable for a given tokenId
    mapping(uint256 tokenId => uint256 claimable) public tokenIdClaimable;
    // tokenIdTotalSupply is a mapping that stores how many tokens need to be sold to execute the take-profit order
    mapping(uint256 tokenId => uint256 supply) public tokenIdTotalSupply;
    // tokenIdData is a mapping that stores the PoolKey, tickLower, and zeroForOne values for a given tokenId
    mapping(uint256 tokenId => TokenData) public tokenIdData;

    struct TokenData {
        PoolKey poolKey;
        int24 tickLower;
        bool zeroForOne;
    } 

    //Utility Helpers
    function _setTickLowerLast(PoolId poolId, int24 tickLower) private {
        tickLowerLasts[poolId] = tickLower;        
    }

    // Utility func to do the same thing as Math.round() in JS
    function _divRound(int128 x, int128 y)
        internal
        pure
        returns (int128 result)
    {
        int128 quot = ABDKMath64x64.div(x, y);
        result = quot >> 64;

        // Check if remainder is greater than 0.5
        if (quot % 2**64 >= 0x8000000000000000) {
            result += 1;
        }
         return result;
    }

    function _getTickLower(int24 actualTick, int24 tickSpacing) internal pure returns (int24 result1, int24 result2) {
        // Option 1
        int24 intervals = actualTick / tickSpacing;
        if (actualTick < 0 && actualTick % tickSpacing != 0) {
            intervals--; // round towards negative infinity
        }
        result1 = intervals * tickSpacing;
        // Option 2
        result2 = _divRound(int128(actualTick), int128(int24(tickSpacing))) * tickSpacing;

        if (result2 < TickMath.MIN_TICK) {
            result2 += tickSpacing;
        } else if (result2 > TickMath.MAX_TICK) {
            result2 -= tickSpacing;
        }
        console.log("TickLower values from both approaches are %s and %s", result1, result2);
        return(result1, result2);
    }

//This function by itself is quite simply - it takes the arguments provided to us by Uniswap in the afterInitialize function, 
// calculates the tickLower value for the current tick, and sets it in the mapping.
// At the end, the hook MUST return the function selector - and this is true for all hooks - so we return that.
    function afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24 tick,
        // Add bytes calldata after tick
        bytes calldata
        // One thing to note: is the poolManagerOnly modifier, which is coming from the BaseHook contract 
        // which ensures this function is being called directly by Uniswap's Pool Manager - and not by some random user trying to exploit us.
    ) external override poolManagerOnly returns (bytes4) {
        (int24 tickLower,) = _getTickLower(tick, key.tickSpacing);
        _setTickLowerLast(key.toId(), tickLower);
        return TakeProfitsHook.afterInitialize.selector;
    }

// This function simply takes all of that information, uses abi.encodePacked to encode it all, hashes it, and then converts the hash to a uint256. 
// This token ID then uniquely identifies a specific order, 
// and when a user comes back to return these tokens back to us - we can figure out which order was theirs.
// TODO: question: what if 2 users have the exact same values for the following. Won't the IDs clash??
    function getTokenId(PoolKey calldata key, int24 tickLower, bool zeroForOne) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(key.id, tickLower, zeroForOne)));
    }

    function placeOrder(
        PoolKey calldata poolKey,
        int24 tick,
        bool zeroForOne,
        uint256 amountIn
    ) external returns (int24) {
        (int24 tickLower,) = _getTickLower(tick, poolKey.tickSpacing);
        // add order to the takeProfitPositions mapping
        takeProfitPositions[key.toId()][tickLower][zeroForOne] += int256(
        amountIn
    );
    uint256 tokenId = getTokenId(poolKey, tickLower, zeroForOne);

    // If token id doesn't already exist, add it to the mapping
    // Not every order creates a new token id, as it's possible for users to add more tokens to a pre-existing order
    if (!tokenIdExists[tokenId]) {
        tokenIdExists[tokenId] = true;
        tokenIdData[tokenId] = TokenData(key, tickLower, zeroForOne);
    }
    
    // Mint ERC1155 token as receipt for the order
    _mint(msg.sender, tokenId, amountIn, ""); // minting semi fungible tokens
    tokenIdTotalSupply[tokenId] += amountIn;
    
    // get address of the token the user wants to sell so we can transfer the tokens
    // to be sold from the user's wallet into the hook contract.
    // Uniswap v4 contains this information within the PoolKey but it is 
    // wrapped in an abstracted struct called Currency. To extract the address given the Currency, we need to use Currency.unwrap which we need to import from the v4 codebase.
    address tokenToBeSoldAddress = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);

    // transfer tokens to be sold from user wallet to hook contract address
    IERC20(tokenToBeSoldAddress).transferFrom(msg.sender, address(this), amountIn); // Note: document diff between transfer vs transferFrom
    return tickLower;
    }

    function cancelOrder(
        PoolKey calldata poolKey,
        int24 tick,
        bool zeroForOne
    ) external {
        (int24 tickLower,) = _getTickLower(tick, poolKey.tickSpacing);
        uint256 tokenId = getTokenId(poolKey, tickLower, zeroForOne);

        // Get the amount of token users ERC1155 tokens represent
        uint256 amountIn = balanceOf(msg.sender, tokenId);
        require(amountIn > 0, "No orders found to sell");

        _burn(msg.sender, tokenId, amountIn);
        takeProfitPositions[key.toId()][tickLower][zeroForOne] -= int256(amountIn);
        tokenIdTotalSupply[tokenId] -= amountIn;

        // extract address of the token user wanted to sell and move back to the user's wallet address
        address tokenToBeSold = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);

        // Option 1: With transferFrom, tokens can be sent on behalf of someone as long as the third aprty has approval
        // IERC20(tokenToBeSold).transferFrom(address(this), msg.sender, amountIn)

        // OR Option 2: With transfer, tokens can be sent directly from one address to another
        IERC20(tokenToBeSold).transfer(msg.sender, amountIn);

    }

    function _swapTokens(
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata params
    ) external returns (BalanceDelta) {

        // delta is the BalanceDelta struct that stores the delta balance changes
        // i.e. Change in Token 0 balance and change in Token 1 balance
        // Added empty string after parms in BalanceDelta
        BalanceDelta delta = poolManager.swap(key, params, "");

        // token 0 -> token 1
        if (params.zeroForOne){
            if (delta.amount0 > 0) {
                IERC20(Currency.unwrap(key.currency0)).transfer(
                    address(poolManager),
                    uint128(delta.amount0())                
                );
                poolManager.settle(key.currency0);
            }
            // if we are owed token 1, take it from uniswap pool
            // NOTE: This will be a negative value, as it is a negative balance change from the pool's perspective
            if (delta.amount1 <= 0){
                poolManager.take(
                    key.currency1,
                    address(this),
                    uint256 (-delta.amount1())
                );
            }
        } else { // token 1 -> token 0
        if (delta.amount1 > 0) {
            IERC20(Currency.unwrap(key.currency1)).transfer(
                    address(poolManager),
                    uint128(delta.amount1())                
                );
            poolManager.settle(key.currency1);
        }
        if (delta.amount0 <= 0){
                poolManager.take(
                    key.currency0,
                    address(this),
                    uint256 (-delta.amount0())
                );
            }
    }
    return delta;
    }

    function fulfillOrder (
        PoolKey calldata poolKey,
        int24 tick,
        bool zeroForOne,
        uint256 amountIn
    ) internal {
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountIn,
            // Set the price limit to be the least possible if swapping from Token 0 to Token 1
        // or the maximum possible if swapping from Token 1 to Token 0
        // i.e. infinite slippage allowed
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
        });
        BalanceDelta delta = abi.decode(poolManager.lock(abi.encodeCall(this._swapTokens, (key, swapParams))
        ),
        (BalanceDelta)
        );

        // Update mapping to reflect that `amountIn` worth of tokens have been swapped from this order
        takeProfitPositions[key.toId()][tick][zeroForOne] -= amountIn;

        uint256 tokenId = getTokenId(key, tick, zeroForOne);

        // Flip the sign of the delta as tokens we were owed by Uniswap are represented as a negative delta change
        uint256 amountOfTokensReceivedFromSwap = zeroForOne
            ? uint256(int256(-delta.amount1()))
            : uint256(int256(-delta.amount0()));

        // Update the amount of tokens claimable for this order
        tokenIdClaimable[tokenId] += amountOfTokensReceivedFromSwap;
    }

    function afterSwap(address, PoolKey calldata key, 
        IPoolManager.SwapParams calldata params, 
        BalanceDelta) 
        external override poolManagerOnly returns (bytes4) {
    
        int24 lastTickLower = tickLowerLasts[key.toId()];

        // Get the exact current tick and use it to calculate the currentTickLower
        (uint160 sqrtPriceX96, int24 currentTick, , , , ) = poolManager.getSlot0(key.toId());
        console.log("sqrtPriceX96 is %s", sqrtPriceX96);
        priceFromSqrtX96 = (sqrtPriceX96Pow / 2**96) ** 2;
        console.log("priceFromSqrtX96 is %s", priceFromSqrtX96);
        adjustedPriceFromSqrtX96 = priceFromSqrtX96 / 10**12;
        console.log("adjustedPriceFromSqrtX96 is %s", adjustedPriceFromSqrtX96);
        inversePriceFromSqrtX96 = 1 / adjustedPriceFromSqrtX96;
        console.log("inversePriceFromSqrtX96 is %s", inversePriceFromSqrtX96); 

        (int24 currentTickLower,) = _getTickLower(currentTick, key.tickSpacing);
        console.log("currentTickLower is %s", currentTickLower); 

        // We execute orders in the opposite direction
        // i.e. if someone does a zeroForOne swap to increase price of Token 1, we execute
        // all orders that are oneForZero
        // and vice versa
        bool swapOneForZero = !params.zeroForOne;
        bool swapZeroForOne = params.zeroForOne;
        int256 swapAmountIn;

        // if tick has increased then token 0 price has increased too
        if (lastTickLower < currentTickLower) {
            // Loop through all ticks and orders to see which ones are oneForZero so they can be fulfilled
            for (int24 tick = lastTickLower; lastTickLower < currentTickLower; ) {
                swapAmountIn = takeProfitPositions[key.toId()][tick][swapOneForZero];
                if (swapAmountIn > 0) {
                fulfillOrder(key, tick, swapOneForZero, swapAmountIn);
                }
            tick += key.tickSpacing;    
            }
        } else { // Else if tick has decreased (i.e. price of Token 1 has increased)
            for (int24 tick = lastTickLower; currentTickLower < lastTickLower; ) {
                swapAmountIn = takeProfitPositions[key.toId()][tick][swapZeroForOne];
                if (swapAmountIn > 0) {
                fulfillOrder(key, tick, swapZeroForOne, swapAmountIn);
                }
            tick -= key.tickSpacing;
            }
        }
        tickLowerLasts[key.Id()] = currentTickLower;
        return LimitOrderHook.afterSwap.selector;
    }

    function redeem(uint256 tokenId, uint256 amountIn, address destination) external {
        // Make sure there is something to claim
        require(tokenIdClaimable[tokenId] > 0, "TakeProfitsHook: No tokens to redeem");

        // Make sure user has enough ERC-1155 tokens to redeem the amount they're requesting
        uint256 balance = balanceOf(msg.sender, tokenId);
        require(balance >= amountIn, "TakeProfitsHook: Not enough ERC-1155 tokens to redeem requested amount");

        TokenData memory data = tokenIdData[tokenId];
        address tokenToSendContractAddress = data.zeroForOne ? Currency.unwrap(data.poolKey.currency1) : Currency.unwrap(data.poolKey.currency0);

        // multiple people could have added tokens to the same order, so we need to calculate the amount to send
        // total supply = total amount of tokens that were part of the order to be sold
        // therefore, user's share percentage = (amountIn / total supply)
        // therefore, amount to send to user = (user's share * total claimable)
        // Since this is Solidity, we should multiply before we divide to maintain some precision, so we rearrange to
        // amountToSend = amountIn * (total claimable / total supply)
        // We use FixedPointMathLib.mulDivDown to avoid rounding errors
        uint256 amountToSend = amountIn.mulDivDown(tokenIdClaimable[tokenId], tokenIdTotalSupply[tokenId]);

        tokenIdClaimable[tokenId] -= amountToSend;
        tokenIdTotalSupply[tokenId] -= amountIn;
        _burn(msg.sender, tokenId, amountIn);

        IERC20(tokenToSendContractAddress).transfer(destination, amountToSend);
    }
}

