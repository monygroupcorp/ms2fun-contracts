// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {Ownable} from "solady/auth/Ownable.sol";

contract MigrateOwnership is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address timelock = vm.envAddress("TIMELOCK_ADDRESS");

        // All owned protocol contracts
        address masterRegistry = vm.envAddress("MASTER_REGISTRY");
        address protocolTreasury = vm.envAddress("PROTOCOL_TREASURY");
        address featuredQueueManager = vm.envAddress("FEATURED_QUEUE_MANAGER");
        address queryAggregator = vm.envAddress("QUERY_AGGREGATOR");

        vm.startBroadcast(deployerPrivateKey);

        Ownable(masterRegistry).transferOwnership(timelock);
        console.log("MasterRegistryV1 ownership transferred to timelock");

        Ownable(protocolTreasury).transferOwnership(timelock);
        console.log("ProtocolTreasuryV1 ownership transferred to timelock");

        Ownable(featuredQueueManager).transferOwnership(timelock);
        console.log("FeaturedQueueManager ownership transferred to timelock");

        Ownable(queryAggregator).transferOwnership(timelock);
        console.log("QueryAggregator ownership transferred to timelock");

        vm.stopBroadcast();

        console.log("All protocol contracts now owned by timelock:", timelock);
    }
}
