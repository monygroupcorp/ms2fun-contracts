// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "solady/auth/Ownable.sol";

/**
 * @title LaunchManager
 * @notice Holds graduation presets for ERC404Factory instances.
 *         Each preset defines the economic parameters for a bonding curve.
 */
contract LaunchManager is Ownable {
    error InvalidProtocol();
    error InvalidTargetETH();
    error InvalidUnitPerNFT();
    error InvalidReserveBps();
    error InvalidCurveComputer();
    error PresetNotActive();

    /// @notice Economic parameters for a graduation preset.
    struct Preset {
        uint256 targetETH;
        uint256 unitPerNFT;
        uint256 liquidityReserveBps;
        address curveComputer;      // DAO-approved ICurveComputer for this preset
        bool active;
    }

    mapping(uint256 => Preset) private _presets;

    event PresetUpdated(uint256 indexed presetId, uint256 targetETH, address curveComputer, bool active);

    constructor(address _protocol) {
        if (_protocol == address(0)) revert InvalidProtocol();
        _initializeOwner(_protocol);
    }

    /// @notice Set or update a graduation preset. Only callable by owner (DAO).
    function setPreset(uint256 presetId, Preset calldata preset) external onlyOwner {
        if (preset.targetETH == 0) revert InvalidTargetETH();
        if (preset.unitPerNFT == 0) revert InvalidUnitPerNFT();
        if (preset.liquidityReserveBps == 0 || preset.liquidityReserveBps >= 10000) revert InvalidReserveBps();
        if (preset.curveComputer == address(0)) revert InvalidCurveComputer();
        _presets[presetId] = preset;
        emit PresetUpdated(presetId, preset.targetETH, preset.curveComputer, preset.active);
    }

    /// @notice Get a graduation preset. Reverts if not active.
    function getPreset(uint256 presetId) external view returns (Preset memory) {
        Preset memory p = _presets[presetId];
        if (!p.active) revert PresetNotActive();
        return p;
    }
}
