# Inline zRouter into UltraAlignmentVault — Full Migration Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.
>
> **Commit style:** Plain commit messages only. Do NOT add `Co-Authored-By` trailers or any other metadata to commits.

**Goal:** Remove the `IVaultSwapRouter` abstraction entirely — inline zRouter's `swapV4` directly into `UltraAlignmentVault`, delete `UniswapVaultSwapRouter`, `ZRouterVaultSwapRouter`, `IVaultSwapRouter`, and `MockVaultSwapRouter`, and update all callers.

**Architecture:** The vault currently stores `IVaultSwapRouter public swapRouter` and four dead Uniswap addresses (`v3Router`, `v2Router`, `v2Factory`, `v3Factory`). Replace all five with `address public zRouter`, `uint24 public zRouterFee`, `int24 public zRouterTickSpacing`. The factory constructor changes from six Uniswap address params to three zRouter params plus a pre-deployed `IVaultPriceValidator`. Tests replace `MockVaultSwapRouter` with `MockZRouter` throughout.

**Current bytecode headroom:** `UltraAlignmentVault` is 17,677 bytes; limit is 24,576 bytes. Headroom = 6,899 bytes. Inlining adds ~500 bytes. Safe to proceed.

**Tech Stack:** Solidity 0.8.20, Foundry/Forge, MockZRouter (already exists at `test/mocks/MockZRouter.sol`).

---

## Essential Context

### New vault initialize() signature (after this plan)

```solidity
function initialize(
    address _weth,
    address _poolManager,
    address _alignmentToken,
    address _factoryCreator,
    uint256 _creatorYieldCutBps,
    address _zRouter,
    uint24  _zRouterFee,
    int24   _zRouterTickSpacing,
    IVaultPriceValidator _priceValidator
) external
```

### New factory constructor signature (after this plan)

```solidity
constructor(
    address _weth,
    address _poolManager,
    address _zRouter,
    uint24  _zRouterFee,
    int24   _zRouterTickSpacing,
    IVaultPriceValidator _defaultPriceValidator
)
```

### IzRouterV4 interface (inline in vault — same as in ZRouterVaultSwapRouter.sol)

```solidity
interface IzRouterV4 {
    function swapV4(
        address to,
        bool exactOut,
        uint24 swapFee,
        int24 tickSpace,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) external payable returns (uint256 amountIn, uint256 amountOut);
}
```

### Test swap pattern with MockZRouter

Replace `MockVaultSwapRouter` in setUp with:

```solidity
MockZRouter public mockZRouter;
// in setUp:
mockZRouter = new MockZRouter();
vm.deal(address(mockZRouter), 100 ether);
alignmentToken.transfer(address(mockZRouter), 100_000e18);
// pass to initialize: address(mockZRouter), 3000, 60
```

---

## Task 1: Update UltraAlignmentVault.sol

**Files:**
- Modify: `src/vaults/UltraAlignmentVault.sol`

### Step 1: Add IzRouterV4 interface

After line 20 (`import {IVaultPriceValidator}...`) and before line 22 (`/// @notice IERC20Metadata...`), add:

```solidity
interface IzRouterV4 {
    function swapV4(
        address to,
        bool exactOut,
        uint24 swapFee,
        int24 tickSpace,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) external payable returns (uint256 amountIn, uint256 amountOut);
}
```

### Step 2: Remove dead import

Remove line 19:
```solidity
import {IVaultSwapRouter} from "../interfaces/IVaultSwapRouter.sol";
```

### Step 3: Replace state variables (lines 97–109 area)

Replace this block:
```solidity
    address public weth;
    address public poolManager;
    address public v3Router;
    address public v2Router;
    address public v2Factory;
    address public v3Factory;
    address public alignmentToken;
    uint8 public alignmentTokenDecimals;
    PoolKey public v4PoolKey;

    // Peripherals (set once at initialize, owner can update)
    IVaultSwapRouter    public swapRouter;
    IVaultPriceValidator public priceValidator;
```

With:
```solidity
    address public weth;
    address public poolManager;
    address public alignmentToken;
    uint8 public alignmentTokenDecimals;
    PoolKey public v4PoolKey;

    // zRouter swap config (set once at initialize)
    address public zRouter;
    uint24  public zRouterFee;
    int24   public zRouterTickSpacing;

    // Peripherals (set once at initialize, owner can update)
    IVaultPriceValidator public priceValidator;
```

### Step 4: Replace initialize() signature and body

Replace the entire `initialize()` function (lines 161–209):

```solidity
    function initialize(
        address _weth,
        address _poolManager,
        address _alignmentToken,
        address _factoryCreator,
        uint256 _creatorYieldCutBps,
        address _zRouter,
        uint24  _zRouterFee,
        int24   _zRouterTickSpacing,
        IVaultPriceValidator _priceValidator
    ) external {
        if (_initialized) revert("Already initialized");
        _initialized = true;

        _initializeOwner(msg.sender); // factory becomes owner

        require(_weth != address(0), "Invalid WETH");
        require(_poolManager != address(0), "Invalid pool manager");
        require(_alignmentToken != address(0), "Invalid alignment token");
        require(_creatorYieldCutBps <= 500, "Creator cut exceeds protocol yield cut");

        weth = _weth;
        poolManager = _poolManager;
        alignmentToken = _alignmentToken;
        factoryCreator = _factoryCreator;
        creatorYieldCutBps = _creatorYieldCutBps;
        zRouter = _zRouter;
        zRouterFee = _zRouterFee;
        zRouterTickSpacing = _zRouterTickSpacing;
        priceValidator = _priceValidator;

        // Initialize defaults that can't use declaration initializers with clones
        protocolYieldCutBps = 500;
        standardConversionReward = 0.0012 ether;
        v3PreferredFee = 3000;
        maxPriceDeviationBps = 500;
        vaultFeeCollectionInterval = 1 days;
        dustDistributionThreshold = 1e18;

        try IERC20Metadata(_alignmentToken).decimals() returns (uint8 decimals) {
            alignmentTokenDecimals = decimals;
        } catch {
            alignmentTokenDecimals = 18;
        }
    }
```

### Step 5: Replace ETH→token swap call site (~line 283)

Replace:
```solidity
        // Swap ETH for alignment token via router
        uint256 targetTokenReceived = swapRouter.swapETHForToken{value: ethToSwap}(
            alignmentToken,
            minOutTarget,
            address(this)
        );
```

With:
```solidity
        // Swap ETH for alignment token via zRouter
        (, uint256 targetTokenReceived) = IzRouterV4(zRouter).swapV4{value: ethToSwap}(
            address(this),
            false,
            zRouterFee,
            zRouterTickSpacing,
            address(0),
            alignmentToken,
            ethToSwap,
            minOutTarget,
            type(uint256).max
        );
```

### Step 6: Replace token→ETH swap call site (~line 418)

Replace:
```solidity
    function _convertVaultFeesToEth(uint256 tokenAmount) internal returns (uint256 ethReceived) {
        if (tokenAmount == 0) return 0;
        IERC20(alignmentToken).approve(address(swapRouter), tokenAmount);
        return swapRouter.swapTokenForETH(alignmentToken, tokenAmount, 0, address(this));
    }
```

With:
```solidity
    function _convertVaultFeesToEth(uint256 tokenAmount) internal returns (uint256 ethReceived) {
        if (tokenAmount == 0) return 0;
        IERC20(alignmentToken).approve(zRouter, tokenAmount);
        (, ethReceived) = IzRouterV4(zRouter).swapV4(
            address(this),
            false,
            zRouterFee,
            zRouterTickSpacing,
            alignmentToken,
            address(0),
            tokenAmount,
            0,
            type(uint256).max
        );
    }
```

### Step 7: Compile check

```bash
forge build --skip "test/**" --skip "script/**" 2>&1 | grep -E "^Error|error:" | grep -v "note\|help"
```

Expected: no output (clean compile — test files will still reference old interfaces, that's fine for now).

### Step 8: Commit

```bash
git add src/vaults/UltraAlignmentVault.sol
git commit -m "feat: inline zRouter swapV4 into UltraAlignmentVault, remove IVaultSwapRouter"
```

---

## Task 2: Update UltraAlignmentVaultFactory.sol

**Files:**
- Modify: `src/vaults/UltraAlignmentVaultFactory.sol`

### Step 1: Rewrite the factory file

Replace the entire file with:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LibClone} from "solady/utils/LibClone.sol";
import {UltraAlignmentVault} from "./UltraAlignmentVault.sol";
import {IVaultPriceValidator} from "../interfaces/IVaultPriceValidator.sol";

/// @title UltraAlignmentVaultFactory
/// @notice Deploys UltraAlignmentVault clones; zRouter config is shared across all vaults.
contract UltraAlignmentVaultFactory {
    address public immutable vaultImplementation;
    IVaultPriceValidator public immutable defaultPriceValidator;

    address public immutable weth;
    address public immutable poolManager;
    address public immutable zRouter;
    uint24  public immutable zRouterFee;
    int24   public immutable zRouterTickSpacing;

    event VaultDeployed(address indexed vault, address indexed alignmentToken, address indexed creator);

    constructor(
        address _weth,
        address _poolManager,
        address _zRouter,
        uint24  _zRouterFee,
        int24   _zRouterTickSpacing,
        IVaultPriceValidator _defaultPriceValidator
    ) {
        weth = _weth;
        poolManager = _poolManager;
        zRouter = _zRouter;
        zRouterFee = _zRouterFee;
        zRouterTickSpacing = _zRouterTickSpacing;
        defaultPriceValidator = _defaultPriceValidator;
        vaultImplementation = address(new UltraAlignmentVault());
    }

    /// @notice Deploy a new vault clone
    /// @param alignmentToken The token this vault aligns to
    /// @param factoryCreator Address that receives creator yield cut
    /// @param creatorYieldCutBps Creator yield cut in basis points (max 500)
    /// @param priceValidator Custom price validator; uses defaultPriceValidator if address(0)
    /// @return vault Address of the deployed vault clone
    function deployVault(
        address alignmentToken,
        address factoryCreator,
        uint256 creatorYieldCutBps,
        IVaultPriceValidator priceValidator
    ) external returns (address vault) {
        vault = LibClone.clone(vaultImplementation);

        UltraAlignmentVault(payable(vault)).initialize(
            weth,
            poolManager,
            alignmentToken,
            factoryCreator,
            creatorYieldCutBps,
            zRouter,
            zRouterFee,
            zRouterTickSpacing,
            priceValidator == IVaultPriceValidator(address(0)) ? defaultPriceValidator : priceValidator
        );

        emit VaultDeployed(vault, alignmentToken, factoryCreator);
    }
}
```

### Step 2: Compile check

```bash
forge build --skip "test/**" --skip "script/**" 2>&1 | grep -E "^Error|error:" | grep -v "note\|help"
```

Expected: no output.

### Step 3: Commit

```bash
git add src/vaults/UltraAlignmentVaultFactory.sol
git commit -m "refactor: remove UniswapVaultSwapRouter from factory, take zRouter params + pre-deployed priceValidator"
```

---

## Task 3: Update DeploySepolia.s.sol

**Files:**
- Modify: `script/DeploySepolia.s.sol`

### Step 1: Add zRouter constant

Near the top of `DeploySepolia`, alongside the other `SEPOLIA_*` constants (lines 36–41), add:

```solidity
    // zRouter singleton on Sepolia — TODO: replace with actual deployed address
    address public constant SEPOLIA_ZROUTER = address(0); // placeholder
    uint24  public constant ZROUTER_FEE = 3000;
    int24   public constant ZROUTER_TICK_SPACING = 60;
```

### Step 2: Remove dead imports

Remove these three lines from the imports section:
```solidity
import {UniswapVaultSwapRouter} from "../src/peripherals/UniswapVaultSwapRouter.sol";
import {IVaultSwapRouter} from "../src/interfaces/IVaultSwapRouter.sol";
```

Also remove these constants if unused elsewhere in the script (check first with grep):
- `SEPOLIA_V3_SWAP_ROUTER`
- `SEPOLIA_V3_FACTORY`
- `SEPOLIA_V2_ROUTER`
- `SEPOLIA_V2_FACTORY`

**Check before removing:**
```bash
grep -n "SEPOLIA_V3_SWAP_ROUTER\|SEPOLIA_V3_FACTORY\|SEPOLIA_V2_ROUTER\|SEPOLIA_V2_FACTORY\|v3Router\|v2Router\|v2Factory\|v3Factory" script/DeploySepolia.s.sol
```

Remove only the constants that appear only once (their own declaration). Leave any used elsewhere.

### Step 3: Update vault initialization block (lines ~176–199)

Replace this block:
```solidity
        // 12. UltraAlignmentVault (peripherals + clone pattern)
        UniswapVaultPriceValidator priceValidator = new UniswapVaultPriceValidator(
            weth, v2Factory, v3Factory, poolManager, 1000
        );
        UniswapVaultSwapRouter swapRouter = new UniswapVaultSwapRouter(
            weth, poolManager, v3Router, v2Router, v2Factory, v3Factory, 3000
        );
        UltraAlignmentVault vaultImpl = new UltraAlignmentVault();
        vault = UltraAlignmentVault(payable(LibClone.clone(address(vaultImpl))));
        vault.initialize(
            weth,
            poolManager,
            v3Router,
            v2Router,
            v2Factory,
            v3Factory,
            address(testToken),
            deployer,       // factoryCreator
            100,            // creatorYieldCutBps (1%)
            IVaultSwapRouter(address(swapRouter)),
            IVaultPriceValidator(address(priceValidator))
        );
```

With:
```solidity
        // 12. UltraAlignmentVault (peripherals + clone pattern)
        UniswapVaultPriceValidator priceValidator = new UniswapVaultPriceValidator(
            weth, v2Factory, v3Factory, poolManager, 1000
        );
        UltraAlignmentVault vaultImpl = new UltraAlignmentVault();
        vault = UltraAlignmentVault(payable(LibClone.clone(address(vaultImpl))));
        vault.initialize(
            weth,
            poolManager,
            address(testToken),
            deployer,       // factoryCreator
            100,            // creatorYieldCutBps (1%)
            SEPOLIA_ZROUTER,
            ZROUTER_FEE,
            ZROUTER_TICK_SPACING,
            IVaultPriceValidator(address(priceValidator))
        );
```

Note: `v2Factory`, `v3Factory`, `poolManager`, `weth` are still used for `UniswapVaultPriceValidator` construction so keep those local vars/constants if the script uses them.

### Step 4: Compile check

```bash
forge build --skip "test/**" --skip "script/**" 2>&1 | grep -E "^Error|error:" | grep -v "note\|help"
```

Expected: no output.

### Step 5: Commit

```bash
git add script/DeploySepolia.s.sol
git commit -m "chore: update DeploySepolia to use zRouter vault init"
```

---

## Task 4: Update UltraAlignmentVault.t.sol and TestableUltraAlignmentVault.sol

**Files:**
- Modify: `test/vaults/UltraAlignmentVault.t.sol`
- Modify: `test/helpers/TestableUltraAlignmentVault.sol`

The vault test has MockVaultSwapRouter used throughout. The setUp creates a `MockVaultSwapRouter` and passes it to `vault.initialize()` as an `IVaultSwapRouter`. We replace this with `MockZRouter`.

### Step 1: Update TestableUltraAlignmentVault.sol

Replace the entire file:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UltraAlignmentVault} from "../../src/vaults/UltraAlignmentVault.sol";
import {IVaultPriceValidator} from "../../src/interfaces/IVaultPriceValidator.sol";

/// @notice Test-only vault that overrides LP with mock behavior.
/// @dev Swap behavior is handled by MockZRouter injected at initialize().
///      Only _addToLpPosition is overridden here since it requires a real V4 pool.
contract TestableUltraAlignmentVault is UltraAlignmentVault {
    function _addToLpPosition(
        uint256 amount0,
        uint256 amount1,
        int24 tickLower,
        int24 tickUpper
    ) internal override returns (uint128 liquidityUnits) {
        require(amount0 > 0 && amount1 > 0, "Amounts must be positive");
        lastTickLower = tickLower;
        lastTickUpper = tickUpper;
        liquidityUnits = uint128((amount0 + amount1) / 2);
    }

    /// @notice Simulate protocol fee accrual for testing withdrawProtocolFees happy path.
    function simulateProtocolFeeAccrual(uint256 amount) external payable {
        require(msg.value == amount, "Must send exact ETH");
        accumulatedProtocolFees += amount;
    }
}
```

### Step 2: Update imports in UltraAlignmentVault.t.sol

Replace these imports near the top:
```solidity
import {MockVaultSwapRouter} from "../mocks/MockVaultSwapRouter.sol";
import {IVaultSwapRouter} from "../../src/interfaces/IVaultSwapRouter.sol";
```

With:
```solidity
import {MockZRouter} from "../mocks/MockZRouter.sol";
```

### Step 3: Replace state variable declarations

Replace:
```solidity
    address public mockWETH = address(0x1111111111111111111111111111111111111111);
    address public mockPoolManager = address(0x2222222222222222222222222222222222222222);
    address public mockV3Router = address(0x3333333333333333333333333333333333333333);
    address public mockV2Router = address(0x4444444444444444444444444444444444444444);
    address public mockV2Factory = address(0x5555555555555555555555555555555555555555);
    address public mockV3Factory = address(0x6666666666666666666666666666666666666666);

    MockVaultSwapRouter public mockRouter;
```

With:
```solidity
    address public mockWETH = address(0x1111111111111111111111111111111111111111);
    address public mockPoolManager = address(0x2222222222222222222222222222222222222222);

    MockZRouter public mockZRouter;
```

### Step 4: Update setUp()

Replace this block in setUp (lines ~62–83):
```solidity
        // Deploy mock peripherals
        mockRouter = new MockVaultSwapRouter();
        mockValidator = new MockVaultPriceValidator();

        // Pre-fund mock router with tokens for swap simulation
        alignmentToken.transfer(address(mockRouter), 100000e18);

        // Deploy testable vault implementation and clone it
        vaultImpl = new TestableUltraAlignmentVault();
        vault = TestableUltraAlignmentVault(payable(LibClone.clone(address(vaultImpl))));
        vault.initialize(
            mockWETH,
            mockPoolManager,
            mockV3Router,
            mockV2Router,
            mockV2Factory,
            mockV3Factory,
            address(alignmentToken),
            address(0xC1EA),
            100,
            IVaultSwapRouter(address(mockRouter)),
            IVaultPriceValidator(address(mockValidator))
        );
```

With:
```solidity
        // Deploy mock peripherals
        mockZRouter = new MockZRouter();
        mockValidator = new MockVaultPriceValidator();

        // Pre-fund MockZRouter for both swap directions
        vm.deal(address(mockZRouter), 100 ether);
        alignmentToken.transfer(address(mockZRouter), 100_000e18);

        // Deploy testable vault implementation and clone it
        vaultImpl = new TestableUltraAlignmentVault();
        vault = TestableUltraAlignmentVault(payable(LibClone.clone(address(vaultImpl))));
        vault.initialize(
            mockWETH,
            mockPoolManager,
            address(alignmentToken),
            address(0xC1EA),
            100,
            address(mockZRouter),
            3000,
            60,
            IVaultPriceValidator(address(mockValidator))
        );
```

### Step 5: Fix all other initialize() calls in the test file

Search for every other `vault.initialize(` or `v.initialize(` call in the file (lines ~129, 137, 145, 152–158, 459–462). Each one currently passes 11 arguments with v3Router/v2Router etc. Update them all to use the new 9-argument signature.

For inline calls on a single line (like line 129), the pattern is:
```solidity
// OLD (11 args):
v.initialize(address(0), mockPoolManager, mockV3Router, mockV2Router, mockV2Factory, mockV3Factory,
    address(alignmentToken), address(0xC1EA), 100,
    IVaultSwapRouter(address(mockRouter)), IVaultPriceValidator(address(mockValidator)));

// NEW (9 args):
v.initialize(address(0), mockPoolManager,
    address(alignmentToken), address(0xC1EA), 100,
    address(mockZRouter), 3000, 60,
    IVaultPriceValidator(address(mockValidator)));
```

Apply this pattern to all remaining `initialize()` calls in the file.

Also update the `_freshClone()` helper if present — check:
```bash
grep -n "_freshClone\|initialize" test/vaults/UltraAlignmentVault.t.sol | head -40
```

### Step 6: Run vault tests

```bash
forge test --match-contract UltraAlignmentVaultTest -v 2>&1 | tail -20
```

Expected: all pass. If any fail, read the error and fix before continuing.

### Step 7: Commit

```bash
git add test/vaults/UltraAlignmentVault.t.sol test/helpers/TestableUltraAlignmentVault.sol
git commit -m "test: migrate UltraAlignmentVault tests from MockVaultSwapRouter to MockZRouter"
```

---

## Task 5: Update UltraAlignmentVaultFactory.t.sol

**Files:**
- Modify: `test/vaults/UltraAlignmentVaultFactory.t.sol`

### Step 1: Replace imports

Remove:
```solidity
import {IVaultSwapRouter} from "../../src/interfaces/IVaultSwapRouter.sol";
import {MockVaultSwapRouter} from "../mocks/MockVaultSwapRouter.sol";
```

Add:
```solidity
import {MockZRouter} from "../mocks/MockZRouter.sol";
```

### Step 2: Rewrite state variables and setUp

Replace the current state variables and setUp to use the new factory constructor:

State vars — replace the `mockV3Router`, `mockV2Router`, `mockV2Factory`, `mockV3Factory` vars with:
```solidity
    MockZRouter public mockZRouter;
    MockVaultPriceValidator public mockPriceValidator;
    address public mockZRouterAddr;
```

setUp — replace `new UltraAlignmentVaultFactory(mockWeth, mockPoolManager, mockV3Router, mockV2Router, mockV2Factory, mockV3Factory)` with:
```solidity
        mockZRouter = new MockZRouter();
        mockPriceValidator = new MockVaultPriceValidator();

        factory = new UltraAlignmentVaultFactory(
            mockWeth,
            mockPoolManager,
            address(mockZRouter),
            3000,
            60,
            IVaultPriceValidator(address(mockPriceValidator))
        );
```

### Step 3: Update deployVault() calls

Every `factory.deployVault(...)` call currently passes 5 args including `IVaultSwapRouter(address(0))`. Remove that arg — it now takes 4 args:

```solidity
// OLD:
factory.deployVault(address(alignmentToken), owner, 100, IVaultSwapRouter(address(0)), IVaultPriceValidator(address(0)));

// NEW:
factory.deployVault(address(alignmentToken), owner, 100, IVaultPriceValidator(address(0)));
```

Apply to all deployVault calls in the file.

### Step 4: Rewrite test_deployVault_usesDefaultSwapRouter

Rename and rewrite to check zRouter config instead:
```solidity
    function test_deployVault_usesFactoryZRouterConfig() public {
        address vault = factory.deployVault(
            address(alignmentToken),
            owner,
            100,
            IVaultPriceValidator(address(0))
        );

        assertEq(UltraAlignmentVault(payable(vault)).zRouter(), factory.zRouter(), "Should use factory zRouter");
        assertEq(UltraAlignmentVault(payable(vault)).zRouterFee(), factory.zRouterFee(), "Should use factory fee");
        assertEq(UltraAlignmentVault(payable(vault)).zRouterTickSpacing(), factory.zRouterTickSpacing(), "Should use factory tickSpacing");
        assertEq(
            address(UltraAlignmentVault(payable(vault)).priceValidator()),
            address(factory.defaultPriceValidator()),
            "Should use default price validator"
        );
    }
```

### Step 5: Remove or replace test_deployVault_acceptsCustomSwapRouter

The custom swap router override is gone. Delete `test_deployVault_acceptsCustomSwapRouter`. Optionally add `test_deployVault_acceptsCustomPriceValidator` to verify the custom price validator override still works:

```solidity
    function test_deployVault_acceptsCustomPriceValidator() public {
        MockVaultPriceValidator customValidator = new MockVaultPriceValidator();

        address vault = factory.deployVault(
            address(alignmentToken),
            owner,
            100,
            IVaultPriceValidator(address(customValidator))
        );

        assertEq(
            address(UltraAlignmentVault(payable(vault)).priceValidator()),
            address(customValidator),
            "Should use custom price validator"
        );
    }
```

### Step 6: Rewrite test_constructor_storesAddresses

```solidity
    function test_constructor_storesAddresses() public view {
        assertEq(factory.weth(), mockWeth);
        assertEq(factory.poolManager(), mockPoolManager);
        assertEq(factory.zRouter(), address(mockZRouter));
        assertEq(factory.zRouterFee(), 3000);
        assertEq(factory.zRouterTickSpacing(), 60);
        assertEq(address(factory.defaultPriceValidator()), address(mockPriceValidator));
        assertTrue(factory.vaultImplementation() != address(0));
    }
```

### Step 7: Run factory tests

```bash
forge test --match-contract UltraAlignmentVaultFactoryTest -v 2>&1 | tail -20
```

Expected: all pass.

### Step 8: Commit

```bash
git add test/vaults/UltraAlignmentVaultFactory.t.sol
git commit -m "test: update UltraAlignmentVaultFactory tests for zRouter-based factory"
```

---

## Task 6: Update remaining test files

**Files to modify** (all use vault.initialize with old 11-arg signature):
- `test/vaults/VaultInterfaceCompliance.t.sol`
- `test/security/M04_GriefingAttackTests.t.sol`
- `test/factories/CreatorFeesSplit.t.sol`
- `test/master/NamespaceCollision.t.sol`
- `test/factories/erc404/hooks/UltraAlignmentHookFactory.t.sol`
- `test/factories/erc1155/ERC1155Factory.t.sol`
- `test/factories/erc721/ERC721AuctionFactory.t.sol`

### Step 1: Apply the same pattern to each file

For each file:

1. Remove `import {MockVaultSwapRouter}` and `import {IVaultSwapRouter}`
2. Add `import {MockZRouter} from "../mocks/MockZRouter.sol";` (adjust relative path: from `test/factories/` use `"../../test/mocks/MockZRouter.sol"` or `"../mocks/..."` depending on depth)
3. Remove `MockVaultSwapRouter` state vars
4. Add `MockZRouter public mockZRouter;` (or use inline construction)
5. In setUp: replace `new MockVaultSwapRouter()` with `new MockZRouter()` and fund it
6. Update `vault.initialize(...)` from 11 args to 9 args

**The new initialize call pattern:**
```solidity
vault.initialize(
    mockWETH,           // or wethAddr / whatever the local var is
    mockPoolManager,    // or address(poolManager)
    address(alignmentToken),
    address(0xC1EA),    // factoryCreator
    100,                // creatorYieldCutBps
    address(mockZRouter),
    3000,               // zRouterFee
    60,                 // zRouterTickSpacing
    IVaultPriceValidator(address(new MockVaultPriceValidator()))
);
```

For files that construct `MockVaultSwapRouter` inline (without a stored ref), just replace with `address(new MockZRouter())` or create a local `MockZRouter` and fund it.

**VaultInterfaceCompliance.t.sol**: This file already has a `MockZRouter mockZRouter` declared (for V2). Check if it conflicts — if so, rename the existing one or the new one.

### Step 2: Run the updated tests

```bash
forge test --match-contract "VaultInterfaceCompliance|M04_Griefing|CreatorFeesSplit|NamespaceCollision|UltraAlignmentHookFactory|ERC1155Factory|ERC721Auction" -v 2>&1 | tail -30
```

Expected: all pass. Fix any failures before continuing.

### Step 3: Commit

```bash
git add test/vaults/VaultInterfaceCompliance.t.sol \
        test/security/M04_GriefingAttackTests.t.sol \
        test/factories/CreatorFeesSplit.t.sol \
        test/master/NamespaceCollision.t.sol \
        test/factories/erc404/hooks/UltraAlignmentHookFactory.t.sol \
        test/factories/erc1155/ERC1155Factory.t.sol \
        test/factories/erc721/ERC721AuctionFactory.t.sol
git commit -m "test: migrate remaining vault tests from MockVaultSwapRouter to MockZRouter"
```

---

## Task 7: Delete dead files + bytecode check

### Step 1: Delete dead production files

```bash
rm src/peripherals/UniswapVaultSwapRouter.sol
rm src/interfaces/IVaultSwapRouter.sol
rm src/peripherals/ZRouterVaultSwapRouter.sol
```

### Step 2: Delete dead test files

```bash
rm test/mocks/MockVaultSwapRouter.sol
rm test/peripherals/ZRouterVaultSwapRouter.t.sol
```

(The `test/peripherals/` directory can stay if other files are added later; no need to rmdir.)

### Step 3: Compile check

```bash
forge build --skip "test/**" --skip "script/**" 2>&1 | grep -E "^Error|error:" | grep -v "note\|help"
```

Expected: no output.

### Step 4: Bytecode size check

```bash
forge build --skip "test/**" --skip "script/**" --sizes 2>&1 | grep "UltraAlignmentVault "
```

Expected: runtime size < 24,576 bytes. Record the new size.

### Step 5: Run full suite

```bash
forge test --skip "test/fork/**" 2>&1 | tail -5
```

Expected: all tests pass, zero failures.

### Step 6: Commit

```bash
git add -A
git commit -m "chore: delete UniswapVaultSwapRouter, ZRouterVaultSwapRouter, IVaultSwapRouter, MockVaultSwapRouter"
```

---

## Task 8: Final verification

### Step 1: Confirm no dead references remain

```bash
grep -r "UniswapVaultSwapRouter\|IVaultSwapRouter\|MockVaultSwapRouter\|ZRouterVaultSwapRouter" src/ test/ script/ --include="*.sol" | grep -v "test/fork/"
```

Expected: no output (zero references).

### Step 2: Confirm vault has expected state vars

```bash
grep -n "zRouter\|swapRouter\|v3Router\|v2Router\|v2Factory\|v3Factory" src/vaults/UltraAlignmentVault.sol
```

Expected: only `zRouter`, `zRouterFee`, `zRouterTickSpacing` appear. No `swapRouter`, no `v3Router` etc.

### Step 3: Full test suite

```bash
forge test --skip "test/fork/**" 2>&1 | tail -5
```

Expected: all tests pass.

### Step 4: Done — hand off to finishing-a-development-branch skill
