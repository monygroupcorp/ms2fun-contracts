// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

enum Operation { Call, DelegateCall }

interface IAvatar {
    function execTransactionFromModule(
        address to, uint256 value, bytes memory data,
        Operation operation
    ) external returns (bool success);
}
