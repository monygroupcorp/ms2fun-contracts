// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

contract StipendConductor {
    // ============ Custom Errors ============

    error InvalidAddress();
    error Unauthorized();
    error ZeroAmount();
    error ZeroInterval();
    error Revoked();
    error TooEarly();
    error StipendTransferFailed();

    address public immutable dao;
    address public beneficiary;
    uint256 public amount;
    uint256 public interval;
    uint256 public lastExecuted;
    bool public revoked;

    event StipendExecuted(address indexed beneficiary, uint256 amount, uint256 timestamp);
    event StipendRevoked(uint256 timestamp);
    event StipendAmountUpdated(uint256 oldAmount, uint256 newAmount);
    event BeneficiaryUpdated(address indexed oldBeneficiary, address indexed newBeneficiary);

    modifier onlyDAO() {
        if (msg.sender != dao) revert Unauthorized();
        _;
    }

    constructor(address _dao, address _beneficiary, uint256 _amount, uint256 _interval) {
        if (_dao == address(0)) revert InvalidAddress();
        if (_beneficiary == address(0)) revert InvalidAddress();
        if (_amount == 0) revert ZeroAmount();
        if (_interval == 0) revert ZeroInterval();
        dao = _dao;
        beneficiary = _beneficiary;
        amount = _amount;
        interval = _interval;
    }

    function execute() external {
        if (revoked) revert Revoked();
        if (lastExecuted != 0 && block.timestamp < lastExecuted + interval) revert TooEarly();
        lastExecuted = block.timestamp;
        (bool success,) = dao.call(
            abi.encodeWithSignature("executeStipend(address,uint256)", beneficiary, amount)
        );
        if (!success) revert StipendTransferFailed();
        emit StipendExecuted(beneficiary, amount, block.timestamp);
    }

    function revoke() external onlyDAO {
        revoked = true;
        emit StipendRevoked(block.timestamp);
    }

    function updateAmount(uint256 _amount) external onlyDAO {
        if (_amount == 0) revert ZeroAmount();
        emit StipendAmountUpdated(amount, _amount);
        amount = _amount;
    }

    function updateBeneficiary(address _beneficiary) external onlyDAO {
        if (_beneficiary == address(0)) revert InvalidAddress();
        emit BeneficiaryUpdated(beneficiary, _beneficiary);
        beneficiary = _beneficiary;
    }

    function nextExecutionTime() external view returns (uint256) {
        if (lastExecuted == 0) return 0;
        return lastExecuted + interval;
    }
}
