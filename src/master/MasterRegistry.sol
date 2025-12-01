// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LibClone} from "solady/utils/LibClone.sol";

/**
 * @title MasterRegistry
 * @notice Minimal ERC1967 proxy contract using Solady's LibClone
 * @dev This contract uses LibClone to deploy a minimal ERC1967 proxy
 *      Compatible with OpenZeppelin's ERC1967Proxy API
 */
contract MasterRegistry {
    /**
     * @dev Initializes the upgradeable proxy with an initial implementation
     * @param implementation The implementation contract address
     * @param _data Initialization data (encoded function call to initialize)
     */
    constructor(address implementation, bytes memory _data) {
        // Deploy minimal ERC1967 proxy using LibClone
        address proxy = LibClone.deployERC1967(implementation);
        
        // If initialization data is provided, call initialize function
        if (_data.length > 0) {
            (bool success, bytes memory returndata) = proxy.call(_data);
            if (!success) {
                if (returndata.length > 0) {
                    assembly {
                        let returndata_size := mload(returndata)
                        revert(add(32, returndata), returndata_size)
                    }
                } else {
                    revert("MasterRegistry: initialization failed");
                }
            }
        }
        
        // Store the proxy address - this contract will delegate to it
        assembly {
            sstore(0, proxy)
        }
    }
    
    /**
     * @dev Get the proxy address (for testing/debugging)
     */
    function getProxyAddress() external view returns (address proxy) {
        assembly {
            proxy := sload(0)
        }
    }
    
    /**
     * @dev Fallback function that forwards all calls to the proxy
     * @notice Uses regular call (not delegatecall) because the proxy has its own storage
     */
    fallback() external payable {
        address proxy;
        assembly {
            proxy := sload(0)
        }
        (bool success, bytes memory returndata) = proxy.call{value: msg.value}(msg.data);
        if (!success) {
            if (returndata.length > 0) {
                assembly {
                    let returndata_size := mload(returndata)
                    revert(add(32, returndata), returndata_size)
                }
            } else {
                revert("MasterRegistry: call failed");
            }
        }
        assembly {
            return(add(32, returndata), mload(returndata))
        }
    }
    
    receive() external payable {
        // For receive(), forward ETH to the proxy (no calldata)
        address proxy;
        assembly {
            proxy := sload(0)
        }
        (bool success, ) = proxy.call{value: msg.value}("");
        require(success, "MasterRegistry: receive failed");
    }
}

