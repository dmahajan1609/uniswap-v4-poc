pragma solidity ^0.8.21;

import {LimitOrderHook} from "./LimitOrderHook.sol";
import {BaseHook} from "periphery-next/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

contract LimitOrderStub is LimitOrderHook {
    constructor(IPoolManager _poolManager, LimitOrderHook addressToEtch)
        LimitOrderHook(_poolManager, ""){}

        // Note: 
        //The way Uniswap v4 is designed, it requires the contract address of Hook contracts to be a very specific pattern. In fact, it requires that certain bits in the address are 0 or 1 depending on whether that contract implements a specific Hook or not. When Uniswap is deployed to a network, this will likely happen through the use of CREATE2 hook deployments where Hooks will be deployed to a pre-determined address to make sure their addresses are valid and follow that pattern.
        //While testing, however, this is bit of an issue. So instead, we need to override the validateHookAddress to prevent it from checking whether the address is valid or not. But then again, it is annoying to have this piece of code in our smart contract, as we might accidentally deploy it to a real network eventually while forgetting to delete that from our contract.
        // Instead, the Uniswap authors came up with a hacky, but clever, solution to solve this in local testing environments which takes advantage of some Foundry Cheat Codes. Cheat codes in Foundry allow you to do things that you cannot really do on a real network - such as modifying and accessing the underlying contract storage directly.
        function validateHookAddress(BaseHook _this) internal pure override {}

}

