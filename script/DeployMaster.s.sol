// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {MasterRegistryV1} from "../src/master/MasterRegistryV1.sol";
import {MasterRegistry} from "../src/master/MasterRegistry.sol";
import {ICreateX, CREATEX} from "../src/shared/CreateXConstants.sol";

contract DeployMaster is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        bytes32 implSalt = vm.envBytes32("MASTER_REGISTRY_IMPL_SALT");
        bytes32 proxySalt = vm.envBytes32("MASTER_REGISTRY_PROXY_SALT");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy implementation via CREATE3
        address implAddr = ICreateX(CREATEX).deployCreate3(
            implSalt, type(MasterRegistryV1).creationCode
        );
        console.log("Implementation deployed at:", implAddr);

        // Deploy proxy via CREATE3
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address)",
            msg.sender
        );
        bytes memory proxyInitCode = abi.encodePacked(
            type(MasterRegistry).creationCode,
            abi.encode(implAddr, initData)
        );
        address proxyAddr = ICreateX(CREATEX).deployCreate3(proxySalt, proxyInitCode);
        console.log("MasterRegistry (ERC1967 proxy):", proxyAddr);

        vm.stopBroadcast();
    }
}
