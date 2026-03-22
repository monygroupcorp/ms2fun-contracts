// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {GrandCentral} from "../src/dao/GrandCentral.sol";
import {ShareOffering} from "../src/dao/conductors/ShareOffering.sol";
import {StipendConductor} from "../src/dao/conductors/StipendConductor.sol";

contract DeployDAO is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address safeAddress = vm.envAddress("SAFE_ADDRESS");
        address founder = vm.envAddress("FOUNDER_ADDRESS");
        uint256 stipendAmount = vm.envOr("STIPEND_AMOUNT", uint256(3.15 ether));

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy GrandCentral DAO
        GrandCentral dao = new GrandCentral(
            safeAddress,
            founder,
            1000,       // initial shares
            1 days,     // voting period
            1 days,     // grace period
            0,          // quorum percent (no minimum for bootstrap)
            1,          // sponsor threshold (1 share to self-sponsor)
            66          // min retention (fail if >34% ragequit)
        );
        console.log("GrandCentral deployed at:", address(dao));

        // 2. Deploy ShareOffering conductor
        ShareOffering shareOffering = new ShareOffering(address(dao));
        console.log("ShareOffering deployed at:", address(shareOffering));

        // 3. Deploy StipendConductor
        StipendConductor stipendConductor = new StipendConductor(
            address(dao),
            founder,
            stipendAmount,
            30 days
        );
        console.log("StipendConductor deployed at:", address(stipendConductor));

        vm.stopBroadcast();

        console.log("");
        console.log("=== POST-DEPLOY CHECKLIST ===");
        console.log("1. In Safe UI: Settings > Modules > Add Module > paste:", address(dao));
        console.log("2. Fund Safe with initial ETH for stipend payouts");
        console.log("3. Run RegisterConductors.s.sol with:");
        console.log("   DAO_ADDRESS=%s", address(dao));
        console.log("   SHARE_OFFERING_ADDRESS=%s", address(shareOffering));
        console.log("   STIPEND_CONDUCTOR_ADDRESS=%s", address(stipendConductor));
        console.log("4. Wait 2 days (1 day vote + 1 day grace)");
        console.log("5. Run ProcessProposal.s.sol with PROPOSAL_ID=1");
        console.log("6. Verify: dao.isManager(shareOffering) and dao.isManager(stipendConductor)");
    }
}
