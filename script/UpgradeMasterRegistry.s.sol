// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {MasterRegistryV1} from "../src/master/MasterRegistryV1.sol";

/// @notice Upgrades the Sepolia MasterRegistryV1 proxy to the new implementation,
///         deactivates the old ERC404Factory, and revokes the test instance.
///
///         Run with:
///         forge script script/UpgradeMasterRegistry.s.sol \
///           --account <keystore> \
///           --sender 0x1821bd18cbdd267ce4e389f893ddfe7beb333ab6 \
///           --rpc-url <sepolia-rpc> \
///           --broadcast --verify
contract UpgradeMasterRegistry is Script {

    MasterRegistryV1 constant PROXY =
        MasterRegistryV1(0x00001152CBa5fDB16A0FAE780fFebD5b9dF8e7cF);

    address constant OLD_ERC404_FACTORY = 0xd84f755AdFac9408ADbde65832F8A1BFf5179bF8;

    // Fill in before broadcasting — the test instance address from Sepolia
    address constant TEST_INSTANCE = address(0); // TODO: set before broadcast

    function run() public {
        require(TEST_INSTANCE != address(0), "Set TEST_INSTANCE before broadcasting");

        vm.startBroadcast();

        // 1. Deploy new implementation
        MasterRegistryV1 newImpl = new MasterRegistryV1();
        console.log("New implementation:", address(newImpl));

        // 2. Upgrade proxy
        PROXY.upgradeToAndCall(address(newImpl), "");
        console.log("Proxy upgraded");

        // 3. Deactivate old ERC404 factory
        PROXY.deactivateFactory(OLD_ERC404_FACTORY);
        console.log("Old ERC404Factory deactivated");

        // 4. Revoke test instance
        PROXY.revokeInstance(TEST_INSTANCE);
        console.log("Test instance revoked");

        vm.stopBroadcast();
    }
}
