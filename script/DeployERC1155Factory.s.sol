// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {ERC1155Factory} from "../src/factories/erc1155/ERC1155Factory.sol";

contract DeployERC1155Factory is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address masterRegistry = vm.envAddress("MASTER_REGISTRY");
        address instanceTemplate = vm.envAddress("INSTANCE_TEMPLATE");
        
        vm.startBroadcast(deployerPrivateKey);

        ERC1155Factory factory = new ERC1155Factory(masterRegistry, instanceTemplate);
        console.log("ERC1155Factory deployed at:", address(factory));

        vm.stopBroadcast();
    }
}

