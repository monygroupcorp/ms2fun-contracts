// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IRevenueConductorDAO {
    function shares(address member) external view returns (uint256);
    function safe() external view returns (address);
    function fundRagequitPool(uint256 amount) external;
    function fundClaimsPool(uint256 amount) external;
}

interface IRevenueConductorTreasury {
    function routeToDAO(address safe, uint256 amount) external;
}

contract RevenueConductor {
    // ============ Custom Errors ============

    error InvalidAddress();
    error Unauthorized();
    error BpsMustSumTo10000();
    error NothingToRoute();

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
        if (_dao == address(0)) revert InvalidAddress();
        if (_treasury == address(0)) revert InvalidAddress();
        if (_dividendBps + _ragequitBps + _reserveBps != 10000) revert BpsMustSumTo10000();

        dao = _dao;
        treasury = _treasury;
        dividendBps = _dividendBps;
        ragequitBps = _ragequitBps;
        reserveBps = _reserveBps;
    }

    function sweep() external {
        if (IRevenueConductorDAO(dao).shares(msg.sender) == 0) revert Unauthorized();

        uint256 available = treasury.balance;
        if (available == 0) revert NothingToRoute();

        uint256 reserveAmount = available * reserveBps / 10000; // round down: favors routable pool
        uint256 routable = available - reserveAmount;

        uint256 dividendAmount;
        uint256 ragequitAmount;

        uint256 activeTotal = dividendBps + ragequitBps;
        if (activeTotal > 0) {
            dividendAmount = routable * dividendBps / activeTotal; // round down: dust absorbed by ragequit
            ragequitAmount = routable - dividendAmount;
        }

        // Route directly from treasury to Safe
        address safeAddr = IRevenueConductorDAO(dao).safe();
        IRevenueConductorTreasury(treasury).routeToDAO(safeAddr, routable);

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
        if (msg.sender != dao) revert Unauthorized();
        if (_dividendBps + _ragequitBps + _reserveBps != 10000) revert BpsMustSumTo10000();

        dividendBps = _dividendBps;
        ragequitBps = _ragequitBps;
        reserveBps = _reserveBps;

        emit RatioUpdated(_dividendBps, _ragequitBps, _reserveBps);
    }

    receive() external payable {}
}
