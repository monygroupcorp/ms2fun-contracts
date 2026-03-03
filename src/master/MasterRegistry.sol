// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MasterRegistry
 * @notice Standard ERC1967 proxy for MasterRegistryV1 (UUPS upgradeable)
 * @dev Stores the implementation address at the ERC1967 implementation slot
 *      and delegates all calls. Upgrades are handled by the UUPS implementation.
 */
contract MasterRegistry {
    error InitializationFailed();

    /// @dev ERC1967 implementation slot: keccak256("eip1967.proxy.implementation") - 1
    bytes32 internal constant _ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /**
     * @dev Sets the implementation and optionally initializes via delegatecall.
     * @param implementation The implementation contract address
     * @param _data Initialization calldata (e.g. abi.encodeCall(initialize, (owner)))
     */
    constructor(address implementation, bytes memory _data) {
        assembly {
            sstore(_ERC1967_IMPLEMENTATION_SLOT, implementation)
        }
        if (_data.length > 0) {
            (bool success, bytes memory returndata) = implementation.delegatecall(_data);
            if (!success) {
                if (returndata.length > 0) {
                    assembly {
                        revert(add(32, returndata), mload(returndata))
                    }
                } else {
                    revert InitializationFailed();
                }
            }
        }
    }

    /**
     * @dev Delegates all calls to the implementation stored at the ERC1967 slot.
     */
    fallback() external payable {
        assembly {
            let impl := sload(_ERC1967_IMPLEMENTATION_SLOT)
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    receive() external payable {
        assembly {
            let impl := sload(_ERC1967_IMPLEMENTATION_SLOT)
            let result := delegatecall(gas(), impl, 0, 0, 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}
