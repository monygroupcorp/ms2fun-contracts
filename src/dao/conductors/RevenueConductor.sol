// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IRevenueConductorDAO {
    function shares(address member) external view returns (uint256);
    function safe() external view returns (address);
    function fundRagequitPool(uint256 amount) external;
    function fundClaimsPool(uint256 amount) external;
}

interface IRevenueConductorTreasury {
    function withdrawETH(address to, uint256 amount) external;
}

contract RevenueConductor {
    address public immutable dao;
    address public immutable treasury;

    uint256 public dividendBps;
    uint256 public ragequitBps;
    uint256 public reserveBps;

    uint256 public totalRouted;

    event Swept(uint256 routed, uint256 dividend, uint256 ragequit, uint256 reserve);
    event RatioUpdated(uint256 dividendBps, uint256 ragequitBps, uint256 reserveBps);

    constructor(
        address _dao,
        address _treasury,
        uint256 _dividendBps,
        uint256 _ragequitBps,
        uint256 _reserveBps
    ) {
        require(_dao != address(0), "invalid dao");
        require(_treasury != address(0), "invalid treasury");
        require(_dividendBps + _ragequitBps + _reserveBps == 10000, "bps must sum to 10000");

        dao = _dao;
        treasury = _treasury;
        dividendBps = _dividendBps;
        ragequitBps = _ragequitBps;
        reserveBps = _reserveBps;
    }

    function sweep() external {
        require(IRevenueConductorDAO(dao).shares(msg.sender) > 0, "!shareholder");

        uint256 available = treasury.balance;
        require(available > 0, "nothing to route");

        uint256 reserveAmount = available * reserveBps / 10000;
        uint256 routable = available - reserveAmount;

        uint256 dividendAmount;
        uint256 ragequitAmount;

        uint256 activeTotal = dividendBps + ragequitBps;
        if (activeTotal > 0) {
            dividendAmount = routable * dividendBps / activeTotal;
            ragequitAmount = routable - dividendAmount;
        }

        // Withdraw from treasury to this contract
        IRevenueConductorTreasury(treasury).withdrawETH(address(this), routable);

        // Send ETH to Safe (pool accounting is checked against safe.balance)
        address safeAddr = IRevenueConductorDAO(dao).safe();
        (bool success,) = safeAddr.call{value: routable}("");
        require(success, "safe transfer failed");

        // Update pool accounting on the DAO
        if (dividendAmount > 0) {
            IRevenueConductorDAO(dao).fundClaimsPool(dividendAmount);
        }
        if (ragequitAmount > 0) {
            IRevenueConductorDAO(dao).fundRagequitPool(ragequitAmount);
        }

        totalRouted += routable;

        emit Swept(routable, dividendAmount, ragequitAmount, reserveAmount);
    }

    function setRatio(uint256 _dividendBps, uint256 _ragequitBps, uint256 _reserveBps) external {
        require(msg.sender == dao, "!dao");
        require(_dividendBps + _ragequitBps + _reserveBps == 10000, "bps must sum to 10000");

        dividendBps = _dividendBps;
        ragequitBps = _ragequitBps;
        reserveBps = _reserveBps;

        emit RatioUpdated(_dividendBps, _ragequitBps, _reserveBps);
    }

    receive() external payable {}
}
