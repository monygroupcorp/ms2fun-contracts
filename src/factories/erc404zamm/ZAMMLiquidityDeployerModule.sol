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
        address protocolTreasury;
        address token;           // ERC404 token (instance address)
        address instance;        // same as token; LP recipient
        address zamm;            // ZAMM singleton
        uint256 feeOrHook;       // ZAMM pool feeOrHook (e.g. 30 = 0.3%)
    }

    struct PoolResult {
        uint256 ethForPool;
        uint256 graduationFee;
        bool ethIsToken0;
        ZAMMPoolKey poolKey;
        uint256 liquidity;
    }

    event LiquidityDeployed(address indexed zamm, address token0, address token1, uint256 liquidity);
    event GraduationFeePaid(address indexed treasury, uint256 amount);

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
        PoolResult memory r = _deployPool(p);
        poolKey = r.poolKey;
        liquidity = r.liquidity;
        _payFees(p, r);
    }

    function _deployPool(DeployParams calldata p) private returns (PoolResult memory r) {
        // Compute fee splits
        if (p.graduationFeeBps > 0 && p.protocolTreasury != address(0)) {
            r.graduationFee = (p.ethReserve * p.graduationFeeBps) / 10000;
        }
        r.ethForPool = p.ethReserve - r.graduationFee;
        require(r.ethForPool > 0, "No ETH for pool");
        require(p.tokenReserve > 0, "No tokens for pool");

        r.ethIsToken0 = address(0) < p.token;
        r.poolKey = ZAMMPoolKey({
            id0: 0,
            id1: 0,
            token0: r.ethIsToken0 ? address(0) : p.token,
            token1: r.ethIsToken0 ? p.token : address(0),
            feeOrHook: p.feeOrHook
        });

        IERC20(p.token).approve(p.zamm, p.tokenReserve);

        IZAMM.PoolKey memory zammKey = IZAMM.PoolKey({
            id0: 0, id1: 0,
            token0: r.poolKey.token0,
            token1: r.poolKey.token1,
            feeOrHook: p.feeOrHook
        });

        uint256 a0 = r.ethIsToken0 ? r.ethForPool : p.tokenReserve;
        uint256 a1 = r.ethIsToken0 ? p.tokenReserve : r.ethForPool;
        (,, r.liquidity) = IZAMM(p.zamm).addLiquidity{value: r.ethForPool}(
            zammKey, a0, a1, 0, 0, p.instance, type(uint256).max
        );
    }

    function _payFees(DeployParams calldata p, PoolResult memory r) private {
        if (r.graduationFee > 0) {
            SafeTransferLib.safeTransferETH(p.protocolTreasury, r.graduationFee);
            emit GraduationFeePaid(p.protocolTreasury, r.graduationFee);
        }
        emit LiquidityDeployed(p.zamm, r.poolKey.token0, r.poolKey.token1, r.liquidity);
    }

    receive() external payable {}
}
