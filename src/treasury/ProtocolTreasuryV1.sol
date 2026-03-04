// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SafeOwnableUUPS} from "../shared/SafeOwnableUUPS.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {CurrencySettler} from "../libraries/v4/CurrencySettler.sol";
import {LiquidityAmounts} from "../libraries/v4/LiquidityAmounts.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IMasterRegistry} from "../master/interfaces/IMasterRegistry.sol";

interface IWETH {
    function deposit() external payable;
    function transfer(address to, uint256 value) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
}

/**
 * @title ProtocolTreasuryV1
 * @notice UUPS upgradeable treasury that receives protocol revenue from all sources
 * @dev Receives ETH (bonding fees, creation fees, queue revenue) and ERC721 (position NFTs).
 *      Manages protocol-owned V4 LP positions via receivePOL().
 *      Tracks revenue by source for accounting. Owner-gated withdrawals.
 */
// slither-disable-next-line missing-inheritance
contract ProtocolTreasuryV1 is SafeOwnableUUPS, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using StateLibrary for IPoolManager;

    // ============ Custom Errors ============
    // Note: AlreadyInitialized() and Unauthorized() are inherited from Ownable

    error InvalidAddress();
    error NoValue();
    error RegistryNotConfigured();
    error NotRegisteredInstance();
    error V4NotConfigured();
    error WETHNotConfigured();
    error POLAlreadyDeployed();
    error NoPOLPosition();
    error InsufficientBalance();
    error InvalidRecipient();
    error TransferFailed();

    // ============ Revenue Tracking ============

    enum Source {
        BONDING_FEE,
        CREATION_FEE,
        QUEUE_REVENUE,
        OTHER,
        POL_FEES
    }

    mapping(Source => uint256) public totalReceived;
    // slither-disable-next-line uninitialized-state
    mapping(Source => uint256) public totalWithdrawn;

    // ============ Events ============

    event RevenueReceived(Source indexed source, address indexed from, uint256 amount);
    event ETHWithdrawn(address indexed to, uint256 amount);
    event ERC20Withdrawn(address indexed token, address indexed to, uint256 amount);
    event ERC721Withdrawn(address indexed token, address indexed to, uint256 tokenId);
    event V4PoolManagerUpdated(address indexed newPoolManager);
    event WETHUpdated(address indexed newWETH);
    event POLPositionDeployed(address indexed instance, uint128 liquidity, bytes32 salt);
    event POLFeesCollected(address indexed instance, uint256 amount0, uint256 amount1);
    event MasterRegistryUpdated(address indexed newRegistry);
    event RevenueConductorUpdated(address indexed conductor);
    event RevenueRouted(address indexed conductor, address indexed safe, uint256 amount);

    // ============ Revenue Conductor ============

    address public revenueConductor;

    // ============ Initialization ============

    bool private _initialized;

    // ============ V4 Integration ============

    address public v4PoolManager;
    address public weth;
    IMasterRegistry public masterRegistry;

    // POL position tracking
    struct POLPosition {
        PoolKey poolKey;
        int24 tickLower;
        int24 tickUpper;
        bytes32 salt;
        uint128 liquidity;
    }

    mapping(address => POLPosition) internal _polPositions; // instance => position
    address[] public polInstances;

    // Callback routing (mirrors UniAlignmentVault pattern)
    enum CallbackOperation { DEPLOY_POL, COLLECT_FEES }

    struct CallbackData {
        CallbackOperation operation;
        bytes data;
    }

    struct DeployPOLCallbackData {
        PoolKey poolKey;
        int24 tickLower;
        int24 tickUpper;
        bytes32 salt;
        uint256 amount0;
        uint256 amount1;
    }

    struct CollectFeesCallbackData {
        PoolKey poolKey;
        int24 tickLower;
        int24 tickUpper;
        bytes32 salt;
    }

    function initialize(address _owner) external {
        if (_initialized) revert AlreadyInitialized();
        if (_owner == address(0)) revert InvalidAddress();
        _initialized = true;
        _setOwner(_owner);
    }

    // ============ V4 Configuration ============

    function setV4PoolManager(address _pm) external onlyOwner {
        if (_pm == address(0)) revert InvalidAddress();
        v4PoolManager = _pm;
        emit V4PoolManagerUpdated(_pm);
    }

    function setWETH(address _weth) external onlyOwner {
        if (_weth == address(0)) revert InvalidAddress();
        weth = _weth;
        emit WETHUpdated(_weth);
    }

    function setMasterRegistry(address _registry) external onlyOwner {
        if (_registry == address(0)) revert InvalidAddress();
        masterRegistry = IMasterRegistry(_registry);
        emit MasterRegistryUpdated(_registry);
    }

    // ============ Revenue Intake ============

    /// @notice Receive ETH with source attribution
    function deposit(Source source) external payable {
        if (msg.value == 0) revert NoValue();
        totalReceived[source] += msg.value;
        emit RevenueReceived(source, msg.sender, msg.value);
    }

    /// @notice Plain ETH receive — tagged as OTHER
    receive() external payable {
        totalReceived[Source.OTHER] += msg.value;
        emit RevenueReceived(Source.OTHER, msg.sender, msg.value);
    }

    // ============ Protocol-Owned Liquidity ============

    /// @notice Called by instances during graduation to deploy treasury-owned LP
    // slither-disable-next-line reentrancy-benign,reentrancy-events,reentrancy-no-eth,unused-return
    function receivePOL(
        PoolKey calldata poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) external {
        if (address(masterRegistry) == address(0)) revert RegistryNotConfigured();
        if (!masterRegistry.isRegisteredInstance(msg.sender)) revert NotRegisteredInstance();
        if (v4PoolManager == address(0)) revert V4NotConfigured();
        if (weth == address(0)) revert WETHNotConfigured();
        if (_polPositions[msg.sender].liquidity != 0) revert POLAlreadyDeployed();

        // Deterministic salt per instance
        bytes32 salt = keccak256(abi.encodePacked("POL", msg.sender));

        // Approve PoolManager for both currencies
        Currency currency0 = poolKey.currency0;
        Currency currency1 = poolKey.currency1;
        if (!currency0.isAddressZero()) {
            IERC20(Currency.unwrap(currency0)).approve(v4PoolManager, amount0);
        }
        if (!currency1.isAddressZero()) {
            IERC20(Currency.unwrap(currency1)).approve(v4PoolManager, amount1);
        }

        // Deploy via unlock callback
        CallbackData memory cbData = CallbackData({
            operation: CallbackOperation.DEPLOY_POL,
            data: abi.encode(DeployPOLCallbackData({
                poolKey: poolKey,
                tickLower: tickLower,
                tickUpper: tickUpper,
                salt: salt,
                amount0: amount0,
                amount1: amount1
            }))
        });

        bytes memory result = IPoolManager(v4PoolManager).unlock(abi.encode(cbData));
        uint128 liquidity = abi.decode(result, (uint128));

        // Store position
        _polPositions[msg.sender] = POLPosition({
            poolKey: poolKey,
            tickLower: tickLower,
            tickUpper: tickUpper,
            salt: salt,
            liquidity: liquidity
        });
        polInstances.push(msg.sender);

        emit POLPositionDeployed(msg.sender, liquidity, salt);
    }

    /// @notice Permissionless fee collection for a treasury-owned POL position
    // slither-disable-next-line reentrancy-benign,reentrancy-events
    function claimPOLFees(address instance) external returns (uint256 amount0, uint256 amount1) {
        POLPosition storage pos = _polPositions[instance];
        if (pos.liquidity == 0) revert NoPOLPosition();

        CollectFeesCallbackData memory feeParams = CollectFeesCallbackData({
            poolKey: pos.poolKey,
            tickLower: pos.tickLower,
            tickUpper: pos.tickUpper,
            salt: pos.salt
        });

        CallbackData memory cbData = CallbackData({
            operation: CallbackOperation.COLLECT_FEES,
            data: abi.encode(feeParams)
        });

        bytes memory result = IPoolManager(v4PoolManager).unlock(abi.encode(cbData));
        BalanceDelta delta = abi.decode(result, (BalanceDelta));

        amount0 = delta.amount0() > 0 ? uint256(int256(delta.amount0())) : 0;
        amount1 = delta.amount1() > 0 ? uint256(int256(delta.amount1())) : 0;

        totalReceived[Source.POL_FEES] += amount0 + amount1;

        emit POLFeesCollected(instance, amount0, amount1);
    }

    // ============ V4 Callback ============

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != v4PoolManager) revert Unauthorized();

        CallbackData memory cbData = abi.decode(data, (CallbackData));

        if (cbData.operation == CallbackOperation.DEPLOY_POL) {
            return _handleDeployPOL(cbData.data);
        } else {
            return _handleCollectFees(cbData.data);
        }
    }

    // slither-disable-next-line unused-return
    function _handleDeployPOL(bytes memory data) internal returns (bytes memory) {
        DeployPOLCallbackData memory params = abi.decode(data, (DeployPOLCallbackData));

        PoolId poolId = params.poolKey.toId();
        (uint160 sqrtPriceX96,,,) = IPoolManager(v4PoolManager).getSlot0(poolId);
        uint160 sqrtPriceAX96 = TickMath.getSqrtPriceAtTick(params.tickLower);
        uint160 sqrtPriceBX96 = TickMath.getSqrtPriceAtTick(params.tickUpper);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, sqrtPriceAX96, sqrtPriceBX96, params.amount0, params.amount1
        );

        IPoolManager.ModifyLiquidityParams memory modifyParams = IPoolManager.ModifyLiquidityParams({
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            liquidityDelta: int256(uint256(liquidity)),
            salt: params.salt
        });

        (BalanceDelta delta,) = IPoolManager(v4PoolManager).modifyLiquidity(params.poolKey, modifyParams, "");
        _settleDelta(params.poolKey, delta);

        return abi.encode(liquidity);
    }

    // slither-disable-next-line unused-return
    function _handleCollectFees(bytes memory data) internal returns (bytes memory) {
        CollectFeesCallbackData memory params = abi.decode(data, (CollectFeesCallbackData));

        IPoolManager.ModifyLiquidityParams memory modifyParams = IPoolManager.ModifyLiquidityParams({
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            liquidityDelta: 0,
            salt: params.salt
        });

        (BalanceDelta delta,) = IPoolManager(v4PoolManager).modifyLiquidity(params.poolKey, modifyParams, "");
        _settleDelta(params.poolKey, delta);

        return abi.encode(delta);
    }

    function _settleDelta(PoolKey memory poolKey, BalanceDelta delta) internal {
        IPoolManager pm = IPoolManager(v4PoolManager);
        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();

        if (delta0 < 0) {
            poolKey.currency0.settle(pm, address(this), uint128(-delta0), false);
        } else if (delta0 > 0) {
            poolKey.currency0.take(pm, address(this), uint128(delta0), false);
        }
        if (delta1 < 0) {
            poolKey.currency1.settle(pm, address(this), uint128(-delta1), false);
        } else if (delta1 > 0) {
            poolKey.currency1.take(pm, address(this), uint128(delta1), false);
        }
    }

    // ============ POL Views ============

    function getPolPosition(address instance) external view returns (
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt,
        uint128 liquidity
    ) {
        POLPosition storage pos = _polPositions[instance];
        return (pos.tickLower, pos.tickUpper, pos.salt, pos.liquidity);
    }

    function polInstanceCount() external view returns (uint256) {
        return polInstances.length;
    }

    // ============ Revenue Routing ============

    // slither-disable-next-line missing-zero-check
    function setRevenueConductor(address _conductor) external onlyOwner {
        revenueConductor = _conductor;
        emit RevenueConductorUpdated(_conductor);
    }

    /// @notice Route ETH to the DAO Safe — callable only by the conductor, destination locked to DAO safe
    function routeToDAO(address safe, uint256 amount) external {
        if (msg.sender != revenueConductor) revert Unauthorized();
        if (safe == address(0)) revert InvalidAddress();
        if (amount > address(this).balance) revert InsufficientBalance();
        SafeTransferLib.safeTransferETH(safe, amount);
        emit RevenueRouted(msg.sender, safe, amount);
    }

    // ============ Withdrawals (Owner Only) ============

    function withdrawETH(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert InvalidRecipient();
        if (amount > address(this).balance) revert InsufficientBalance();
        SafeTransferLib.safeTransferETH(to, amount);
        emit ETHWithdrawn(to, amount);
    }

    function withdrawERC20(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert InvalidRecipient();
        SafeTransferLib.safeTransfer(token, to, amount);
        emit ERC20Withdrawn(token, to, amount);
    }

    // slither-disable-next-line missing-zero-check,reentrancy-events
    function withdrawERC721(address token, address to, uint256 tokenId) external onlyOwner {
        if (to == address(0)) revert InvalidRecipient();
        // Use low-level call for ERC721 transferFrom(address,address,uint256)
        (bool success,) = token.call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", address(this), to, tokenId)
        );
        if (!success) revert TransferFailed();
        emit ERC721Withdrawn(token, to, tokenId);
    }

    // ============ ERC721 Receiver ============

    /// @notice Accept ERC721 safeTransfer
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    // ============ Views ============

    function getBalance() external view returns (uint256) {
        return address(this).balance;
    }

    function getRevenueBySource(Source source) external view returns (uint256 received, uint256 withdrawn) {
        return (totalReceived[source], totalWithdrawn[source]);
    }

}
