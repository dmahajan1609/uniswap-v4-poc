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

    using PoolIdLibrary for IPoolManager.PoolKey;

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
    function deployERC20Tokens() private {
        TestERC20 tokenA = new TestERC20(2**128);
        TestERC20 tokenB = new TestERC20(2**128);

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
        // Deploy the test-versions of modifyPositionRouter and swapRouter
        modifyPositionRouter = new PoolModifyPositionTest(IPoolManager(address(poolManager)));
        swapROuter = new PoolSwapTest(IPoolManager(address(poolManager)));

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
        poolManager.initialize(poolKey, SQRT_RATIO_1_1);
    }

    function _addLiquidityToPool() private {
        // Mint a lot of tokens to ourselves
        token0.mint(address(this), 100 ether);
        token1.mint(address(this), 100 ether);

        // Approve the modifyPositionRouter to spend your tokens
        token0.approve(address(modifyPositionRouter), 100 ether);
        token1.approve(address(modifyPositionRouter), 100 ether);

        // Add liquidity across different tick ranges
        // First, from -60 to +60
        // Then, from -120 to +120
        // Then, from minimum possible tick to maximum possible tick

        // Add liquidity from -60 to +60
        modifyPositionRouter.modifyPosition(
            poolKey,
            IPoolManager.ModifyPositionParams(-60, 60, 10 ether)
        );

        // Add liquidity from -120 to +120
        modifyPositionRouter.modifyPosition(
            poolKey,
            IPoolManager.ModifyPositionParams(-120, 120, 10 ether)
        );

        // Add liquidity from minimum tick to maximum tick
        modifyPositionRouter.modifyPosition(
            poolKey,
            IPoolManager.ModifyPositionParams(
                TickMath.minUsableTick(60),
                TickMath.maxUsableTick(60),
                50 ether
            )
        );

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


        // Since we deployed the pool contract with tick spacing = 60
        // i.e. the tick can only be a multiple of 60
        // and initially the tick is 0
        // the tickLower should be 60 since we placed an order at tick 100
        assertEq(tickLower, 60);

        // Ensure that our balance was reduced by `amount` tokens
        assertEq(originalBalance - newBalance, amount);

        // Check the balance of ERC-1155 tokens we received
        uint256 tokenId = hook.getTokenId(poolKey, tickLower, zeroForOne);
        uint256 tokenBalance = hook.balanceOf(address(this), tokenId);

        // Ensure that we were, in fact, given ERC-1155 tokens for the order
        // equal to the `amount` of token0 tokens we placed the order for
        assertTrue(tokenId != 0);
        assertEq(tokenBalance, amount);


    }

}