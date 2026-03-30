// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {MasterRegistryV1} from "../src/master/MasterRegistryV1.sol";
import {ERC404Factory} from "../src/factories/erc404/ERC404Factory.sol";
import {ERC404BondingInstance} from "../src/factories/erc404/ERC404BondingInstance.sol";

/// @notice Deploys a new ERC404BondingInstance implementation + ERC404Factory,
///         wires protocol treasury, and registers the factory in MasterRegistry.
///
///         Run with:
///         forge script script/DeployERC404Factory.s.sol \
///           --account <keystore> \
///           --sender 0x1821bd18cbdd267ce4e389f893ddfe7beb333ab6 \
///           --rpc-url $SEPOLIA_RPC_URL \
///           --broadcast --verify
contract DeployERC404Factory is Script {

    // ── Existing Sepolia addresses ────────────────────────────────────────────
    address constant MASTER_REGISTRY        = 0x00001152CBa5fDB16A0FAE780fFebD5b9dF8e7cF;
    address constant GLOBAL_MSG_REGISTRY    = 0x74B4Cc5Cd1F4FFB8025c4a20034D25Cc42E1dd6D;
    address constant COMPONENT_REGISTRY     = 0x00001152Ed1bD8e76693cB775c79708275bBb2F3;
    address constant LAUNCH_MANAGER         = 0x354768153a0d3edC314D9f6baa2fd56a6961B449;
    address constant PROTOCOL_TREASURY      = 0xeBF79fed2520e29dc0a2E3D9055621Ef69a95a67;
    address constant WETH                   = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address constant DEPLOYER               = 0x1821BD18CBdD267CE4e389f893dDFe7BEB333aB6;

    function run() public {
        vm.startBroadcast();

        // 1. Deploy new implementation
        ERC404BondingInstance impl = new ERC404BondingInstance();
        console.log("ERC404BondingInstance impl:", address(impl));

        // 2. Deploy new factory
        ERC404Factory factory = new ERC404Factory(
            ERC404Factory.CoreConfig({
                implementation: address(impl),
                masterRegistry:  MASTER_REGISTRY,
                protocol:        DEPLOYER,
                weth:            WETH
            }),
            ERC404Factory.ModuleConfig({
                globalMessageRegistry: GLOBAL_MSG_REGISTRY,
                launchManager:         LAUNCH_MANAGER,
                componentRegistry:     COMPONENT_REGISTRY
            })
        );
        console.log("ERC404Factory:", address(factory));

        // 3. Wire treasury
        factory.setProtocolTreasury(PROTOCOL_TREASURY);
        console.log("Treasury set");

        // 4. Register in MasterRegistry
        MasterRegistryV1(MASTER_REGISTRY).registerFactory(
            address(factory),
            "ERC404",
            "ERC404-Bonding-Curve-Factory",
            "ERC404 Bonding Curve",
            "https://ms2.fun",
            new bytes32[](0)
        );
        console.log("Factory registered");

        vm.stopBroadcast();
    }
}
