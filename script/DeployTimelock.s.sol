// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {Timelock} from "solady/accounts/Timelock.sol";

contract DeployTimelock is Script {
    uint256 public constant MIN_DELAY = 48 hours; // 172800 seconds

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address safe = vm.envAddress("SAFE_ADDRESS");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy Timelock directly (not behind a proxy — timelocks should be immutable)
        Timelock timelock = new Timelock();
        console.log("Timelock deployed at:", address(timelock));

        // Configure roles
        address[] memory proposers = new address[](1);
        proposers[0] = safe;

        address[] memory executors = new address[](1);
        executors[0] = timelock.OPEN_ROLE_HOLDER(); // Anyone can execute after delay

        address[] memory cancellers = new address[](1);
        cancellers[0] = safe;

        // Initialize: 48h delay, Safe as admin/proposer/canceller, open executor
        timelock.initialize(MIN_DELAY, safe, proposers, executors, cancellers);
        console.log("Timelock initialized with min delay:", MIN_DELAY);
        console.log("Safe (admin/proposer/canceller):", safe);

        vm.stopBroadcast();
    }
}
