// SPDX-License-Identifier: UNLICENSED
// Updated solidity
pragma solidity ^0.8.21;

// Foundry libraries
import "forge-std/Test.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";

// Test ERC-20 token implementation
import {TestERC20} from "v4-core/test/TestERC20.sol";

// Libraries
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

// Interfaces
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

// Pool Manager related contracts
import {PoolManager} from "v4-core/PoolManager.sol";
import {PoolModifyPositionTest} from "v4-core/test/PoolModifyPositionTest.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

// Our contracts
import {LimitOrderHook} from "../src/LimitOrderHook.sol";
import {LimitOrderStub} from "../src/LimitOrderStub.sol";

contract LimitOrderHookTest is Test, GasSnapshot {

    using PoolIdLibrary for PoolKey;

    using CurrencyLibrary for Currency;

    // Hardcode the address for our hook instead of deploying it
    // We will overwrite the storage to replace code at this address with code from the stub
    LimitOrderHook hook = LimitOrderHook(address(uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG)));

    // poolManager is the Uniswap v4 Pool Manager
    PoolManager poolManager;

    // modifyPositionRouter is the test-version of the contract that allows
    // liquidity providers to add/remove/update their liquidity positions
    PoolModifyPositionTest modifyPositionRouter;

    // swapRouter is the test-version of the contract that allows
    // users to execute swaps on Uniswap v4
    PoolSwapTest swapRouter;

    // token0 and token1 are the two tokens in the pool
    TestERC20 token0;
    TestERC20 token1;

    // poolKey and poolId are the pool key and pool id for the pool
    PoolKey poolKey;
    PoolId poolId;

    // SQRT_RATIO_1_1 is the Q notation for sqrtPriceX96 where price = 1
    // i.e. sqrt(1) * 2^96
    // This is used as the initial price for the pool
    // as we add equal amounts of token0 and token1 to the pool during setUp
    uint160 constant SQRT_RATIO_1_1 = 79228162514264337593543950336;

    // Helper function
    function _deployERC20Tokens() private {
        console.log("Deploy ERC20 token0 and token1 locally");
        TestERC20 tokenA = new TestERC20(1000);
        TestERC20 tokenB = new TestERC20(1000);

        // Token 0 and Token 1 are assigned in a pool based on
        // the address of the token
        if (address(tokenA) < address(tokenB)){
            token0 = tokenA;
            token1 = tokenB;
        } else {
            token0 = tokenB;
            token1 = tokenA;
        }
    }

    function _stubValidateHookAddress() private {
        // Deploy the stub contract
        LimitOrderStub stub = new LimitOrderStub(poolManager,hook);
        // Fetch all the storage slot writes that have been done at the stub address
        // during deployment
        (, bytes32[] memory writes) = vm.accesses(address(stub));

        // Etch the code of the stub at the hardcoded hook address
        vm.etch(address(hook), address(stub).code);

        // Replay the storage slot writes at the hook address
        unchecked {
            for (uint256 i = 0; i < writes.length; i++) {
                bytes32 slot = writes[i];
                vm.store(address(hook), slot, vm.load(address(stub), slot));
            }
        }
    }

    function _initializePool() private {
        console.log("Initializing Pool");
        // Deploy the test-versions of modifyPositionRouter and swapRouter
        modifyPositionRouter = new PoolModifyPositionTest(IPoolManager(address(poolManager)));
        swapRouter = new PoolSwapTest(IPoolManager(address(poolManager)));

        // specify poolkey and poolid for the pool
        // struct PoolKey {
            //Currency currency0;
            //Currency currency1;
            //uint24 fee;
            //int24 tickSpacing;
            //IHooks hooks;
       //}
        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hook)
            });

        poolId = poolKey.toId();

        // Initialize the new pool with initial price ratio = 1
        poolManager.initialize(poolKey, SQRT_RATIO_1_1, "");
        // console.log("Initializing a Pool with id:");
        // console.logBytes32(bytes(poolKey.toId()));

    }

    function _addLiquidityToPool() private {
        console.log("Adding liquidity to the Pool at various ticks for token0 and token1");
        // Mint a lot of tokens to ourselves
        token0.mint(address(this), 100 ether);
        console.log("token0 balance after minting ourselves some tokens", token0.balanceOf(address(this)) / 10** 18);
        token1.mint(address(this), 100 ether);
        console.log("token1 balance after minting ourselves some tokens", token1.balanceOf(address(this)) / 10**18);

        // Approve the modifyPositionRouter to spend your tokens
        token0.approve(address(modifyPositionRouter), 100 ether);
        token1.approve(address(modifyPositionRouter), 100 ether);

        // Add liquidity across different tick ranges
        // First, from -60 to +60
        // Then, from -120 to +120
        // Then, from minimum possible tick to maximum possible tick

        // Add liquidity from -60 to +60
        modifyPositionRouter.modifyPosition(poolKey, IPoolManager.ModifyPositionParams(-60, 60, 10 ether), "");

        // Add liquidity from -120 to +120
        modifyPositionRouter.modifyPosition(poolKey, IPoolManager.ModifyPositionParams(-120, 120, 10 ether), "");

        // Add liquidity from minimum tick to maximum tick
        modifyPositionRouter.modifyPosition(poolKey,IPoolManager.ModifyPositionParams(TickMath.minUsableTick(60),TickMath.maxUsableTick(60),50 ether), "");

        // Approve the tokens for swapping through the swapRouter
        token0.approve(address(swapRouter), 100 ether);
        token1.approve(address(swapRouter), 100 ether);
    }

    function setUp() public {
        _deployERC20Tokens();
        poolManager = new PoolManager(500_000);
        _stubValidateHookAddress();
        _initializePool();
        _addLiquidityToPool();
    }

    receive() external payable {}

    // Unlike the testing environment in Hardhat, the signer account that is calling functions on our contracts in Foundry is actually a smart contract, not an externally owned account like Hardhat.
    // so, we need to make sure the Test smart contract can receive ERC-1155 tokens
    // https://eips.ethereum.org/EIPS/eip-1155#erc-1155-token-receiver
    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return
            bytes4(
                keccak256(
                    "onERC1155Received(address,address,uint256,uint256,bytes)"
                )
            );
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return
            bytes4(
                keccak256(
                    "onERC1155BatchReceived(address,address,uint256[],uint256[],bytes)"
                )
            );
    }

    function test_placeOrder() public {
        // Lets place a ZeroForOne order at tick 100

        int24 tick = 100;
        uint256 amount = 10 ether;
        bool ZeroForOne = true;

        // Get original balance of token0
        uint256 beforeBalance = token0.balanceOf(address(this));
        console.log("Token 0 balance before placing order is %s",beforeBalance);

        // approval transaction to allow uniswap hook to spend passed amount
        token0.approve(address(hook), amount);
        //Now place an order
        int24 tickLower = hook.placeOrder(poolKey, tick, ZeroForOne, amount);

        // Get new balance of token0
        uint256 afterBalance = token0.balanceOf(address(this));
        console.log("Token 0 balance after placing order is %s",afterBalance);

        uint256 balance = beforeBalance - afterBalance;
        uint256 realBalance = balance / 10 ** 18;
        console.log("Amount of token 0 order placed is %s",realBalance);

        // Since we deployed the pool contract with tick spacing = 60
        // i.e. the tick can only be a multiple of 60
        // and initially the tick is 0
        // the tickLower should be 60 since we placed an order at tick 100 going by the math
        assertEq(tickLower, 60);

        // Ensure that our balance was reduced by `amount` tokens
        assertEq(balance, amount);

        // Check the balance of ERC-1155 tokens we received
        uint256 tokenId = hook.getTokenId(poolKey, tickLower, ZeroForOne);
        uint256 tokenBalance = hook.balanceOf(address(this), tokenId);

        // Ensure that we were, in fact, given ERC-1155 tokens for the order
        // equal to the `amount` of token0 tokens we placed the order for
        assertTrue(tokenId != 0);
        assertEq(tokenBalance, amount);
    }

    function test_cancelOrder() public {
        // Lets place a ZeroForOne order at tick 100

        int24 tick = 100;
        uint256 amount = 10 ether;
        bool ZeroForOne = true;

        // Get original balance of token0
        uint256 beforeBalance = token0.balanceOf(address(this));
        console.log("Token 0 balance before placing order is %s",beforeBalance);

        //First place order
        token0.approve(address(hook), amount);
        int24 tickLower = hook.placeOrder(poolKey, tick, ZeroForOne, amount);

        // Get new balance of token0
        uint256 afterBalance = token0.balanceOf(address(this));
        console.log("Token 0 balance after placing order is %s",afterBalance);

        uint256 balance =  beforeBalance - afterBalance;
        uint256 realBalance = balance / 10 ** 18;
        console.log("Amount of token 0 order placed is %s",realBalance);

        // Since we deployed the pool contract with tick spacing = 60
        // i.e. the tick can only be a multiple of 60
        // and initially the tick is 0
        // the tickLower should be 60 since we placed an order at tick 100 going by the math
        assertEq(tickLower, 60);
        // Ensure that our balance was reduced by `amount` tokens
        assertEq(balance, amount);

        // Check the balance of ERC-1155 tokens we received
        uint256 tokenId = hook.getTokenId(poolKey, tickLower, ZeroForOne);
        uint256 tokenBalance = hook.balanceOf(address(this), tokenId);
        assertEq(tokenBalance, amount);
        console.log("Amount of ERC1155 received after order placed is %s",tokenBalance / 10 ** 18);

        console.log("Now initiating order cancellation......");

        // Now cancel order
        hook.cancelOrder(poolKey, tick, ZeroForOne);

        // Check that we received our token0 tokens back, and no longer own any ERC-1155 tokens
        uint256 finalBalance = token0.balanceOf(address(this));
        console.log("Token 0 balance after cancelling placed order is %s", finalBalance);
        assertEq(finalBalance, beforeBalance);

        tokenBalance = hook.balanceOf(address(this), tokenId);
        console.log("Amount of ERC1155 remianing after being burned is %s",tokenBalance);

        // Ensure that we were, in fact, given ERC-1155 tokens for the order
        // equal to the `amount` of token0 tokens we placed the order for
        assertEq(tokenBalance, 0);
    }

    function test_limitOrderExecution_zeroForOne() public {
        int24 tick = 100;
        uint256 amount = 10 ether;
        bool zeroForOne = true;
        // Place our order at tick 100 for 10e18 token0 tokens
        uint256 token0BalanceBeforeSwap = token0.balanceOf(address(this));
        console.log("Token0 balance in user wallet BEFORE placing limit order", token0BalanceBeforeSwap / 10** 18);
        uint256 token1BalanceBeforeSwap = token1.balanceOf(address(this));
        console.log("Token1 balance in user wallet BEFORE placing limit order", token1BalanceBeforeSwap / 10** 18);
        token0.approve(address(hook), amount);
        console.log("%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%");
        console.log("Starting to place a limit order....");
        console.log("%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%");
        int24 tickLower = hook.placeOrder(poolKey, tick, zeroForOne, amount);

        // Do a separate manual swap from oneForZero to make tick go up
        // Sell 1e18 token1 tokens for token0 tokens
        console.log("%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%");
        console.log("Starting a manual swap in a one to zero direction in order to trigger a limit order in zero to one direction....:");
        console.log("%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%");
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: !zeroForOne,
            amountSpecified: 1 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_RATIO - 1
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({withdrawTokens: true, settleUsingTransfer: true});

        swapRouter.swap(poolKey, params, testSettings, "");
        console.log("Token0 balance in user wallet AFTER limit order swap", token0.balanceOf(address(this)) / 10**18);


        // Check that the order has been executed
        int256 tokensLeftToSell = hook.takeProfitPositions(
            poolId,
            tick,
            zeroForOne
        );
        assertEq(tokensLeftToSell, 0);

        // Check that the hook contract has the expected number of token1 tokens ready to redeem
        uint256 tokenId = hook.getTokenId(poolKey, tickLower, zeroForOne);
        uint256 claimableTokens = hook.tokenIdClaimable(tokenId);
        console.log("Claimable token1 tokens:", claimableTokens / 10**18);
        uint256 hookContractToken1Balance = token1.balanceOf(address(hook));
        console.log("hookContractToken1Balance:", hookContractToken1Balance / 10**18);
        assertEq(claimableTokens, hookContractToken1Balance);

        // Ensure we can redeem the token1 tokens
        uint256 originalToken1Balance = token1.balanceOf(address(this));
        console.log("%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%");
        console.log("Invoke redeem function to swap received ERC1155 tokens for bought tokens");
        console.log("%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%");
        hook.redeem(tokenId, amount, address(this));
        uint256 newToken1Balance = token1.balanceOf(address(this));
        console.log("Token1 balance in user wallet AFTER redeeming from hook contract", newToken1Balance / 10**18);
        assertEq(newToken1Balance - originalToken1Balance, claimableTokens);
    }

    function test_limitOrderExecution_oneForZero() public {
        int24 tick = -100;
        uint256 amount = 10 ether;
        bool zeroForOne = false;
        // Place our order at tick 100 for 10e18 token0 tokens
        uint256 token0BalanceBeforeSwap = token0.balanceOf(address(this));
        console.log("Token0 balance in user wallet BEFORE placing limit order", token0BalanceBeforeSwap / 10** 18);
        uint256 token1BalanceBeforeSwap = token1.balanceOf(address(this));
        console.log("Token1 balance in user wallet BEFORE placing limit order", token1BalanceBeforeSwap / 10** 18);


        token1.approve(address(hook), amount);
        console.log("%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%");
        console.log("Starting to place a limit order....");
        console.log("%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%");
        int24 tickLower = hook.placeOrder(poolKey, tick, zeroForOne, amount);

        // Do a separate swap from zeroForOne to make tick go down
       // Sell 1e18 token0 tokens for token1 tokens
        console.log("%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%");
        console.log("Starting a manual swap in a zero to one direction in order to trigger a limit order in one to zero direction....:");
        console.log("%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%");
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: !zeroForOne,
            amountSpecified: 1 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({withdrawTokens: true, settleUsingTransfer: true});

        swapRouter.swap(poolKey, params, testSettings, "");
        console.log("Token1 balance in user wallet AFTER limit order swap", token1.balanceOf(address(this)) / 10**18);


        // Check that the order has been executed
        int256 tokensLeftToSell = hook.takeProfitPositions(
            poolId,
            tick,
            zeroForOne
        );
        assertEq(tokensLeftToSell, 0);

        // Check that the hook contract has the expected number of token0 tokens ready to redeem
        uint256 tokenId = hook.getTokenId(poolKey, tickLower, zeroForOne);
        uint256 claimableTokens = hook.tokenIdClaimable(tokenId);
        console.log("Claimable token0 tokens:", claimableTokens / 10**18);
        uint256 hookContractToken1Balance = token0.balanceOf(address(hook));
        console.log("hookContractToken1Balance:", hookContractToken1Balance / 10**18);
        assertEq(claimableTokens, hookContractToken1Balance);

        // Ensure we can redeem the token1 tokens
        uint256 originalToken0Balance = token0.balanceOf(address(this));
        console.log("%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%");
        console.log("Invoke redeem function to swap received ERC1155 tokens for bought tokens");
        console.log("%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%");
        hook.redeem(tokenId, amount, address(this));
        uint256 newToken0Balance = token0.balanceOf(address(this));
        console.log("Token0 balance in user wallet AFTER redeeming from hook contract", newToken0Balance / 10**18);
        assertEq(newToken0Balance - originalToken0Balance, claimableTokens);
    }
}