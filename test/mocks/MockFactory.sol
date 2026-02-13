// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IMasterRegistry} from "../../src/master/interfaces/IMasterRegistry.sol";
import {IFactory} from "../../src/interfaces/IFactory.sol";

/**
 * @title MockFactory
 * @notice Mock factory contract for testing — implements IFactory so MasterRegistry accepts it
 */
contract MockFactory is IFactory {
    IMasterRegistry public masterRegistry;
    address public instanceTemplate;
    address public creator;
    address public protocol;

    constructor(address _creator, address _protocol) {
        creator = _creator;
        protocol = _protocol;
    }

    /// @notice Convenience constructor variant that also sets a registry
    function setMasterRegistry(address _masterRegistry) external {
        masterRegistry = IMasterRegistry(_masterRegistry);
    }

    function registerInstance(
        address instance,
        address _creator,
        string memory name,
        string memory metadataURI,
        address vault,
        address hook
    ) external {
        masterRegistry.registerInstance(
            instance,
            address(this),
            _creator,
            name,
            metadataURI,
            vault
        );
    }
}
