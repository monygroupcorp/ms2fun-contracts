// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAlgebraFactory, IAlgebraPool, IAlgebraNFTPositionManager} from "../../interfaces/algebra/IAlgebra.sol";
import {UltraAlignmentCypherVault} from "../../vaults/cypher/UltraAlignmentCypherVault.sol";

/// @title CypherLiquidityDeployerModule
/// @notice Called by ERC404CypherBondingInstance at graduation.
///         Creates Algebra pool, mints LP to vault, registers benefactor.
contract CypherLiquidityDeployerModule {

    struct DeployParams {
        uint256 ethReserve;
        uint256 tokenReserve;
        uint160 sqrtPriceX96;          // initial pool price
        uint256 graduationFeeBps;
        uint256 creatorGraduationFeeBps;
        address protocolTreasury;
        address factoryCreator;
        address token;                  // ERC404 token address (bonding instance)
        address weth;                   // WETH address
        address vault;                  // UltraAlignmentCypherVault address
        address algebraFactory;
        address positionManager;
        address instance;               // bonding instance (benefactor to register)
    }

    // Full-range ticks for tick spacing 60: floor(887272/60)*60 = 887220
    int24 public constant TICK_LOWER = -887220;
    int24 public constant TICK_UPPER = 887220;

    event LiquidityDeployed(
        address indexed vault, address pool, uint256 tokenId,
        uint256 ethToLP, uint256 tokenToLP
    );
    event GraduationFeePaid(address indexed treasury, uint256 amount);
    event CreatorGraduationFeePaid(address indexed creator, uint256 amount);

    /// @notice Deploy Algebra pool liquidity and register with vault.
    /// @dev Caller must have pre-transferred tokenReserve to this contract.
    ///      ETH must equal p.ethReserve exactly.
    function deployLiquidity(DeployParams calldata p)
        external payable
        returns (uint256 tokenId, address pool)
    {
        require(msg.value == p.ethReserve, "ETH mismatch");
        require(p.token != address(0) && p.vault != address(0), "Invalid params");

        // ── Compute fee splits ──
        uint256 protocolFee;
        uint256 creatorFee;
        if (p.graduationFeeBps > 0 && p.protocolTreasury != address(0)) {
            protocolFee = p.ethReserve * p.graduationFeeBps / 10000;
            if (p.creatorGraduationFeeBps > 0 && p.factoryCreator != address(0)) {
                creatorFee = p.ethReserve * p.creatorGraduationFeeBps / 10000;
            }
        }
        uint256 ethToLP = p.ethReserve - protocolFee - creatorFee;

        // ── Wrap ETH to WETH for LP ──
        address weth = p.weth;
        (bool depositOk,) = weth.call{value: ethToLP}(abi.encodeWithSignature("deposit()"));
        require(depositOk, "WETH deposit failed");

        // ── Create Algebra pool ──
        pool = IAlgebraFactory(p.algebraFactory).createPool(p.token, weth, "");

        // ── Initialize pool price ──
        IAlgebraPool(pool).initialize(p.sqrtPriceX96);

        // ── Determine token ordering ──
        bool tokenIsZero = p.token < weth;
        (address token0, address token1) = tokenIsZero
            ? (p.token, weth)
            : (weth, p.token);
        uint256 amount0 = tokenIsZero ? p.tokenReserve : ethToLP;
        uint256 amount1 = tokenIsZero ? ethToLP : p.tokenReserve;

        // ── Approve positionManager ──
        IERC20(p.token).approve(p.positionManager, p.tokenReserve);
        IERC20(weth).approve(p.positionManager, ethToLP);

        // ── Mint LP position to vault ──
        uint128 liquidity;
        (tokenId, liquidity,,) = IAlgebraNFTPositionManager(p.positionManager).mint(
            IAlgebraNFTPositionManager.MintParams({
                token0: token0,
                token1: token1,
                deployer: address(0),
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: p.vault,
                deadline: block.timestamp
            })
        );
        require(liquidity > 0, "Zero liquidity");

        // ── Register position with vault ──
        UltraAlignmentCypherVault(payable(p.vault)).registerPosition(
            tokenId, pool, tokenIsZero, p.instance, ethToLP
        );

        // ── Pay graduation fees ──
        if (protocolFee > 0) {
            SafeTransferLib.safeTransferETH(p.protocolTreasury, protocolFee);
            emit GraduationFeePaid(p.protocolTreasury, protocolFee);
        }
        if (creatorFee > 0) {
            SafeTransferLib.safeTransferETH(p.factoryCreator, creatorFee);
            emit CreatorGraduationFeePaid(p.factoryCreator, creatorFee);
        }

        emit LiquidityDeployed(p.vault, pool, tokenId, ethToLP, p.tokenReserve);
    }

    receive() external payable {}
}
