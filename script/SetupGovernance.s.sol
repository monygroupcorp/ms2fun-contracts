// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {EXECGovernance} from "../src/governance/EXECGovernance.sol";

contract SetupGovernance is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address execToken = vm.envAddress("EXEC_TOKEN");
        
        vm.startBroadcast(deployerPrivateKey);

        EXECGovernance governance = new EXECGovernance(execToken);
        console.log("EXECGovernance deployed at:", address(governance));

        vm.stopBroadcast();
    }
}

