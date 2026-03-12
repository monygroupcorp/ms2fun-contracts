// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {ERC1155Factory} from "../src/factories/erc1155/ERC1155Factory.sol";

contract DeployERC1155Factory is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address masterRegistry = vm.envAddress("MASTER_REGISTRY");
        address globalMessageRegistry = vm.envAddress("GLOBAL_MESSAGE_REGISTRY");
        address componentRegistry = vm.envAddress("COMPONENT_REGISTRY");

        vm.startBroadcast(deployerPrivateKey);

        ERC1155Factory factory = new ERC1155Factory(masterRegistry, globalMessageRegistry, componentRegistry);
        console.log("ERC1155Factory deployed at:", address(factory));

        vm.stopBroadcast();
    }
}

