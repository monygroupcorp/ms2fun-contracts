// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IMasterRegistry} from "../../src/master/interfaces/IMasterRegistry.sol";

/**
 * @title MockFactory
 * @notice Mock factory contract for testing
 */
contract MockFactory {
    IMasterRegistry public masterRegistry;
    address public instanceTemplate;

    constructor(address _masterRegistry) {
        masterRegistry = IMasterRegistry(_masterRegistry);
    }

    function registerInstance(
        address instance,
        address creator,
        string memory name,
        string memory metadataURI,
        address vault,
        address hook
    ) external {
        masterRegistry.registerInstance(
            instance,
            address(this),
            creator,
            name,
            metadataURI,
            vault
        );
    }
}

