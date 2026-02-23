// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {UltraAlignmentVault} from "../../src/vaults/UltraAlignmentVault.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {Ownable} from "solady/auth/Ownable.sol";

/**
 * @title UltraAlignmentV4HookTest
 * @notice Unit tests for UltraAlignmentV4Hook fee collection
 * @dev TestableHook mirrors production logic EXACTLY — no divergence allowed.
 *
 * DESIGN RULES (learned the hard way):
 * 1. TestableHook must use IDENTICAL logic to production UltraAlignmentV4Hook
 * 2. All pools use realistic setup: currency0=address(0), currency1=token
 * 3. Both buy (zeroForOne=true) and sell (zeroForOne=false) are tested
 * 4. No WETH shortcuts — production only accepts address(0) as currency0
 */
contract UltraAlignmentV4HookTest is Test {
    using SafeCast for uint256;
    using SafeCast for int128;

    TestableHook public hook;
    MockPoolManager public mockPoolManager;
    MockVault public mockVault;

    address public owner = address(0x1);
    address public alice = address(0x2);
    address public bob = address(0x3);

    address public mockToken = address(0x2222222222222222222222222222222222222222);

    uint256 constant DEFAULT_HOOK_FEE_BIPS = 100; // 1%
    uint24 constant DEFAULT_LP_FEE_RATE = 3000; // 0.3%

    // Events (must match production)
    event AlignmentFeeCollected(uint256 ethAmount, address indexed benefactor);
    event LpFeeRateUpdated(uint24 newRate);

    function setUp() public {
        vm.startPrank(owner);

        mockPoolManager = new MockPoolManager();
        mockVault = new MockVault();

        hook = new TestableHook(
            IPoolManager(address(mockPoolManager)),
            UltraAlignmentVault(payable(address(mockVault))),
            address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2), // WETH (not used in fee logic)
            owner,
            DEFAULT_HOOK_FEE_BIPS,
            DEFAULT_LP_FEE_RATE
        );

        vm.stopPrank();

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(address(hook), 100 ether);
    }

    // ========== Helpers ==========

    /// @notice Realistic pool key: currency0=native ETH, currency1=token
    function _ethTokenPoolKey() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)), // Native ETH — always currency0
            currency1: Currency.wrap(mockToken),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    /// @notice Simulate a buy: ETH→token (zeroForOne=true)
    /// @param ethAmount ETH spent by swapper (negative delta0, positive delta1)
    function _buyDelta(uint256 ethAmount, uint256 tokenOut) internal pure returns (BalanceDelta) {
        return toBalanceDelta(
            int128(-int256(ethAmount)),  // delta0: swapper sends ETH (negative)
            int128(int256(tokenOut))     // delta1: swapper receives token (positive)
        );
    }

    /// @notice Simulate a sell: token→ETH (zeroForOne=false)
    /// @param ethOut ETH received by swapper (positive delta0, negative delta1)
    function _sellDelta(uint256 ethOut, uint256 tokenSpent) internal pure returns (BalanceDelta) {
        return toBalanceDelta(
            int128(int256(ethOut)),       // delta0: swapper receives ETH (positive)
            int128(-int256(tokenSpent))   // delta1: swapper sends token (negative)
        );
    }

    function _buyParams(uint256 ethAmount) internal pure returns (IPoolManager.SwapParams memory) {
        return IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(ethAmount),
            sqrtPriceLimitX96: 0
        });
    }

    function _sellParams(uint256 tokenAmount) internal pure returns (IPoolManager.SwapParams memory) {
        return IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: -int256(tokenAmount),
            sqrtPriceLimitX96: 0
        });
    }

    // ========== Initialization Tests ==========

    function test_constructor_storesParametersCorrectly() public view {
        assertEq(address(hook.poolManager()), address(mockPoolManager));
        assertEq(address(hook.vault()), address(mockVault));
        assertEq(hook.owner(), owner);
    }

    function test_constructor_setsImmutableHookFee() public view {
        assertEq(hook.hookFeeBips(), DEFAULT_HOOK_FEE_BIPS, "hookFeeBips should be set at deploy");
    }

    function test_constructor_setsInitialLpFeeRate() public view {
        assertEq(hook.lpFeeRate(), DEFAULT_LP_FEE_RATE, "lpFeeRate should be set at deploy");
    }

    // ========== Buy Direction Tests (ETH→token, zeroForOne=true) ==========
    // THIS IS THE DIRECTION THAT WAS BROKEN BEFORE THE REFACTOR

    function test_buy_collectsFeeOnETHSide() public {
        PoolKey memory key = _ethTokenPoolKey();
        uint256 ethSpent = 1000e18;
        uint256 expectedFee = (ethSpent * DEFAULT_HOOK_FEE_BIPS) / 10000; // 1% of ETH

        BalanceDelta delta = _buyDelta(ethSpent, 500e18);

        vm.prank(address(mockPoolManager));
        (bytes4 selector, int128 hookDelta) = hook.afterSwap(
            alice, key, _buyParams(ethSpent), delta, bytes("")
        );

        assertEq(selector, IHooks.afterSwap.selector);
        assertEq(hookDelta, int128(uint128(expectedFee)), "Hook delta should be fee amount");
        assertEq(mockVault.lastFeeAmount(), expectedFee, "Vault should receive exact fee");
        assertEq(mockVault.lastBenefactor(), alice, "Benefactor should be swapper");
    }

    function test_buy_feeCalculatedFromETHNotToken() public {
        PoolKey memory key = _ethTokenPoolKey();
        uint256 ethSpent = 2000e18;
        uint256 tokenOut = 800e18; // Different from ETH amount

        BalanceDelta delta = _buyDelta(ethSpent, tokenOut);

        vm.prank(address(mockPoolManager));
        (, int128 hookDelta) = hook.afterSwap(
            alice, key, _buyParams(ethSpent), delta, bytes("")
        );

        // Fee should be 1% of ETH (2000e18), not 1% of token (800e18)
        uint256 expectedFee = (ethSpent * DEFAULT_HOOK_FEE_BIPS) / 10000;
        assertEq(uint128(hookDelta), expectedFee, "Fee must be based on ETH movement, not token");
    }

    function test_buy_vaultReceivesETH() public {
        PoolKey memory key = _ethTokenPoolKey();
        BalanceDelta delta = _buyDelta(1000e18, 500e18);

        vm.prank(address(mockPoolManager));
        hook.afterSwap(alice, key, _buyParams(1000e18), delta, bytes(""));

        // Verify vault was called with currency0 (ETH)
        assertEq(
            Currency.unwrap(mockVault.lastCurrency()),
            address(0),
            "Vault must receive native ETH, not token"
        );
    }

    // ========== Sell Direction Tests (token→ETH, zeroForOne=false) ==========

    function test_sell_collectsFeeOnETHSide() public {
        PoolKey memory key = _ethTokenPoolKey();
        uint256 ethReceived = 1000e18;
        uint256 expectedFee = (ethReceived * DEFAULT_HOOK_FEE_BIPS) / 10000;

        BalanceDelta delta = _sellDelta(ethReceived, 500e18);

        vm.prank(address(mockPoolManager));
        (bytes4 selector, int128 hookDelta) = hook.afterSwap(
            bob, key, _sellParams(500e18), delta, bytes("")
        );

        assertEq(selector, IHooks.afterSwap.selector);
        assertEq(hookDelta, int128(uint128(expectedFee)), "Sell should produce ETH fee");
        assertEq(mockVault.lastFeeAmount(), expectedFee, "Vault receives sell fee");
        assertEq(mockVault.lastBenefactor(), bob);
    }

    function test_sell_feeCalculatedFromETHNotToken() public {
        PoolKey memory key = _ethTokenPoolKey();
        uint256 ethReceived = 3000e18;
        uint256 tokenSpent = 1500e18;

        BalanceDelta delta = _sellDelta(ethReceived, tokenSpent);

        vm.prank(address(mockPoolManager));
        (, int128 hookDelta) = hook.afterSwap(
            alice, key, _sellParams(tokenSpent), delta, bytes("")
        );

        uint256 expectedFee = (ethReceived * DEFAULT_HOOK_FEE_BIPS) / 10000;
        assertEq(uint128(hookDelta), expectedFee, "Sell fee must be based on ETH, not token");
    }

    // ========== Both Directions ==========

    function test_buyThenSell_bothProduceFees() public {
        PoolKey memory key = _ethTokenPoolKey();

        // Buy: spend 1 ETH
        BalanceDelta buyDelta = _buyDelta(1 ether, 500e18);
        vm.prank(address(mockPoolManager));
        (, int128 buyHookDelta) = hook.afterSwap(
            alice, key, _buyParams(1 ether), buyDelta, bytes("")
        );
        assertGt(buyHookDelta, 0, "Buy must produce a fee");

        // Sell: receive 0.5 ETH
        BalanceDelta sellDelta = _sellDelta(0.5 ether, 250e18);
        vm.prank(address(mockPoolManager));
        (, int128 sellHookDelta) = hook.afterSwap(
            bob, key, _sellParams(250e18), sellDelta, bytes("")
        );
        assertGt(sellHookDelta, 0, "Sell must produce a fee");

        // Verify proportional: buy fee > sell fee (more ETH moved)
        assertGt(buyHookDelta, sellHookDelta, "Larger ETH movement = larger fee");
    }

    // ========== Pool Validation Tests ==========

    function test_revert_whenCurrency0IsNotNativeETH() public {
        address nonETHToken = address(0x3333333333333333333333333333333333333333);

        // Pool with non-ETH as currency0 — must revert
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(nonETHToken),
            currency1: Currency.wrap(mockToken),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        BalanceDelta delta = toBalanceDelta(int128(-1000e18), int128(1000e18));
        IPoolManager.SwapParams memory params = _buyParams(1000e18);

        vm.prank(address(mockPoolManager));
        vm.expectRevert("Pool currency0 must be native ETH");
        hook.afterSwap(alice, key, params, delta, bytes(""));
    }

    function test_revert_whenCurrency0IsWETH() public {
        // WETH is NOT address(0) — must revert, no shortcuts
        address wethAddr = address(0x1111111111111111111111111111111111111111);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(wethAddr),
            currency1: Currency.wrap(mockToken),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        BalanceDelta delta = toBalanceDelta(int128(-1000e18), int128(1000e18));

        vm.prank(address(mockPoolManager));
        vm.expectRevert("Pool currency0 must be native ETH");
        hook.afterSwap(alice, key, _buyParams(1000e18), delta, bytes(""));
    }

    // ========== Fee Calculation Tests ==========

    function test_feeCalculation_standardRate() public view {
        uint256 ethMoved = 1000e18;
        uint256 expectedFee = (ethMoved * DEFAULT_HOOK_FEE_BIPS) / 10000;
        assertEq(expectedFee, 10e18, "1% of 1000e18 = 10e18");
    }

    function test_feeCalculation_smallAmount_roundsToZero() public {
        PoolKey memory key = _ethTokenPoolKey();

        // 50 wei * 100 / 10000 = 0 (rounds down)
        BalanceDelta delta = _buyDelta(50, 25);

        vm.prank(address(mockPoolManager));
        (, int128 hookDelta) = hook.afterSwap(
            alice, key, _buyParams(50), delta, bytes("")
        );

        assertEq(hookDelta, 0, "Fee should round to zero for tiny swaps");
    }

    function test_feeCalculation_oneEther() public {
        PoolKey memory key = _ethTokenPoolKey();
        BalanceDelta delta = _buyDelta(1 ether, 500e18);

        vm.prank(address(mockPoolManager));
        (, int128 hookDelta) = hook.afterSwap(
            alice, key, _buyParams(1 ether), delta, bytes("")
        );

        // 1e18 * 100 / 10000 = 1e16
        assertEq(uint128(hookDelta), 1e16, "1% of 1 ETH = 0.01 ETH");
    }

    function test_feeCalculation_largeAmount() public {
        PoolKey memory key = _ethTokenPoolKey();
        BalanceDelta delta = _buyDelta(10000e18, 5000e18);

        vm.prank(address(mockPoolManager));
        (, int128 hookDelta) = hook.afterSwap(
            alice, key, _buyParams(10000e18), delta, bytes("")
        );

        assertEq(uint128(hookDelta), 100e18, "1% of 10000 ETH = 100 ETH");
    }

    // ========== Zero Fee Tests ==========

    function test_zeroHookFee_noFeeCollected() public {
        // Deploy hook with hookFeeBips=0
        vm.prank(owner);
        TestableHook zeroFeeHook = new TestableHook(
            IPoolManager(address(mockPoolManager)),
            UltraAlignmentVault(payable(address(mockVault))),
            address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2),
            owner,
            0, // hookFeeBips = 0
            DEFAULT_LP_FEE_RATE
        );

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(mockToken),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(zeroFeeHook))
        });

        BalanceDelta delta = _buyDelta(1000e18, 500e18);

        vm.prank(address(mockPoolManager));
        (, int128 hookDelta) = zeroFeeHook.afterSwap(
            alice, key, _buyParams(1000e18), delta, bytes("")
        );

        assertEq(hookDelta, 0, "Zero hookFeeBips should produce zero fee");
    }

    // ========== hookFeeBips Immutability ==========

    function test_hookFeeBips_isImmutable() public view {
        // hookFeeBips is immutable — no setter exists
        // This test documents the design: hookFeeBips can only be set at construction
        assertEq(hook.hookFeeBips(), DEFAULT_HOOK_FEE_BIPS);
        // There is no setHookFeeBips() function — verified by the fact that
        // the TestableHook contract has no such method
    }

    // ========== LP Fee Rate Management ==========

    function test_setLpFeeRate_byOwner() public {
        vm.prank(owner);
        hook.setLpFeeRate(5000);
        assertEq(hook.lpFeeRate(), 5000);
    }

    function test_setLpFeeRate_validRates() public {
        vm.startPrank(owner);

        hook.setLpFeeRate(0);
        assertEq(hook.lpFeeRate(), 0, "Should allow 0 LP fee");

        hook.setLpFeeRate(3000);
        assertEq(hook.lpFeeRate(), 3000, "Should allow 3000 (0.3%)");

        hook.setLpFeeRate(uint24(LPFeeLibrary.MAX_LP_FEE));
        assertEq(hook.lpFeeRate(), uint24(LPFeeLibrary.MAX_LP_FEE), "Should allow max fee");

        vm.stopPrank();
    }

    function test_setLpFeeRate_ownerOnly() public {
        vm.prank(alice);
        vm.expectRevert();
        hook.setLpFeeRate(5000);
    }

    function test_setLpFeeRate_rejectsAboveMax() public {
        vm.prank(owner);
        vm.expectRevert("Rate too high");
        hook.setLpFeeRate(uint24(LPFeeLibrary.MAX_LP_FEE + 1));
    }

    function test_setLpFeeRate_emitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit LpFeeRateUpdated(7500);
        hook.setLpFeeRate(7500);
    }

    // ========== beforeSwap Tests ==========

    function test_beforeSwap_returnsLpFeeWithOverrideFlag() public {
        PoolKey memory key = _ethTokenPoolKey();
        IPoolManager.SwapParams memory params = _buyParams(1 ether);

        vm.prank(address(mockPoolManager));
        (bytes4 selector, BeforeSwapDelta bsDelta, uint24 fee) = hook.beforeSwap(
            alice, key, params, bytes("")
        );

        assertEq(selector, IHooks.beforeSwap.selector);
        assertEq(
            BeforeSwapDelta.unwrap(bsDelta),
            BeforeSwapDelta.unwrap(BeforeSwapDeltaLibrary.ZERO_DELTA),
            "beforeSwap should not modify deltas"
        );
        assertEq(
            fee,
            DEFAULT_LP_FEE_RATE | LPFeeLibrary.OVERRIDE_FEE_FLAG,
            "Must return lpFeeRate with OVERRIDE_FEE_FLAG"
        );
    }

    function test_beforeSwap_reflectsUpdatedRate() public {
        vm.prank(owner);
        hook.setLpFeeRate(10000);

        PoolKey memory key = _ethTokenPoolKey();
        IPoolManager.SwapParams memory params = _buyParams(1 ether);

        vm.prank(address(mockPoolManager));
        (,, uint24 fee) = hook.beforeSwap(alice, key, params, bytes(""));

        assertEq(fee, 10000 | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function test_beforeSwap_onlyPoolManager() public {
        PoolKey memory key = _ethTokenPoolKey();
        IPoolManager.SwapParams memory params = _buyParams(1 ether);

        vm.prank(alice);
        vm.expectRevert("Unauthorized");
        hook.beforeSwap(alice, key, params, bytes(""));
    }

    // ========== Access Control ==========

    function test_afterSwap_onlyPoolManagerCanCall() public {
        PoolKey memory key = _ethTokenPoolKey();
        BalanceDelta delta = _buyDelta(1000e18, 500e18);

        vm.prank(alice);
        vm.expectRevert("Unauthorized");
        hook.afterSwap(alice, key, _buyParams(1000e18), delta, bytes(""));
    }

    // ========== Multiple Swaps ==========

    function test_multipleSwaps_differentUsers() public {
        PoolKey memory key = _ethTokenPoolKey();

        // Alice buys
        BalanceDelta delta1 = _buyDelta(1000e18, 500e18);
        vm.prank(address(mockPoolManager));
        hook.afterSwap(alice, key, _buyParams(1000e18), delta1, bytes(""));
        assertEq(mockVault.lastFeeAmount(), 10e18, "Alice: 1% of 1000 ETH");
        assertEq(mockVault.lastBenefactor(), alice);

        // Bob sells (receives 2000 ETH)
        BalanceDelta delta2 = _sellDelta(2000e18, 1000e18);
        vm.prank(address(mockPoolManager));
        hook.afterSwap(bob, key, _sellParams(1000e18), delta2, bytes(""));
        assertEq(mockVault.lastFeeAmount(), 20e18, "Bob: 1% of 2000 ETH");
        assertEq(mockVault.lastBenefactor(), bob);
    }

    // ========== Vault Integration ==========

    function test_vaultIntegration_receiveInstanceCalled() public {
        PoolKey memory key = _ethTokenPoolKey();
        BalanceDelta delta = _buyDelta(5000e18, 2500e18);

        vm.prank(address(mockPoolManager));
        hook.afterSwap(alice, key, _buyParams(5000e18), delta, bytes(""));

        assertTrue(mockVault.receivedFee(), "Vault should have received fee");
        assertEq(mockVault.lastBenefactor(), alice);
        assertEq(mockVault.lastFeeAmount(), 50e18);
    }

    function test_vaultRevert_propagatesToSwap() public {
        MockRevertingVault revertingVault = new MockRevertingVault();

        vm.prank(owner);
        TestableHook revertingHook = new TestableHook(
            IPoolManager(address(mockPoolManager)),
            UltraAlignmentVault(payable(address(revertingVault))),
            address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2),
            owner,
            DEFAULT_HOOK_FEE_BIPS,
            DEFAULT_LP_FEE_RATE
        );
        vm.deal(address(revertingHook), 100 ether);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(mockToken),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(revertingHook))
        });

        BalanceDelta delta = _buyDelta(50e18, 25e18);

        vm.prank(address(mockPoolManager));
        vm.expectRevert("Vault revert");
        revertingHook.afterSwap(alice, key, _buyParams(50e18), delta, bytes(""));
    }

    // ========== Gas Efficiency ==========

    function test_gasEfficiency_multipleSwaps() public {
        PoolKey memory key = _ethTokenPoolKey();
        BalanceDelta delta = _buyDelta(100e18, 50e18);
        IPoolManager.SwapParams memory params = _buyParams(100e18);

        uint256 gasStart = gasleft();

        for (uint256 i = 0; i < 10; i++) {
            vm.prank(address(mockPoolManager));
            hook.afterSwap(alice, key, params, delta, bytes(""));
        }

        uint256 avgGas = (gasStart - gasleft()) / 10;
        assertTrue(avgGas < 200000, "Average gas per swap should be < 200k");
        assertEq(mockPoolManager.takeCount(), 10, "Should have taken fee 10 times");
    }

    // ========== Max Fee Edge Case ==========

    function test_maxHookFee_100percent() public {
        vm.prank(owner);
        TestableHook maxFeeHook = new TestableHook(
            IPoolManager(address(mockPoolManager)),
            UltraAlignmentVault(payable(address(mockVault))),
            address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2),
            owner,
            10000, // 100% fee
            DEFAULT_LP_FEE_RATE
        );
        vm.deal(address(maxFeeHook), 100 ether);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(mockToken),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(maxFeeHook))
        });

        uint256 ethSpent = 50e18;
        BalanceDelta delta = _buyDelta(ethSpent, 25e18);

        vm.prank(address(mockPoolManager));
        (, int128 hookDelta) = maxFeeHook.afterSwap(
            alice, key, _buyParams(ethSpent), delta, bytes("")
        );

        assertEq(uint128(hookDelta), ethSpent, "100% fee should take entire ETH amount");
    }
}

// ========== TestableHook ==========
// CRITICAL: This MUST mirror production UltraAlignmentV4Hook logic exactly.
// If you change production, change this. If they diverge, tests are useless.

contract TestableHook is ReentrancyGuard, Ownable {
    using SafeCast for uint256;

    IPoolManager public immutable poolManager;
    UltraAlignmentVault public immutable vault;
    address public immutable weth;
    uint256 public immutable hookFeeBips;
    uint24 public lpFeeRate;

    event AlignmentFeeCollected(uint256 ethAmount, address indexed benefactor);
    event LpFeeRateUpdated(uint24 newRate);

    constructor(
        IPoolManager _poolManager,
        UltraAlignmentVault _vault,
        address _weth,
        address _owner,
        uint256 _hookFeeBips,
        uint24 _initialLpFeeRate
    ) {
        require(address(_poolManager) != address(0), "Invalid pool manager");
        require(address(_vault) != address(0), "Invalid vault");
        require(_owner != address(0), "Invalid owner");
        require(_hookFeeBips <= 10000, "Hook fee too high");
        require(_initialLpFeeRate <= LPFeeLibrary.MAX_LP_FEE, "LP fee too high");

        _initializeOwner(_owner);
        poolManager = _poolManager;
        vault = _vault;
        weth = _weth;
        hookFeeBips = _hookFeeBips;
        lpFeeRate = _initialLpFeeRate;
    }

    modifier onlyPoolManager() {
        require(msg.sender == address(poolManager), "Unauthorized");
        _;
    }

    /// @dev MIRRORS production beforeSwap exactly
    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (
            IHooks.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            lpFeeRate | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    /// @dev MIRRORS production afterSwap exactly — always taxes currency0 (ETH side)
    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        require(Currency.unwrap(key.currency0) == address(0), "Pool currency0 must be native ETH");

        int128 amount0 = delta.amount0();
        uint256 ethMoved = amount0 < 0 ? uint256(uint128(-amount0)) : uint256(uint128(amount0));
        uint256 feeAmount = (ethMoved * hookFeeBips) / 10000;

        if (feeAmount > 0) {
            poolManager.take(key.currency0, address(this), feeAmount);
            vault.receiveContribution{value: feeAmount}(key.currency0, feeAmount, sender);
            emit AlignmentFeeCollected(feeAmount, sender);
            return (IHooks.afterSwap.selector, feeAmount.toInt128());
        }

        return (IHooks.afterSwap.selector, int128(0));
    }

    /// @dev MIRRORS production setLpFeeRate exactly
    function setLpFeeRate(uint24 _rate) external onlyOwner {
        require(_rate <= LPFeeLibrary.MAX_LP_FEE, "Rate too high");
        lpFeeRate = _rate;
        emit LpFeeRateUpdated(_rate);
    }
}

// ========== Mocks ==========

contract MockPoolManager {
    uint256 public takeCount;
    mapping(address => uint256) public tokenBalances;

    function take(Currency currency, address to, uint256 amount) external {
        takeCount++;
        tokenBalances[to] += amount;
    }

    function settle(Currency currency) external payable {}
    function burn(uint256 amount) external {}
}

contract MockVault {
    uint256 public lastFeeAmount;
    address public lastBenefactor;
    Currency public lastCurrency;
    bool public receivedFee;

    receive() external payable {}

    function receiveContribution(
        Currency currency,
        uint256 amount,
        address benefactor
    ) external payable {
        lastFeeAmount = amount;
        lastBenefactor = benefactor;
        lastCurrency = currency;
        receivedFee = true;
    }
}

contract MockRevertingVault {
    receive() external payable {}

    function receiveContribution(
        Currency currency,
        uint256 amount,
        address benefactor
    ) external payable {
        revert("Vault revert");
    }
}
