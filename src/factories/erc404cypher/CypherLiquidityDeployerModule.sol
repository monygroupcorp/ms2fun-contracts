// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAlgebraFactory, IAlgebraPool, IAlgebraNFTPositionManager} from "../../interfaces/algebra/IAlgebra.sol";
import {CypherAlignmentVault} from "../../vaults/cypher/CypherAlignmentVault.sol";

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
        address vault;                  // CypherAlignmentVault address
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

    struct PoolSetupResult {
        uint256 tokenId;
        address pool;
        uint256 ethToLP;
        uint256 protocolFee;
        uint256 creatorFee;
        bool tokenIsZero;
    }

    /// @notice Deploy Algebra pool liquidity and register with vault.
    /// @dev Caller must have pre-transferred tokenReserve to this contract.
    ///      ETH must equal p.ethReserve exactly.
    function deployLiquidity(DeployParams calldata p)
        external payable
        returns (uint256 tokenId, address pool)
    {
        require(msg.value == p.ethReserve, "ETH mismatch");
        require(p.token != address(0) && p.vault != address(0), "Invalid params");

        PoolSetupResult memory r = _setupPool(p);
        tokenId = r.tokenId;
        pool = r.pool;
        _postMint(p, r);
    }

    function _setupPool(DeployParams calldata p) private returns (PoolSetupResult memory r) {
        // ── Compute fee splits ──
        if (p.graduationFeeBps > 0 && p.protocolTreasury != address(0)) {
            r.protocolFee = p.ethReserve * p.graduationFeeBps / 10000;
            if (p.creatorGraduationFeeBps > 0 && p.factoryCreator != address(0)) {
                r.creatorFee = p.ethReserve * p.creatorGraduationFeeBps / 10000;
            }
        }
        r.ethToLP = p.ethReserve - r.protocolFee - r.creatorFee;

        // ── Wrap ETH to WETH for LP ──
        address weth = p.weth;
        (bool depositOk,) = weth.call{value: r.ethToLP}(abi.encodeWithSignature("deposit()"));
        require(depositOk, "WETH deposit failed");

        // ── Create Algebra pool ──
        r.pool = IAlgebraFactory(p.algebraFactory).createPool(p.token, weth, "");
        IAlgebraPool(r.pool).initialize(p.sqrtPriceX96);

        // ── Determine token ordering and amounts ──
        r.tokenIsZero = p.token < weth;
        (address token0, address token1) = r.tokenIsZero ? (p.token, weth) : (weth, p.token);
        uint256 amount0 = r.tokenIsZero ? p.tokenReserve : r.ethToLP;
        uint256 amount1 = r.tokenIsZero ? r.ethToLP : p.tokenReserve;

        // ── Approve and mint LP ──
        IERC20(p.token).approve(p.positionManager, p.tokenReserve);
        IERC20(weth).approve(p.positionManager, r.ethToLP);

        uint128 liquidity;
        (r.tokenId, liquidity,,) = IAlgebraNFTPositionManager(p.positionManager).mint(
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
    }

    function _postMint(DeployParams calldata p, PoolSetupResult memory r) private {
        CypherAlignmentVault(payable(p.vault)).registerPosition(
            r.tokenId, r.pool, r.tokenIsZero, p.instance, r.ethToLP
        );
        if (r.protocolFee > 0) {
            SafeTransferLib.safeTransferETH(p.protocolTreasury, r.protocolFee);
            emit GraduationFeePaid(p.protocolTreasury, r.protocolFee);
        }
        if (r.creatorFee > 0) {
            SafeTransferLib.safeTransferETH(p.factoryCreator, r.creatorFee);
            emit CreatorGraduationFeePaid(p.factoryCreator, r.creatorFee);
        }
        emit LiquidityDeployed(p.vault, r.pool, r.tokenId, r.ethToLP, p.tokenReserve);
    }

    receive() external payable {}
}
