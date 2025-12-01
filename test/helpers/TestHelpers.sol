// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MasterRegistry} from "../../src/master/MasterRegistry.sol";
import {MasterRegistryV1} from "../../src/master/MasterRegistryV1.sol";

/**
 * @title TestHelpers
 * @notice Helper functions for testing MasterRegistry
 */
library TestHelpers {
    /**
     * @notice Get the actual proxy address from MasterRegistry wrapper
     * @dev MasterRegistry stores the proxy address in storage slot 0
     * @dev This is needed because MasterRegistry is a wrapper that forwards calls
     *      Using the proxy directly preserves msg.sender correctly
     */
    function getProxyAddress(MasterRegistry wrapper) internal view returns (address) {
        return wrapper.getProxyAddress();
    }

    /**
     * @notice Cast MasterRegistry wrapper to MasterRegistryV1 for direct calls
     * @dev Note: This goes through the wrapper, so msg.sender will be the wrapper
     *      Use getProxyAddress() + cast to MasterRegistryV1 for proper msg.sender
     */
    function asV1(MasterRegistry wrapper) internal pure returns (MasterRegistryV1) {
        return MasterRegistryV1(address(wrapper));
    }

    /**
     * @notice Get MasterRegistryV1 interface from proxy address
     * @dev Use this when you need proper msg.sender preservation
     */
    function getV1FromProxy(address proxy) internal pure returns (MasterRegistryV1) {
        return MasterRegistryV1(proxy);
    }
}

