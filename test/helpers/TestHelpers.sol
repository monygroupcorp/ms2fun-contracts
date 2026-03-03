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
     * @notice Get the proxy address from MasterRegistry
     * @dev MasterRegistry IS the ERC1967 proxy, so just return its address
     */
    function getProxyAddress(MasterRegistry wrapper) internal pure returns (address) {
        return address(wrapper);
    }

    /**
     * @notice Cast MasterRegistry to MasterRegistryV1 for direct calls
     */
    function asV1(MasterRegistry wrapper) internal pure returns (MasterRegistryV1) {
        return MasterRegistryV1(address(wrapper));
    }

    /**
     * @notice Get MasterRegistryV1 interface from proxy address
     */
    function getV1FromProxy(address proxy) internal pure returns (MasterRegistryV1) {
        return MasterRegistryV1(proxy);
    }
}
