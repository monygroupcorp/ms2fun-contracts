// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {GrandCentral} from "../src/dao/GrandCentral.sol";
import {IGrandCentral} from "../src/dao/interfaces/IGrandCentral.sol";

contract RegisterConductors is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address daoAddress = vm.envAddress("DAO_ADDRESS");
        address shareOfferingAddress = vm.envAddress("SHARE_OFFERING_ADDRESS");
        address stipendConductorAddress = vm.envAddress("STIPEND_CONDUCTOR_ADDRESS");

        GrandCentral dao = GrandCentral(daoAddress);

        // Build setConductors calldata: both conductors get manager permission (2)
        address[] memory conductors = new address[](2);
        conductors[0] = shareOfferingAddress;
        conductors[1] = stipendConductorAddress;

        uint256[] memory permissions = new uint256[](2);
        permissions[0] = 2; // manager
        permissions[1] = 2; // manager

        // Proposal targets/values/calldatas — single self-call to setConductors
        address[] memory targets = new address[](1);
        targets[0] = daoAddress;

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            GrandCentral.setConductors.selector,
            conductors,
            permissions
        );

        vm.startBroadcast(deployerPrivateKey);

        // Submit proposal (self-sponsors if sender has >= sponsorThreshold shares)
        uint256 proposalId = dao.submitProposal(
            targets,
            values,
            calldatas,
            0, // no expiration
            "Register ShareOffering and StipendConductor as managers"
        );
        console.log("Proposal submitted with ID:", proposalId);

        // Vote yes (founder auto-votes after self-sponsoring)
        dao.submitVote(uint32(proposalId), true);
        console.log("Voted YES on proposal", proposalId);

        vm.stopBroadcast();

        console.log("");
        console.log("=== NEXT STEPS ===");
        console.log("1. Wait for voting period (1 day) + grace period (1 day)");
        console.log("2. Run ProcessProposal.s.sol with PROPOSAL_ID=%s", proposalId);
    }
}
