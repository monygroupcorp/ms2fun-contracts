// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {GrandCentral} from "../src/dao/GrandCentral.sol";
import {IGrandCentral} from "../src/dao/interfaces/IGrandCentral.sol";

contract ProcessProposal is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address daoAddress = vm.envAddress("DAO_ADDRESS");
        uint32 proposalId = uint32(vm.envUint("PROPOSAL_ID"));

        GrandCentral dao = GrandCentral(daoAddress);

        // Read conductor addresses to reconstruct the original calldata
        address shareOfferingAddress = vm.envAddress("SHARE_OFFERING_ADDRESS");
        address stipendConductorAddress = vm.envAddress("STIPEND_CONDUCTOR_ADDRESS");

        address[] memory conductors = new address[](2);
        conductors[0] = shareOfferingAddress;
        conductors[1] = stipendConductorAddress;

        uint256[] memory permissions = new uint256[](2);
        permissions[0] = 2;
        permissions[1] = 2;

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

        // Check proposal state before processing
        IGrandCentral.ProposalState propState = dao.state(proposalId);
        console.log("Proposal state:", uint256(propState));
        require(propState == IGrandCentral.ProposalState.Ready, "Proposal not ready");

        vm.startBroadcast(deployerPrivateKey);

        dao.processProposal(proposalId, targets, values, calldatas);
        console.log("Proposal processed successfully");

        vm.stopBroadcast();

        // Verify
        console.log("");
        console.log("=== VERIFICATION ===");
        console.log("ShareOffering is manager:", dao.isManager(shareOfferingAddress));
        console.log("StipendConductor is manager:", dao.isManager(stipendConductorAddress));
    }
}
