// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAvatar, Operation} from "../../src/dao/interfaces/IAvatar.sol";

contract MockSafe is IAvatar {
    struct Execution {
        address to;
        uint256 value;
        bytes data;
        Operation operation;
    }

    Execution[] public executions;

    receive() external payable {}

    function execTransactionFromModule(
        address to,
        uint256 value,
        bytes memory data,
        Operation operation
    ) external returns (bool success) {
        executions.push(Execution({to: to, value: value, data: data, operation: operation}));

        if (value > 0) {
            (success,) = to.call{value: value}(data);
        } else if (data.length > 0) {
            (success,) = to.call(data);
        } else {
            success = true;
        }
    }

    function executionCount() external view returns (uint256) {
        return executions.length;
    }

    function enableModule(address) external {
        // No-op for testing — in real Gnosis Safe this registers a module
    }
}
