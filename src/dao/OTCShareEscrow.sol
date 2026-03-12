// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IGrandCentral} from "./interfaces/IGrandCentral.sol";

/// @title OTCShareEscrow
/// @notice Standalone escrow for OTC share offers. Anyone can lock ERC20/ETH and request
///         DAO shares. The DAO claims offers through governance proposals.
contract OTCShareEscrow is ReentrancyGuard {
    // ============ Custom Errors ============

    error InvalidAddress();
    error InvalidAmount();
    error InvalidExpiration();
    error OfferExists();
    error NoOffer();
    error OfferExpired();
    error Unauthorized();

    // ============ Structs ============

    struct Offer {
        uint256 amount;
        uint256 sharesRequested;
        uint40 expiration;
    }

    struct OfferRef {
        address proposer;
        address token;
    }

    struct ActiveOfferView {
        address proposer;
        address token;
        uint256 amount;
        uint256 sharesRequested;
        uint40 expiration;
    }

    // ============ Constants ============

    uint40 public constant MIN_DURATION = 7 days;

    // ============ Immutables ============

    address public immutable dao;
    address public immutable safe;

    // ============ State ============

    mapping(address proposer => mapping(address token => Offer)) public offers;
    OfferRef[] public offerRefs;

    // ============ Events ============

    event OfferCreated(
        address indexed proposer, address indexed token,
        uint256 amount, uint256 sharesRequested, uint40 expiration
    );
    event OfferCancelled(address indexed proposer, address indexed token, uint256 amount);
    event OfferClaimed(
        address indexed proposer, address indexed token,
        uint256 amount, uint256 sharesRequested
    );

    // ============ Constructor ============

    constructor(address _dao) {
        if (_dao == address(0)) revert InvalidAddress();
        dao = _dao;
        safe = IGrandCentral(_dao).safe();
    }
}
