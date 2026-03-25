// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IERC20} from "../../shared/interfaces/IERC20.sol";
import {IAlignmentVault} from "../../interfaces/IAlignmentVault.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {ILiquidityDeployerModule} from "../../interfaces/ILiquidityDeployerModule.sol";
import {RevenueSplitLib} from "../../shared/libraries/RevenueSplitLib.sol";
import {Ownable} from "solady/auth/Ownable.sol";

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
 * @notice Singleton called by ERC404BondingInstance at graduation.
 *         Receives ETH + tokens, deploys ZAMM liquidity, pays graduation fees.
 */
contract ZAMMLiquidityDeployerModule is ILiquidityDeployerModule, Ownable {
    error ETHMismatch();
    error NoETHForPool();
    error NoTokensForPool();

    address public immutable zamm;
    uint256 public immutable feeOrHook;

    string private _metadataURI;

    // slither-disable-next-line missing-zero-check
    constructor(address _zamm, uint256 _feeOrHook) {
        zamm = _zamm;
        feeOrHook = _feeOrHook;
        _initializeOwner(msg.sender);
    }

    struct PoolResult {
        uint256 ethForPool;
        uint256 protocolFee;  // 1% of raise → protocol treasury
        uint256 vaultCut;     // 19% of raise → alignment vault
        bool ethIsToken0;
        address token0;
        address token1;
        uint256 liquidity;
    }

    event LiquidityDeployed(address indexed zamm, address token0, address token1, uint256 liquidity);
    event GraduationFeePaid(address indexed treasury, uint256 amount);
    event GraduationVaultContribution(address indexed vault, uint256 amount);

    /**
     * @notice Deploy ZAMM liquidity on behalf of an ERC404BondingInstance.
     * @dev Caller must transfer tokenReserve tokens to this contract before calling.
     *      ETH must equal p.ethReserve exactly.
     */
    // slither-disable-next-line reentrancy-events
    function deployLiquidity(DeployParams calldata p) external payable override {
        if (msg.value != p.ethReserve) revert ETHMismatch();
        PoolResult memory r = _deployPool(p);
        _payFees(p, r);
    }

    // slither-disable-next-line arbitrary-send-eth,unused-return
    function _deployPool(ILiquidityDeployerModule.DeployParams calldata p) private returns (PoolResult memory r) {
        RevenueSplitLib.Split memory s = RevenueSplitLib.split(p.ethReserve);
        r.protocolFee = s.protocolCut;
        r.vaultCut    = s.vaultCut;
        r.ethForPool  = s.remainder;
        if (r.ethForPool == 0) revert NoETHForPool();
        if (p.tokenReserve == 0) revert NoTokensForPool();

        r.ethIsToken0 = address(0) < p.token;
        r.token0 = r.ethIsToken0 ? address(0) : p.token;
        r.token1 = r.ethIsToken0 ? p.token : address(0);

        IERC20(p.token).approve(zamm, p.tokenReserve);

        IZAMM.PoolKey memory zammKey = IZAMM.PoolKey({
            id0: 0, id1: 0,
            token0: r.token0,
            token1: r.token1,
            feeOrHook: feeOrHook
        });

        uint256 a0 = r.ethIsToken0 ? r.ethForPool : p.tokenReserve;
        uint256 a1 = r.ethIsToken0 ? p.tokenReserve : r.ethForPool;
        uint256 a0Min = a0 * 99 / 100; // 1% slippage tolerance
        uint256 a1Min = a1 * 99 / 100;
        (,, r.liquidity) = IZAMM(zamm).addLiquidity{value: r.ethForPool}(
            zammKey, a0, a1, a0Min, a1Min, p.instance, block.timestamp
        );
    }

    // slither-disable-next-line arbitrary-send-eth,reentrancy-events
    function _payFees(ILiquidityDeployerModule.DeployParams calldata p, PoolResult memory r) private {
        // 1% → protocol treasury
        if (r.protocolFee > 0 && p.protocolTreasury != address(0)) {
            SafeTransferLib.safeTransferETH(p.protocolTreasury, r.protocolFee);
            emit GraduationFeePaid(p.protocolTreasury, r.protocolFee);
        }
        // 19% → alignment vault
        if (r.vaultCut > 0 && p.vault != address(0)) {
            IAlignmentVault(payable(p.vault)).receiveContribution{value: r.vaultCut}(
                Currency.wrap(address(0)), r.vaultCut, p.instance
            );
            emit GraduationVaultContribution(p.vault, r.vaultCut);
        }
        emit LiquidityDeployed(zamm, r.token0, r.token1, r.liquidity);
    }

    receive() external payable {}

    // ── IComponentModule ───────────────────────────────────────────────────────

    function metadataURI() external view override returns (string memory) {
        return _metadataURI;
    }

    function setMetadataURI(string calldata uri) external override onlyOwner {
        _metadataURI = uri;
        emit MetadataURIUpdated(uri);
    }
}
