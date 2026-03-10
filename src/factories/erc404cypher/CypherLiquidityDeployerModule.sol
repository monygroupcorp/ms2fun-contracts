// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAlgebraFactory, IAlgebraPool, IAlgebraNFTPositionManager} from "../../interfaces/algebra/IAlgebra.sol";
import {CypherAlignmentVault} from "../../vaults/cypher/CypherAlignmentVault.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {ILiquidityDeployerModule} from "../../interfaces/ILiquidityDeployerModule.sol";
import {RevenueSplitLib} from "../../shared/libraries/RevenueSplitLib.sol";
import {Ownable} from "solady/auth/Ownable.sol";

interface IWETH {
    function deposit() external payable;
}

/// @title CypherLiquidityDeployerModule
/// @notice Called by ERC404BondingInstance at graduation.
///         Creates Algebra pool, mints LP to vault, registers benefactor.
contract CypherLiquidityDeployerModule is ILiquidityDeployerModule, Ownable {
    using FixedPointMathLib for uint256;

    error ETHMismatch();
    error InvalidParams();
    error ZeroLiquidity();

    address public immutable algebraFactory;
    address public immutable positionManager;
    address public immutable weth;

    string private _metadataURI;

    // slither-disable-next-line missing-zero-check
    constructor(address _algebraFactory, address _positionManager, address _weth) {
        algebraFactory = _algebraFactory;
        positionManager = _positionManager;
        weth = _weth;
        _initializeOwner(msg.sender);
    }

    // Full-range ticks for tick spacing 60: floor(887272/60)*60 = 887220
    int24 public constant TICK_LOWER = -887220;
    int24 public constant TICK_UPPER = 887220;

    event LiquidityDeployed(
        address indexed vault, address pool, uint256 tokenId,
        uint256 ethToLP, uint256 tokenToLP
    );
    event GraduationFeePaid(address indexed treasury, uint256 amount);
    event GraduationVaultContribution(address indexed vault, uint256 amount);

    struct PoolSetupResult {
        uint256 tokenId;
        address pool;
        uint256 ethToLP;
        uint256 protocolFee;  // 1% of raise
        uint256 vaultCut;     // 19% of raise
        bool tokenIsZero;
    }

    /// @notice Deploy Algebra pool liquidity and register with vault.
    /// @dev Caller must have pre-transferred tokenReserve to this contract.
    ///      ETH must equal p.ethReserve exactly.
    // slither-disable-next-line reentrancy-events
    function deployLiquidity(DeployParams calldata p) external payable override {
        if (msg.value != p.ethReserve) revert ETHMismatch();
        if (p.token == address(0) || p.vault == address(0)) revert InvalidParams();

        PoolSetupResult memory r = _setupPool(p);
        _postMint(p, r);
    }

    // slither-disable-next-line arbitrary-send-eth,incorrect-equality,timestamp,unused-return
    function _setupPool(ILiquidityDeployerModule.DeployParams calldata p) private returns (PoolSetupResult memory r) {
        // Fixed 1/19/80 split: 1% protocol, 19% vault, 80% LP
        RevenueSplitLib.Split memory s = RevenueSplitLib.split(p.ethReserve);
        r.protocolFee = s.protocolCut;
        r.vaultCut    = s.vaultCut;
        r.ethToLP     = s.remainder;

        // ── Compute sqrtPriceX96 internally from token ordering ──
        bool tokenIsZero = p.token < weth;
        uint256 amount0 = tokenIsZero ? p.tokenReserve : r.ethToLP;
        uint256 amount1 = tokenIsZero ? r.ethToLP : p.tokenReserve;
        uint160 sqrtPriceX96 = uint160(
            FixedPointMathLib.sqrt(FixedPointMathLib.fullMulDiv(amount1, 1 << 192, amount0))
        );

        // ── Wrap ETH to WETH for LP ──
        IWETH(weth).deposit{value: r.ethToLP}();

        // ── Create Algebra pool ──
        r.pool = IAlgebraFactory(algebraFactory).createPool(p.token, weth, "");
        IAlgebraPool(r.pool).initialize(sqrtPriceX96);

        // ── Determine token ordering and amounts ──
        r.tokenIsZero = tokenIsZero;
        (address token0, address token1) = tokenIsZero ? (p.token, weth) : (weth, p.token);

        // ── Approve and mint LP ──
        IERC20(p.token).approve(positionManager, p.tokenReserve);
        IERC20(weth).approve(positionManager, r.ethToLP);

        uint128 liquidity;
        (r.tokenId, liquidity,,) = IAlgebraNFTPositionManager(positionManager).mint(
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
        if (liquidity == 0) revert ZeroLiquidity();
    }

    // slither-disable-next-line arbitrary-send-eth,reentrancy-events,timestamp
    function _postMint(ILiquidityDeployerModule.DeployParams calldata p, PoolSetupResult memory r) private {
        CypherAlignmentVault(payable(p.vault)).registerPosition(
            r.tokenId, r.pool, r.tokenIsZero, p.instance, r.ethToLP
        );
        // 1% → protocol treasury
        if (r.protocolFee > 0 && p.protocolTreasury != address(0)) {
            SafeTransferLib.safeTransferETH(p.protocolTreasury, r.protocolFee);
            emit GraduationFeePaid(p.protocolTreasury, r.protocolFee);
        }
        // 19% → alignment vault via receiveContribution
        if (r.vaultCut > 0) {
            CypherAlignmentVault(payable(p.vault)).receiveContribution{value: r.vaultCut}(
                Currency.wrap(address(0)), r.vaultCut, p.instance
            );
            emit GraduationVaultContribution(p.vault, r.vaultCut);
        }
        emit LiquidityDeployed(p.vault, r.pool, r.tokenId, r.ethToLP, p.tokenReserve);
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
