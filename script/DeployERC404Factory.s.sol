// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {ERC404Factory} from "../src/factories/erc404/ERC404Factory.sol";
import {ERC404StakingModule} from "../src/factories/erc404/ERC404StakingModule.sol";

contract DeployERC404Factory is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address masterRegistry = vm.envAddress("MASTER_REGISTRY");
        address instanceTemplate = vm.envAddress("INSTANCE_TEMPLATE");
        address v4PoolManager = vm.envAddress("V4_POOL_MANAGER");
        address weth = vm.envAddress("WETH");
        address creator = vm.envAddress("CREATOR");
        uint256 creatorFeeBps = vm.envUint("CREATOR_FEE_BPS");
        uint256 creatorGraduationFeeBps = vm.envUint("CREATOR_GRADUATION_FEE_BPS");

        vm.startBroadcast(deployerPrivateKey);

        address protocol = vm.envAddress("PROTOCOL");
        ERC404StakingModule stakingModule = new ERC404StakingModule(masterRegistry);
        console.log("ERC404StakingModule deployed at:", address(stakingModule));
        ERC404Factory factory = new ERC404Factory(masterRegistry, instanceTemplate, v4PoolManager, weth, protocol, creator, creatorFeeBps, creatorGraduationFeeBps, address(stakingModule));
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
}

