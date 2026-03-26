// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DeployCore} from "./DeployCore.sol";

/// @notice Deploys the full protocol to Sepolia.
///         Run with: forge script script/DeploySepolia.s.sol --account <keystore> \
///                   --rpc-url sepolia --broadcast --verify
contract DeploySepolia is DeployCore {

    function run() public {
        vm.startBroadcast();
        deploy(msg.sender, _sepoliaConfig());
        vm.stopBroadcast();
    }

    function _sepoliaConfig() internal pure returns (NetworkConfig memory cfg) {
        AlignmentTargetConfig[] memory targets = new AlignmentTargetConfig[](1);
        targets[0] = AlignmentTargetConfig({
            token:             0x779877A7B0D9E8603169DdbD7836e478b4624789, // LINK
            symbol:            "LINK",
            name:              "Chainlink",
            description:       "Chainlink - Sepolia alignment target",
            deployUniVault:    true,
            deployCypherVault: false,
            deployZAMMVault:   false
        });

        cfg.chainId          = 11155111;
        cfg.weth             = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
        cfg.v4PoolManager    = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
        cfg.v3Factory        = 0x0227628f3F023bb0B980b67D528571c95c6DaC1c;
        cfg.v2Factory        = 0xF62c03E08ada871A0bEb309762E260a7a6a880E6;
        cfg.cypherPositionManager = address(0);
        cfg.cypherRouter     = address(0);
        cfg.zamm             = address(0);
        cfg.zrouter          = address(0);
        cfg.safe             = address(0); // deploys MockSafe
        // Vanity salts — deployer guard: 0x1821bd18cbdd267ce4e389f893ddfe7beb333ab6
        cfg.saltMasterRegistry = 0x1821bd18cbdd267ce4e389f893ddfe7beb333ab6006fc783a2ee2a5801bcc77a; // => 0x00001152cba5fdb16a0fae780ffebd5b9df8e7cf
        cfg.saltTreasury       = 0x1821bd18cbdd267ce4e389f893ddfe7beb333ab60082245dad1d7c3e0071f20f; // => 0x00001152e56eb45082de505e9e9be5dc158e4cfc
        cfg.saltQueueManager   = 0x1821bd18cbdd267ce4e389f893ddfe7beb333ab600cf49066351827200ad2a5e; // => 0x00001152c0715721ae4d2b0b693862953dcfb99c
        cfg.saltGlobalMsgReg   = 0x1821bd18cbdd267ce4e389f893ddfe7beb333ab6006b9e54d6a39a0801f14fa8; // => 0x0000115268c7cb1a508ec18da1cb2d71c0b2c637
        cfg.saltAlignmentReg   = 0x1821bd18cbdd267ce4e389f893ddfe7beb333ab60057d45cf31029d003f61c1d; // => 0x00001152db13c4afb4d9f4bba93f364692f372eb
        cfg.saltComponentReg   = 0x1821bd18cbdd267ce4e389f893ddfe7beb333ab600586503138e974c00a226d9; // => 0x00001152ed1bd8e76693cb775c79708275bbb2f3
        cfg.priceDeviationBps  = 1000;
        cfg.twapSeconds        = 1800;
        cfg.zrouterFee         = 3000;
        cfg.zrouterTickSpacing = 60;
        cfg.alignmentTargets   = targets;
        cfg.jsonOutputPath     = "./deployments/sepolia.json";
    }
}
