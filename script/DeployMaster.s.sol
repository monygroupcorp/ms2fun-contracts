// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {MasterRegistryV1} from "../src/master/MasterRegistryV1.sol";
import {MasterRegistry} from "../src/master/MasterRegistry.sol";

contract DeployMaster is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(deployerPrivateKey);

        // Deploy implementation
        MasterRegistryV1 implementation = new MasterRegistryV1();
        console.log("Implementation deployed at:", address(implementation));

        // Deploy proxy using Solady's LibClone (via MasterRegistry wrapper)
        // Use single-param initialize (owner-only model, execToken ignored)
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address)",
            msg.sender
        );
        MasterRegistry proxy = new MasterRegistry(address(implementation), initData);
        console.log("Proxy deployed at:", address(proxy));

        vm.stopBroadcast();
    }
}

