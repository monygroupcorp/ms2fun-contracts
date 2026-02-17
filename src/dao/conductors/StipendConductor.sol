// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

contract StipendConductor {
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
        require(msg.sender == dao, "!dao");
        _;
    }

    constructor(address _dao, address _beneficiary, uint256 _amount, uint256 _interval) {
        require(_dao != address(0), "invalid dao");
        require(_beneficiary != address(0), "invalid beneficiary");
        require(_amount > 0, "zero amount");
        require(_interval > 0, "zero interval");
        dao = _dao;
        beneficiary = _beneficiary;
        amount = _amount;
        interval = _interval;
    }

    function execute() external {
        require(!revoked, "revoked");
        require(lastExecuted == 0 || block.timestamp >= lastExecuted + interval, "too early");
        lastExecuted = block.timestamp;
        (bool success,) = dao.call(
            abi.encodeWithSignature("executeStipend(address,uint256)", beneficiary, amount)
        );
        require(success, "stipend transfer failed");
        emit StipendExecuted(beneficiary, amount, block.timestamp);
    }

    function revoke() external onlyDAO {
        revoked = true;
        emit StipendRevoked(block.timestamp);
    }

    function updateAmount(uint256 _amount) external onlyDAO {
        require(_amount > 0, "zero amount");
        emit StipendAmountUpdated(amount, _amount);
        amount = _amount;
    }

    function updateBeneficiary(address _beneficiary) external onlyDAO {
        require(_beneficiary != address(0), "invalid beneficiary");
        emit BeneficiaryUpdated(beneficiary, _beneficiary);
        beneficiary = _beneficiary;
    }

    function nextExecutionTime() external view returns (uint256) {
        if (lastExecuted == 0) return 0;
        return lastExecuted + interval;
    }
}
