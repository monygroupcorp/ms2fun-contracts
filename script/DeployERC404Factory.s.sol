// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {ERC404Factory} from "../src/factories/erc404/ERC404Factory.sol";

contract DeployERC404Factory is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address masterRegistry = vm.envAddress("MASTER_REGISTRY");
        address instanceTemplate = vm.envAddress("INSTANCE_TEMPLATE");
        address hookFactory = vm.envAddress("HOOK_FACTORY");
        address v4PoolManager = vm.envAddress("V4_POOL_MANAGER");
        address weth = vm.envAddress("WETH");

        vm.startBroadcast(deployerPrivateKey);

        ERC404Factory factory = new ERC404Factory(masterRegistry, instanceTemplate, hookFactory, v4PoolManager, weth);
        console.log("ERC404Factory deployed at:", address(factory));

        vm.stopBroadcast();
    }
}

