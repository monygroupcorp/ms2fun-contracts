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
        cfg.saltMasterRegistry = 0x1821bd18cbdd267ce4e389f893ddfe7beb333ab600721d1a3d22a2ea02871306;
        cfg.saltTreasury       = 0x1821bd18cbdd267ce4e389f893ddfe7beb333ab600530939d9b7c16301180b07;
        cfg.saltQueueManager   = 0x1821bd18cbdd267ce4e389f893ddfe7beb333ab6007cd1badd91acac0064a2a3;
        cfg.saltGlobalMsgReg   = 0x1821bd18cbdd267ce4e389f893ddfe7beb333ab60009c6c91fc2b55e00e94a29;
        cfg.saltAlignmentReg   = 0x1821bd18cbdd267ce4e389f893ddfe7beb333ab60033170d37eaf164000226a2;
        cfg.saltComponentReg   = 0x1821bd18cbdd267ce4e389f893ddfe7beb333ab6008821ee824b2be903e32004;
        cfg.priceDeviationBps  = 1000;
        cfg.twapSeconds        = 1800;
        cfg.zrouterFee         = 3000;
        cfg.zrouterTickSpacing = 60;
        cfg.alignmentTargets   = targets;
        cfg.jsonOutputPath     = "./deployments/sepolia.json";
    }
}
