// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {ERC404Factory} from "../src/factories/erc404/ERC404Factory.sol";
import {ERC404BondingInstance} from "../src/factories/erc404/ERC404BondingInstance.sol";
import {LaunchManager} from "../src/factories/erc404/LaunchManager.sol";
import {CurveParamsComputer} from "../src/factories/erc404/CurveParamsComputer.sol";

contract DeployERC404Factory is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address masterRegistry = vm.envAddress("MASTER_REGISTRY");
        address protocol = vm.envAddress("PROTOCOL");
        address componentRegistry = vm.envAddress("COMPONENT_REGISTRY");
        address globalMessageRegistry = vm.envAddress("GLOBAL_MESSAGE_REGISTRY");

        vm.startBroadcast(deployerPrivateKey);

        ERC404BondingInstance impl = new ERC404BondingInstance();
        console.log("ERC404BondingInstance implementation deployed at:", address(impl));

        LaunchManager launchManager = new LaunchManager(protocol);
        console.log("LaunchManager deployed at:", address(launchManager));

        CurveParamsComputer curveComputer = new CurveParamsComputer(protocol);
        console.log("CurveParamsComputer deployed at:", address(curveComputer));

        ERC404Factory factory = new ERC404Factory(
            ERC404Factory.CoreConfig({
                implementation: address(impl),
                masterRegistry: masterRegistry,
                protocol: protocol
            }),
            ERC404Factory.ModuleConfig({
                globalMessageRegistry: globalMessageRegistry,
                launchManager: address(launchManager),
                componentRegistry: componentRegistry
            })
        );
        console.log("ERC404Factory deployed at:", address(factory));

        // NOTE: Approve curveComputer and set preset via ComponentRegistry + LaunchManager
        // after deploying — curveComputer must be approved in ComponentRegistry first,
        // then call launchManager.setPreset(presetId, Preset{...}).

        vm.stopBroadcast();
    }
}
