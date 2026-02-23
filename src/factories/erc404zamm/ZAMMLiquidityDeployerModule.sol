// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IERC20} from "../../shared/interfaces/IERC20.sol";

interface IZAMM {
    struct PoolKey {
        uint256 id0;
        uint256 id1;
        address token0;
        address token1;
        uint256 feeOrHook;
    }

    function addLiquidity(
        PoolKey calldata poolKey,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amount0, uint256 amount1, uint256 liquidity);
}

/**
 * @title ZAMMLiquidityDeployerModule
 * @notice Singleton called by ERC404ZAMMBondingInstance at graduation.
 *         Receives ETH + tokens, deploys ZAMM liquidity, pays graduation fees.
 */
contract ZAMMLiquidityDeployerModule {
    // Re-export for caller to store
    struct ZAMMPoolKey {
        uint256 id0;
        uint256 id1;
        address token0;
        address token1;
        uint256 feeOrHook;
    }

    struct DeployParams {
        uint256 ethReserve;
        uint256 tokenReserve;
        uint256 graduationFeeBps;
        uint256 creatorGraduationFeeBps;
        uint256 polBps;          // reserved for future use, pass 0
        address protocolTreasury;
        address factoryCreator;
        address token;           // ERC404 token (instance address)
        address instance;        // same as token; LP recipient
        address zamm;            // ZAMM singleton
        uint256 feeOrHook;       // ZAMM pool feeOrHook (e.g. 30 = 0.3%)
    }

    event LiquidityDeployed(address indexed zamm, address token0, address token1, uint256 liquidity);
    event GraduationFeePaid(address indexed treasury, uint256 amount);
    event CreatorGraduationFeePaid(address indexed creator, uint256 amount);

    /**
     * @notice Deploy ZAMM liquidity on behalf of an ERC404ZAMMBondingInstance.
     * @dev Caller must transfer tokenReserve tokens to this contract before calling.
     *      ETH must equal p.ethReserve exactly.
     * @return poolKey The ZAMM PoolKey for the deployed pool
     * @return liquidity LP units minted
     */
    function deployLiquidity(DeployParams calldata p)
        external
        payable
        returns (ZAMMPoolKey memory poolKey, uint256 liquidity)
    {
        require(msg.value == p.ethReserve, "ETH mismatch");

        // Compute fee splits
        uint256 graduationFee;
        uint256 creatorCut;
        if (p.graduationFeeBps > 0 && p.protocolTreasury != address(0)) {
            graduationFee = (p.ethReserve * p.graduationFeeBps) / 10000;
            if (p.creatorGraduationFeeBps > 0 && p.factoryCreator != address(0)) {
                creatorCut = (p.ethReserve * p.creatorGraduationFeeBps) / 10000;
                if (creatorCut > graduationFee) creatorCut = graduationFee;
            }
        }

        uint256 ethForPool = p.ethReserve - graduationFee;
        uint256 tokensForPool = p.tokenReserve;

        require(ethForPool > 0, "No ETH for pool");
        require(tokensForPool > 0, "No tokens for pool");

        // Determine token ordering: address(0) = ETH sorts lowest
        bool ethIsToken0 = address(0) < p.token;

        poolKey = ZAMMPoolKey({
            id0: 0,
            id1: 0,
            token0: ethIsToken0 ? address(0) : p.token,
            token1: ethIsToken0 ? p.token : address(0),
            feeOrHook: p.feeOrHook
        });

        // Approve ZAMM to pull our tokens
        IERC20(p.token).approve(p.zamm, tokensForPool);

        // Deploy liquidity: ETH sent as msg.value
        uint256 amount0Desired = ethIsToken0 ? ethForPool : tokensForPool;
        uint256 amount1Desired = ethIsToken0 ? tokensForPool : ethForPool;

        IZAMM.PoolKey memory zammKey = IZAMM.PoolKey({
            id0: poolKey.id0,
            id1: poolKey.id1,
            token0: poolKey.token0,
            token1: poolKey.token1,
            feeOrHook: poolKey.feeOrHook
        });

        (,, liquidity) = IZAMM(p.zamm).addLiquidity{value: ethForPool}(
            zammKey,
            amount0Desired,
            amount1Desired,
            0, // no slippage protection at graduation (deterministic)
            0,
            p.instance, // LP goes to the bonding instance
            type(uint256).max
        );

        // Pay graduation fees (from remaining ETH after pool deployment)
        if (graduationFee > 0) {
            uint256 protocolCut = graduationFee - creatorCut;
            if (protocolCut > 0) {
                SafeTransferLib.safeTransferETH(p.protocolTreasury, protocolCut);
                emit GraduationFeePaid(p.protocolTreasury, protocolCut);
            }
            if (creatorCut > 0) {
                SafeTransferLib.safeTransferETH(p.factoryCreator, creatorCut);
                emit CreatorGraduationFeePaid(p.factoryCreator, creatorCut);
            }
        }

        emit LiquidityDeployed(p.zamm, poolKey.token0, poolKey.token1, liquidity);
    }

    receive() external payable {}
}
