// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {ERC404Factory} from "../src/factories/erc404/ERC404Factory.sol";
import {ERC404BondingInstance} from "../src/factories/erc404/ERC404BondingInstance.sol";
import {ERC404StakingModule} from "../src/factories/erc404/ERC404StakingModule.sol";
import {LiquidityDeployerModule} from "../src/factories/erc404/LiquidityDeployerModule.sol";
import {LaunchManager} from "../src/factories/erc404/LaunchManager.sol";
import {CurveParamsComputer} from "../src/factories/erc404/CurveParamsComputer.sol";

contract DeployERC404Factory is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address masterRegistry = vm.envAddress("MASTER_REGISTRY");
        address protocol = vm.envAddress("PROTOCOL");

        vm.startBroadcast(deployerPrivateKey);

        ERC404BondingInstance impl = new ERC404BondingInstance();
        console.log("ERC404BondingInstance implementation deployed at:", address(impl));
        ERC404StakingModule stakingModule = new ERC404StakingModule(masterRegistry);
        console.log("ERC404StakingModule deployed at:", address(stakingModule));
        LiquidityDeployerModule liquidityDeployer = new LiquidityDeployerModule();
        console.log("LiquidityDeployerModule deployed at:", address(liquidityDeployer));
        LaunchManager launchManager = new LaunchManager(protocol);
        console.log("LaunchManager deployed at:", address(launchManager));
        CurveParamsComputer curveComputer = new CurveParamsComputer(protocol);
        console.log("CurveParamsComputer deployed at:", address(curveComputer));

        ERC404Factory factory = _deployFactory(
            address(impl), masterRegistry, protocol,
            address(stakingModule), address(liquidityDeployer),
            address(launchManager), address(curveComputer)
        );
        console.log("ERC404Factory deployed at:", address(factory));

        // Set up default graduation profile (profileId = 1)
        factory.setProfile(1, ERC404Factory.GraduationProfile({
            targetETH: 15 ether,
            unitPerNFT: 1_000_000,
            poolFee: 3000,
            tickSpacing: 60,
            liquidityReserveBps: 1000,
            active: true
        }));
        console.log("Default graduation profile set (profileId=1)");

        vm.stopBroadcast();
    }

    function _deployFactory(
        address impl,
        address masterRegistry,
        address protocol,
        address stakingModule,
        address liquidityDeployer,
        address launchManager,
        address curveComputer
    ) internal returns (ERC404Factory) {
        return new ERC404Factory(
            ERC404Factory.CoreConfig({
                implementation: impl,
                masterRegistry: masterRegistry,
                instanceTemplate: vm.envAddress("INSTANCE_TEMPLATE"),
                v4PoolManager: vm.envAddress("V4_POOL_MANAGER"),
                weth: vm.envAddress("WETH"),
                protocol: protocol
            }),
            ERC404Factory.ModuleConfig({
                stakingModule: stakingModule,
                liquidityDeployer: liquidityDeployer,
                globalMessageRegistry: vm.envAddress("GLOBAL_MESSAGE_REGISTRY"),
                launchManager: launchManager,
                curveComputer: curveComputer,
                tierGatingModule: address(0),
                componentRegistry: address(0)
            })
        );
    }
}
