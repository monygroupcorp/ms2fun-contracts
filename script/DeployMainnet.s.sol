// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DeployCore} from "./DeployCore.sol";

/// @notice Mainnet deployment — populate _mainnetConfig() before use.
///         Run with: forge script script/DeployMainnet.s.sol --account <keystore> \
///                   --rpc-url mainnet --broadcast --verify
///
/// TODO before mainnet launch:
///   1. Mine vanity CREATE3 salts for deployer address
///   2. Set real alignment targets (token addresses, vault flags)
///   3. Set cypherPositionManager / cypherRouter if Cypher is live on mainnet
///   4. Set zamm address if ZAMM is live on mainnet
///   5. Set cfg.safe to the real Gnosis Safe address
contract DeployMainnet is DeployCore {

    address constant WETH       = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant V4_PM      = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address constant V2_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;

    function run() public {
        vm.startBroadcast();
        deploy(msg.sender, _mainnetConfig());
        vm.stopBroadcast();
    }

    function _mainnetConfig() internal pure returns (NetworkConfig memory cfg) {
        AlignmentTargetConfig[] memory targets = new AlignmentTargetConfig[](0);
        // TODO: populate targets

        cfg.chainId          = 1;
        cfg.weth             = WETH;
        cfg.v4PoolManager    = V4_PM;
        cfg.v3Factory        = V3_FACTORY;
        cfg.v2Factory        = V2_FACTORY;
        cfg.cypherPositionManager = address(0); // TODO
        cfg.cypherRouter     = address(0);      // TODO
        cfg.zamm             = address(0);      // TODO
        cfg.zrouter          = address(0);
        cfg.safe             = address(0);      // TODO: real Safe address
        cfg.saltMasterRegistry = bytes32(0);    // TODO: mine vanity salts
        cfg.saltTreasury       = bytes32(0);
        cfg.saltQueueManager   = bytes32(0);
        cfg.saltGlobalMsgReg   = bytes32(0);
        cfg.saltAlignmentReg   = bytes32(0);
        cfg.saltComponentReg   = bytes32(0);
        cfg.priceDeviationBps  = 500;  // 5% — mainnet liquidity is deeper
        cfg.twapSeconds        = 1800;
        cfg.zrouterFee         = 3000;
        cfg.zrouterTickSpacing = 60;
        cfg.alignmentTargets   = targets;
        cfg.jsonOutputPath     = "./deployments/mainnet.json";
    }
}
