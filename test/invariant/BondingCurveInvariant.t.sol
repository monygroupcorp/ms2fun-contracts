// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {ERC404BondingInstance} from "../../src/factories/erc404/ERC404BondingInstance.sol";
import {BondingCurveMath} from "../../src/factories/erc404/libraries/BondingCurveMath.sol";
import {CurveParamsComputer} from "../../src/factories/erc404/CurveParamsComputer.sol";
import {ILiquidityDeployerModule} from "../../src/interfaces/ILiquidityDeployerModule.sol";
import {BondingCurveHandler} from "./handlers/BondingCurveHandler.sol";

contract MockLiqDeployer is ILiquidityDeployerModule {
    function deployLiquidity(ILiquidityDeployerModule.DeployParams calldata) external payable override {}
    function metadataURI() external view override returns (string memory) { return ""; }
    function setMetadataURI(string calldata) external override {}
}

contract BondingCurveInvariantTest is StdInvariant, Test {
    ERC404BondingInstance public instance;
    BondingCurveHandler public handler;
    BondingCurveMath.Params curveParams;

    address public owner = address(0x1);
    address public protocolTreasury = address(0xFEE);
    address public mockVault = address(0xBEEF);
    address public mockMasterRegistry = address(0x400);
    address public mockGlobalMsgRegistry = address(0x700);
    address public mockLiquidityDeployer;

    address[] public actors;

    uint256 constant MAX_SUPPLY = 10_000_000 * 1e18;
    uint256 constant UNIT = 1_000_000 ether;
    uint256 constant LIQUIDITY_RESERVE_BPS = 1000;
    uint256 constant BONDING_FEE_BPS = 100; // 1%

    function setUp() public {
        mockLiquidityDeployer = address(new MockLiqDeployer());

        curveParams = BondingCurveMath.Params({
            initialPrice: 0.025 ether,
            quarticCoeff: 3 gwei,
            cubicCoeff: 1333333333,
            quadraticCoeff: 2 gwei,
            normalizationFactor: 1e7
        });

        vm.startPrank(owner);

        ERC404BondingInstance impl = new ERC404BondingInstance();
        instance = ERC404BondingInstance(payable(LibClone.clone(address(impl))));

        ERC404BondingInstance.BondingParams memory bp = ERC404BondingInstance.BondingParams({
            maxSupply: MAX_SUPPLY,
            unit: UNIT,
            liquidityReserveBps: LIQUIDITY_RESERVE_BPS,
            curve: curveParams
        });

        instance.initialize(owner, mockVault, bp, mockLiquidityDeployer, address(0));

        ERC404BondingInstance.ProtocolParams memory pp = ERC404BondingInstance.ProtocolParams({
            globalMessageRegistry: mockGlobalMsgRegistry,
            protocolTreasury: protocolTreasury,
            masterRegistry: mockMasterRegistry,
            bondingFeeBps: BONDING_FEE_BPS
        });
        instance.initializeProtocol(pp);
        instance.initializeMetadata("Test Token", "TEST", "");

        instance.setBondingOpenTime(block.timestamp + 1);
        vm.warp(block.timestamp + 2);
        instance.setBondingActive(true);

        vm.stopPrank();

        actors.push(address(0xA11CE));
        actors.push(address(0xB0B));
        actors.push(address(0xCAFE));
        actors.push(address(0xDEAD));

        handler = new BondingCurveHandler(instance, curveParams, actors);

        targetContract(address(handler));
    }

    // ── Invariant 1: reserve == address(instance).balance during active bonding ──
    // Bonding fees are sent to protocolTreasury immediately, so the contract's
    // ETH balance should always equal the tracked reserve.

    function invariant_reserveEqualsBalance() public view {
        if (instance.graduated()) return;
        assertEq(
            instance.reserve(),
            address(instance).balance,
            "reserve != address(this).balance during active bonding"
        );
    }

    // ── Invariant 2: totalBondingSupply <= maxSupply - liquidityReserve - freeMintAllocation * unit ──

    function invariant_bondingSupplyWithinCap() public view {
        uint256 cap = instance.maxSupply()
            - instance.liquidityReserve()
            - (instance.freeMintAllocation() * instance.unit());
        assertLe(
            instance.totalBondingSupply(),
            cap,
            "totalBondingSupply exceeds bonding cap"
        );
    }

    // ── Invariant 3: calculateRefund(supply, amount) <= calculateCost(supply - amount, amount) ──
    // Selling should never yield more ETH than what buying would cost at the same supply range.
    // Both use the same integral bounds, so with consistent rounding this should be exact equality,
    // but we assert <= to catch any rounding-direction bug that creates arbitrage.

    function invariant_noRoundingArbitrage() public view {
        uint256 supply = instance.totalBondingSupply();
        if (supply == 0) return;

        // Test at the current supply: selling `supply` tokens should refund <= buying them would cost
        // We test with a 1-unit chunk at the current supply level
        uint256 unit_ = instance.unit();
        if (supply < unit_) return;

        uint256 refund = BondingCurveMath.calculateRefund(curveParams, supply, unit_);
        uint256 cost = BondingCurveMath.calculateCost(curveParams, supply - unit_, unit_);

        assertLe(
            refund,
            cost,
            "refund exceeds cost at same supply range - rounding arbitrage possible"
        );
    }
}
