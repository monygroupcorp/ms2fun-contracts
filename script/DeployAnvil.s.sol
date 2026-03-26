// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DeployCore} from "./DeployCore.sol";

/// @notice Deploys the full protocol to a local Anvil chain.
///         Called by deploy.mjs: forge script script/DeployAnvil.s.sol --broadcast
///         Writes deployments/anvil.json which deploy.mjs copies to
///         src/config/contracts.local.json for the frontend.
contract DeployAnvil is DeployCore {

    // Mainnet addresses available on an Anvil mainnet fork
    address constant WETH       = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant V4_PM      = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address constant V2_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    address constant MS2_TOKEN  = 0x98Ed411B8cf8536657c660Db8aA55D9D4bAAf820;
    address constant CULT_TOKEN = 0x0000000000c5dc95539589fbD24BE07c6C14eCa4;

    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        vm.startBroadcast(pk);
        deploy(deployer, _anvilConfig());
        vm.stopBroadcast();
    }

    function _anvilConfig() internal view returns (NetworkConfig memory cfg) {
        AlignmentTargetConfig[] memory targets = new AlignmentTargetConfig[](2);
        targets[0] = AlignmentTargetConfig({
            token: MS2_TOKEN, symbol: "MS2",
            name: "Milady-Station-2", description: "MS2 community alignment target",
            deployUniVault: true, deployCypherVault: false, deployZAMMVault: false
        });
        targets[1] = AlignmentTargetConfig({
            token: CULT_TOKEN, symbol: "CULT",
            name: "Cult-DAO", description: "Cult DAO community alignment target",
            deployUniVault: true, deployCypherVault: false, deployZAMMVault: false
        });

        // Use timestamp-derived salts so repeated Anvil restarts don't collide
        cfg.chainId          = block.chainid;
        cfg.weth             = WETH;
        cfg.v4PoolManager    = V4_PM;
        cfg.v3Factory        = V3_FACTORY;
        cfg.v2Factory        = V2_FACTORY;
        cfg.cypherPositionManager = address(0);
        cfg.cypherRouter     = address(0);
        cfg.zamm             = address(0);
        cfg.zrouter          = address(0);
        cfg.safe             = address(0);
        // Sequential salts — unguarded so any address can call CreateX on local chain
        cfg.saltMasterRegistry = bytes32(uint256(keccak256(abi.encode(block.timestamp, "master"))));
        cfg.saltTreasury       = bytes32(uint256(keccak256(abi.encode(block.timestamp, "treasury"))));
        cfg.saltQueueManager   = bytes32(uint256(keccak256(abi.encode(block.timestamp, "queue"))));
        cfg.saltGlobalMsgReg   = bytes32(uint256(keccak256(abi.encode(block.timestamp, "gmr"))));
        cfg.saltAlignmentReg   = bytes32(uint256(keccak256(abi.encode(block.timestamp, "align"))));
        cfg.saltComponentReg   = bytes32(uint256(keccak256(abi.encode(block.timestamp, "comp"))));
        cfg.priceDeviationBps  = 1000;
        cfg.twapSeconds        = 1800;
        cfg.zrouterFee         = 3000;
        cfg.zrouterTickSpacing = 60;
        cfg.alignmentTargets   = targets;
        cfg.jsonOutputPath     = "./deployments/anvil.json";
    }
}
