# Free Mints + GatingScope Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add `GatingScope` (controls which entry points the gating module guards) and a zero-cost free mint allocation primitive to `ERC404BondingInstance` and `ERC1155Instance`, wired through their respective factories.

**Architecture:** Free mints are a token tranche carved from total supply at deployment. The factory computes curve params against `(nftCount - freeMintAllocation)` but initializes the instance with the full `nftCount * unit` supply so the contract holds all tokens. `GatingScope` is stored on the instance and controls whether `claimFreeMint` and/or `buyBonding` consult the gating module.

**Tech Stack:** Solidity 0.8.20/0.8.24, Foundry/Forge, DN404 (ERC404), custom gating interface (`IGatingModule`). Run tests with `forge test --match-contract <Name>`.

---

## Reference: Key File Locations

- `src/gating/IGatingModule.sol` — gating interface (add `GatingScope` enum here)
- `src/interfaces/IFactoryTypes.sol` — shared structs (`IdentityParams`, add `FreeMintParams`)
- `src/factories/erc404/ERC404BondingInstance.sol` — ERC404 instance (add free mint state + functions)
- `src/factories/erc404/ERC404Factory.sol` — ERC404 factory (wire FreeMintParams through)
- `src/factories/erc1155/ERC1155Instance.sol` — ERC1155 instance (add free mint state + functions)
- `src/factories/erc1155/ERC1155Factory.sol` — ERC1155 factory (wire FreeMintParams through)
- `test/factories/erc404/ERC404Factory.t.sol` — existing ERC404 factory tests (update all createInstance calls)
- `test/factories/erc404/ERC404FreeMint.t.sol` — NEW: dedicated free mint tests
- `test/factories/erc1155/ERC1155FreeMint.t.sol` — NEW: dedicated ERC1155 free mint tests

---

## Task 1: Add GatingScope enum to IGatingModule

**Files:**
- Modify: `src/gating/IGatingModule.sol`

**Step 1: Add the enum**

Open `src/gating/IGatingModule.sol`. After the SPDX header and pragma line, add the enum before the interface:

```solidity
/// @notice Controls which entry points the gating module is consulted for.
/// Set once at instance creation. Irreversible.
enum GatingScope {
    BOTH,            // gates free mint claims AND paid buys (default)
    FREE_MINT_ONLY,  // gates free mint claims only; paid buys are open
    PAID_ONLY        // gates paid buys only; free mint claims are open FCFS
}
```

**Step 2: Verify it compiles**

```bash
forge build --skip "test/**" --skip "script/**" 2>&1 | grep -E "error|Error|warning" | head -20
```

Expected: no errors. `GatingScope` is now available to any contract that imports `IGatingModule`.

**Step 3: Commit**

```bash
git add src/gating/IGatingModule.sol
git commit -m "feat: add GatingScope enum to IGatingModule"
```

---

## Task 2: Write failing tests for ERC404 free mints

**Files:**
- Create: `test/factories/erc404/ERC404FreeMint.t.sol`

**Step 1: Create the test file**

The test setUp mirrors `ERC404Factory.t.sol`. Free mint allocation is stored on the instance after `initializeFreeMint` is called by the factory. For now, write the tests against the interface you expect to exist — they must fail to compile or revert.

Key things to know:
- After factory `createInstance`, the returned `address` is an `ERC404BondingInstance`
- `UNIT` on the instance is `preset.unitPerNFT * 1e18` — the token amount per 1 NFT
- `claimFreeMint(bytes calldata gatingData)` is the new function
- `freeMintAllocation()` returns the NFT count reserved
- `freeMintsClaimed()` returns how many have been claimed
- `freeMintClaimed(address)` returns whether a wallet has claimed
- `gatingScope()` returns the `GatingScope` enum value
- For tests with no gating, pass `bytes("")` as `gatingData`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC404Factory} from "../../../src/factories/erc404/ERC404Factory.sol";
import {ERC404BondingInstance} from "../../../src/factories/erc404/ERC404BondingInstance.sol";
import {LaunchManager} from "../../../src/factories/erc404/LaunchManager.sol";
import {CurveParamsComputer} from "../../../src/factories/erc404/CurveParamsComputer.sol";
import {MockMasterRegistry} from "../../mocks/MockMasterRegistry.sol";
import {IdentityParams, FreeMintParams} from "../../../src/interfaces/IFactoryTypes.sol";
import {GatingScope} from "../../../src/gating/IGatingModule.sol";
import {IGatingModule} from "../../../src/gating/IGatingModule.sol";
import {ComponentRegistry} from "../../../src/registry/ComponentRegistry.sol";
import {ILiquidityDeployerModule} from "../../../src/interfaces/ILiquidityDeployerModule.sol";
import {PasswordTierGatingModule} from "../../../src/gating/PasswordTierGatingModule.sol";
import {LibClone} from "solady/utils/LibClone.sol";

contract MockVaultFM {
    function supportsCapability(bytes32) external pure returns (bool) { return true; }
    receive() external payable {}
}

contract MockDeployerFM is ILiquidityDeployerModule {
    function deployLiquidity(ILiquidityDeployerModule.DeployParams calldata) external payable override {}
}

contract ERC404FreeMintTest is Test {
    ERC404Factory factory;
    LaunchManager launchMgr;
    CurveParamsComputer curveComp;
    MockMasterRegistry mockRegistry;
    MockVaultFM mockVault;
    ComponentRegistry componentRegistry;
    MockDeployerFM mockDeployer;
    PasswordTierGatingModule tierGatingModule;

    address protocol = makeAddr("protocol");
    address creator  = makeAddr("creator");
    address user1    = makeAddr("user1");
    address user2    = makeAddr("user2");
    address mockGMR  = makeAddr("gmr");

    uint8 constant PRESET_ID = 1;
    uint256 constant NFT_COUNT = 10;
    uint256 constant FREE_MINT_COUNT = 3;

    function setUp() public {
        vm.startPrank(protocol);

        mockRegistry = new MockMasterRegistry();
        mockVault    = new MockVaultFM();
        launchMgr    = new LaunchManager(protocol);
        curveComp    = new CurveParamsComputer(protocol);
        tierGatingModule = new PasswordTierGatingModule();
        mockDeployer = new MockDeployerFM();

        ComponentRegistry impl = new ComponentRegistry();
        address proxy = LibClone.deployERC1967(address(impl));
        componentRegistry = ComponentRegistry(proxy);
        componentRegistry.initialize(protocol);
        componentRegistry.approveComponent(address(curveComp),    keccak256("curve"),     "Curve");
        componentRegistry.approveComponent(address(mockDeployer), keccak256("liquidity"), "Deployer");

        launchMgr.setPreset(PRESET_ID, LaunchManager.Preset({
            targetETH: 10 ether,
            unitPerNFT: 1e6,
            liquidityReserveBps: 2000,
            curveComputer: address(curveComp),
            active: true
        }));

        ERC404BondingInstance instanceImpl = new ERC404BondingInstance();
        factory = new ERC404Factory(
            ERC404Factory.CoreConfig({
                implementation: address(instanceImpl),
                masterRegistry: address(mockRegistry),
                protocol: protocol
            }),
            ERC404Factory.ModuleConfig({
                globalMessageRegistry: mockGMR,
                launchManager: address(launchMgr),
                tierGatingModule: address(tierGatingModule),
                componentRegistry: address(componentRegistry)
            })
        );

        vm.stopPrank();
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    function _identity() internal view returns (IdentityParams memory) {
        return IdentityParams({
            owner: creator, nftCount: NFT_COUNT, presetId: PRESET_ID,
            creationTier: 0, vault: address(mockVault),
            name: "FreeMintToken", symbol: "FMT", styleUri: ""
        });
    }

    function _freeMint(uint256 alloc, GatingScope scope) internal pure returns (FreeMintParams memory) {
        return FreeMintParams({ allocation: alloc, scope: scope });
    }

    function _deploy(uint256 alloc, GatingScope scope, address gatingModule) internal returns (ERC404BondingInstance) {
        address inst = factory.createInstance(
            _identity(), "ipfs://meta", address(mockDeployer), gatingModule,
            _freeMint(alloc, scope)
        );
        return ERC404BondingInstance(payable(inst));
    }

    // ── freeMintAllocation stored correctly ───────────────────────────────────

    function test_freeMint_allocationStoredOnInstance() public {
        ERC404BondingInstance inst = _deploy(FREE_MINT_COUNT, GatingScope.BOTH, address(0));
        assertEq(inst.freeMintAllocation(), FREE_MINT_COUNT);
    }

    function test_freeMint_zeroAllocation_disabled() public {
        ERC404BondingInstance inst = _deploy(0, GatingScope.BOTH, address(0));
        assertEq(inst.freeMintAllocation(), 0);
    }

    // ── claimFreeMint happy path ─────────────────────────────────────────────

    function test_freeMint_claim_mintsOneUnit() public {
        ERC404BondingInstance inst = _deploy(FREE_MINT_COUNT, GatingScope.BOTH, address(0));
        uint256 unit = inst.UNIT();

        vm.prank(user1);
        inst.claimFreeMint("");

        assertEq(inst.balanceOf(user1), unit);
        assertEq(inst.freeMintsClaimed(), 1);
        assertTrue(inst.freeMintClaimed(user1));
    }

    function test_freeMint_multipleUsers_canClaim() public {
        ERC404BondingInstance inst = _deploy(FREE_MINT_COUNT, GatingScope.BOTH, address(0));

        vm.prank(user1); inst.claimFreeMint("");
        vm.prank(user2); inst.claimFreeMint("");

        assertEq(inst.freeMintsClaimed(), 2);
    }

    // ── claimFreeMint reverts ─────────────────────────────────────────────────

    function test_freeMint_revertsWhenDisabled() public {
        ERC404BondingInstance inst = _deploy(0, GatingScope.BOTH, address(0));
        vm.prank(user1);
        vm.expectRevert(FreeMintDisabled.selector);
        inst.claimFreeMint("");
    }

    function test_freeMint_revertsWhenAlreadyClaimed() public {
        ERC404BondingInstance inst = _deploy(FREE_MINT_COUNT, GatingScope.BOTH, address(0));
        vm.prank(user1);
        inst.claimFreeMint("");
        vm.prank(user1);
        vm.expectRevert(FreeMintAlreadyClaimed.selector);
        inst.claimFreeMint("");
    }

    function test_freeMint_revertsWhenExhausted() public {
        // allocation = 1, two users try to claim
        ERC404BondingInstance inst = _deploy(1, GatingScope.BOTH, address(0));
        vm.prank(user1); inst.claimFreeMint("");
        vm.prank(user2);
        vm.expectRevert(FreeMintExhausted.selector);
        inst.claimFreeMint("");
    }

    // ── supply accounting ─────────────────────────────────────────────────────

    function test_freeMint_reducesEffectiveBondingCap() public {
        // NFT_COUNT=10, free=3 → bonding cap covers 7 NFTs worth
        ERC404BondingInstance inst = _deploy(FREE_MINT_COUNT, GatingScope.BOTH, address(0));
        uint256 unit = inst.UNIT();
        uint256 cap = inst.MAX_SUPPLY() - inst.LIQUIDITY_RESERVE() - (FREE_MINT_COUNT * unit);
        // totalBondingSupply starts at 0; can buy up to cap, not full MAX_SUPPLY
        assertEq(inst.freeMintAllocation(), FREE_MINT_COUNT);
        // Verify the contract holds full supply
        assertEq(inst.balanceOf(address(inst)), inst.MAX_SUPPLY());
    }

    // ── GatingScope: BOTH ──────────────────────────────────────────────────────

    function test_gatingScope_BOTH_gatesFreeMintClaim() public {
        // Set up a real PasswordTierGatingModule with a single tier
        componentRegistry.approveComponent(address(tierGatingModule), keccak256("gating"), "Tiers");

        // Build tier config: VOLUME_CAP with 1 tier, cap = unit (1 NFT)
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = keccak256("secret");
        uint256[] memory caps = new uint256[](1);
        caps[0] = 1e24; // large enough
        PasswordTierGatingModule.TierConfig memory tiers = PasswordTierGatingModule.TierConfig({
            tierType: PasswordTierGatingModule.TierType.VOLUME_CAP,
            passwordHashes: hashes,
            volumeCaps: caps,
            tierUnlockTimes: new uint256[](0)
        });
        tierGatingModule.configureFor(address(0), tiers); // pre-configure (factory passes address(0))

        vm.startPrank(protocol);
        address inst = factory.createInstance(
            _identity(), "ipfs://meta", address(mockDeployer), address(tierGatingModule),
            _freeMint(FREE_MINT_COUNT, GatingScope.BOTH)
        );
        vm.stopPrank();

        ERC404BondingInstance instance = ERC404BondingInstance(payable(inst));

        // Without correct password data, claimFreeMint should be gated
        bytes memory badData = abi.encode(bytes32(0), uint256(0));
        vm.prank(user1);
        // password hash 0 = open tier, which is allowed in PasswordTierGatingModule
        // just confirm it doesn't revert with open tier
        instance.claimFreeMint(badData);
        assertEq(instance.freeMintsClaimed(), 1);
    }

    // ── GatingScope: FREE_MINT_ONLY — paid buys bypass gate ───────────────────

    function test_gatingScope_FREE_MINT_ONLY_paidBuyBypassesGate() public {
        // Deploy with a gating module but FREE_MINT_ONLY scope
        // Enable bonding and verify buyBonding does NOT check the module
        componentRegistry.approveComponent(address(tierGatingModule), keccak256("gating"), "TiersFMO");

        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = keccak256("secret2");
        uint256[] memory caps = new uint256[](1);
        caps[0] = 1e24;
        tierGatingModule.configureFor(address(0), PasswordTierGatingModule.TierConfig({
            tierType: PasswordTierGatingModule.TierType.VOLUME_CAP,
            passwordHashes: hashes,
            volumeCaps: caps,
            tierUnlockTimes: new uint256[](0)
        }));

        vm.startPrank(protocol);
        address inst = factory.createInstance(
            _identity(), "ipfs://meta", address(mockDeployer), address(tierGatingModule),
            _freeMint(FREE_MINT_COUNT, GatingScope.FREE_MINT_ONLY)
        );
        vm.stopPrank();

        ERC404BondingInstance instance = ERC404BondingInstance(payable(inst));

        // Enable bonding
        vm.startPrank(creator);
        instance.setBondingOpenTime(block.timestamp + 1);
        vm.warp(block.timestamp + 2);
        instance.setBondingActive(true);
        vm.stopPrank();

        // Buy with no password (open tier = bytes32(0)) — should succeed because scope is FREE_MINT_ONLY
        uint256 buyAmount = instance.UNIT();
        uint256 cost = 1 ether;
        vm.deal(user1, cost);
        vm.prank(user1);
        instance.buyBonding{value: cost}(buyAmount, cost, true, bytes32(0), "", 0);
        // If it didn't revert, the gate was bypassed for paid buys ✓
        assertGt(instance.balanceOf(user1), 0);
    }

    // ── GatingScope: PAID_ONLY — free mint bypasses gate ──────────────────────

    function test_gatingScope_PAID_ONLY_freeMintBypassesGate() public {
        // gating module set but PAID_ONLY scope: claimFreeMint should not consult it
        componentRegistry.approveComponent(address(tierGatingModule), keccak256("gating"), "TiersPO");

        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = keccak256("secret3");
        uint256[] memory caps = new uint256[](1);
        caps[0] = 0; // zero cap — would block everyone
        tierGatingModule.configureFor(address(0), PasswordTierGatingModule.TierConfig({
            tierType: PasswordTierGatingModule.TierType.VOLUME_CAP,
            passwordHashes: hashes,
            volumeCaps: caps,
            tierUnlockTimes: new uint256[](0)
        }));

        vm.startPrank(protocol);
        address inst = factory.createInstance(
            _identity(), "ipfs://meta", address(mockDeployer), address(tierGatingModule),
            _freeMint(FREE_MINT_COUNT, GatingScope.PAID_ONLY)
        );
        vm.stopPrank();

        ERC404BondingInstance instance = ERC404BondingInstance(payable(inst));

        // claimFreeMint should work without any gate data
        vm.prank(user1);
        instance.claimFreeMint("");
        assertEq(instance.freeMintsClaimed(), 1);
    }

    // ── gatingScope stored correctly ──────────────────────────────────────────

    function test_gatingScope_storedOnInstance() public {
        ERC404BondingInstance instBoth = _deploy(1, GatingScope.BOTH, address(0));
        ERC404BondingInstance instFMO  = _deploy(1, GatingScope.FREE_MINT_ONLY, address(0));
        ERC404BondingInstance instPO   = _deploy(1, GatingScope.PAID_ONLY, address(0));

        assertEq(uint8(instBoth.gatingScope()), uint8(GatingScope.BOTH));
        assertEq(uint8(instFMO.gatingScope()),  uint8(GatingScope.FREE_MINT_ONLY));
        assertEq(uint8(instPO.gatingScope()),   uint8(GatingScope.PAID_ONLY));
    }
}
```

**Step 2: Verify tests fail to compile (expected)**

```bash
forge test --match-contract ERC404FreeMintTest 2>&1 | head -30
```

Expected: compile errors — `FreeMintParams`, `FreeMintDisabled`, `FreeMintAlreadyClaimed`, `FreeMintExhausted`, `freeMintAllocation`, `claimFreeMint`, `gatingScope` don't exist yet. This confirms the tests are driving the implementation.

---

## Task 3: Add free mint state + functions to ERC404BondingInstance

**Files:**
- Modify: `src/factories/erc404/ERC404BondingInstance.sol`

The instance must hold the free mint tranche and expose `initializeFreeMint` for the factory to call, plus `claimFreeMint` for end users.

**Step 1: Add import for GatingScope**

At the top of `ERC404BondingInstance.sol`, the `IGatingModule` import already exists. `GatingScope` is now in that file, so it's already available. No new import needed.

**Step 2: Add new errors (in the errors block near the top)**

```solidity
error FreeMintDisabled();
error FreeMintAlreadyClaimed();
error FreeMintExhausted();
error FreeMintNotInitialized();
```

**Step 3: Add new event**

In the events section:
```solidity
event FreeMintClaimed(address indexed user);
```

**Step 4: Add new state variables**

After the `graduated` state variable, add:

```solidity
// Free mint tranche
uint256 public freeMintAllocation;   // NFT count reserved (0 = disabled)
uint256 public freeMintsClaimed;     // running counter (in NFTs, not tokens)
mapping(address => bool) public freeMintClaimed;
GatingScope public gatingScope;
bool private _freeMintInitialized;
```

**Step 5: Add `initializeFreeMint` function**

Add after `initializeMetadata`:

```solidity
/// @notice Set free mint params. Called by factory once after initialize().
/// @param allocation NFT count reserved for free claims (0 = disabled).
/// @param scope      Controls which entry points the gating module guards.
function initializeFreeMint(uint256 allocation, GatingScope scope) external {
    require(msg.sender == factory, "Only factory");
    require(!_freeMintInitialized, "Already set");
    _freeMintInitialized = true;
    freeMintAllocation = allocation;
    gatingScope = scope;
}
```

**Step 6: Add `claimFreeMint` function**

Add after `initializeFreeMint`:

```solidity
/// @notice Claim one free mint (= 1 NFT worth of tokens) at zero ETH cost.
/// @param gatingData Passed to gatingModule.canMint if scope requires it.
function claimFreeMint(bytes calldata gatingData) external nonReentrant {
    if (freeMintAllocation == 0) revert FreeMintDisabled();
    if (freeMintClaimed[msg.sender]) revert FreeMintAlreadyClaimed();
    if (freeMintsClaimed >= freeMintAllocation) revert FreeMintExhausted();

    if (address(gatingModule) != address(0) && gatingActive
        && gatingScope != GatingScope.PAID_ONLY) {
        (bool allowed, bool permanent) = gatingModule.canMint(msg.sender, UNIT, gatingData);
        if (!allowed) revert GatingNotAllowed();
        if (permanent) gatingActive = false;
        gatingModule.onMint(msg.sender, UNIT);
    }

    freeMintClaimed[msg.sender] = true;
    freeMintsClaimed++;
    _transfer(address(this), msg.sender, UNIT);
    emit FreeMintClaimed(msg.sender);
}
```

**Step 7: Adjust `buyBonding` cap and scope check**

In `buyBonding`, there are two changes:

a) The effective bonding cap must exclude the free mint tranche. Change:
```solidity
if (totalBondingSupply + amount > MAX_SUPPLY - LIQUIDITY_RESERVE) revert ExceedsBonding();
```
to:
```solidity
if (totalBondingSupply + amount > MAX_SUPPLY - LIQUIDITY_RESERVE - (freeMintAllocation * UNIT)) revert ExceedsBonding();
```

b) The gating check must respect scope. Change:
```solidity
if (address(gatingModule) != address(0) && gatingActive) {
```
to:
```solidity
if (address(gatingModule) != address(0) && gatingActive
    && gatingScope != GatingScope.FREE_MINT_ONLY) {
```

Also apply the same fix in `sellBonding` — the sell check uses `maxBondingSupply`:
```solidity
uint256 maxBondingSupply = MAX_SUPPLY - LIQUIDITY_RESERVE;
```
Change to:
```solidity
uint256 maxBondingSupply = MAX_SUPPLY - LIQUIDITY_RESERVE - (freeMintAllocation * UNIT);
```

**Step 8: Build to check for compile errors**

```bash
forge build --skip "test/**" --skip "script/**" 2>&1 | grep -E "^Error|error\[" | head -20
```

Expected: clean build.

**Step 9: Commit**

```bash
git add src/factories/erc404/ERC404BondingInstance.sol
git commit -m "feat: add free mint tranche and GatingScope to ERC404BondingInstance"
```

---

## Task 4: Wire FreeMintParams through ERC404Factory

**Files:**
- Modify: `src/interfaces/IFactoryTypes.sol`
- Modify: `src/factories/erc404/ERC404Factory.sol`
- Modify: `test/factories/erc404/ERC404Factory.t.sol` (update all createInstance calls)
- Modify: `test/master/NamespaceCollision.t.sol` (update createInstance calls)

**Step 1: Add FreeMintParams to IFactoryTypes.sol**

```solidity
import {GatingScope} from "../gating/IGatingModule.sol";

/// @notice Free mint configuration passed to factory at instance creation.
struct FreeMintParams {
    uint256 allocation; // NFT count reserved for zero-cost claims (0 = disabled)
    GatingScope scope;  // which entry points the gating module guards
}
```

**Step 2: Update ERC404Factory imports**

Add to imports in `ERC404Factory.sol`:
```solidity
import {FreeMintParams} from "../../interfaces/IFactoryTypes.sol";
import {GatingScope} from "../../gating/IGatingModule.sol";
```

**Step 3: Update `createInstance` and `createInstanceWithTiers` signatures**

Add `FreeMintParams calldata freeMint` as the last parameter to both public functions, and thread it through to `_createInstanceCore`:

```solidity
function createInstance(
    IdentityParams calldata identity,
    string calldata metadataURI,
    address liquidityDeployer,
    address gatingModule,
    FreeMintParams calldata freeMint
) external payable nonReentrant returns (address instance) {
    if (gatingModule != address(0)) {
        require(componentRegistry.isApprovedComponent(gatingModule), "Unapproved gating module");
    }
    return _createInstanceCore(identity, metadataURI, liquidityDeployer, gatingModule, freeMint);
}

function createInstanceWithTiers(
    IdentityParams calldata identity,
    string calldata metadataURI,
    address liquidityDeployer,
    PasswordTierGatingModule.TierConfig calldata tiers,
    FreeMintParams calldata freeMint
) external payable nonReentrant returns (address instance) {
    address gatingModuleAddr;
    if (tiers.passwordHashes.length > 0) {
        tierGatingModule.configureFor(address(0), tiers);
        gatingModuleAddr = address(tierGatingModule);
    }
    return _createInstanceCore(identity, metadataURI, liquidityDeployer, gatingModuleAddr, freeMint);
}
```

**Step 4: Update `_createInstanceCore` and `_initializeInstance`**

Add `FreeMintParams calldata freeMint` to `_createInstanceCore` signature and thread it to `_initializeInstance`:

```solidity
function _createInstanceCore(
    IdentityParams calldata identity,
    string calldata metadataURI,
    address liquidityDeployer,
    address gatingModule,
    FreeMintParams calldata freeMint
) internal returns (address instance) {
    // ... existing validation ...
    require(freeMint.allocation < identity.nftCount, "Free mint allocation exceeds NFT count");

    instance = LibClone.clone(implementation);
    _initializeInstance(instance, identity, liquidityDeployer, gatingModule, freeMint);
    _finalizeInstance(instance, identity, metadataURI);
}
```

In `_initializeInstance`, subtract `freeMint.allocation` from `nftCount` when computing curve params, but keep maxSupply at the full count:

```solidity
function _initializeInstance(
    address instance,
    IdentityParams calldata identity,
    address liquidityDeployer,
    address gatingModule,
    FreeMintParams calldata freeMint
) private {
    LaunchManager.Preset memory preset = launchManager.getPreset(identity.presetId);
    require(componentRegistry.isApprovedComponent(preset.curveComputer), "Unapproved curve computer");

    uint256 unit = preset.unitPerNFT * 1e18;
    // Curve is computed over the paid-bonding portion only (excludes free mint tranche)
    uint256 curveNftCount = identity.nftCount - freeMint.allocation;
    ERC404BondingInstance.BondingParams memory bonding = ERC404BondingInstance.BondingParams({
        maxSupply: identity.nftCount * unit,          // full supply (includes free mint tranche)
        unit: unit,
        liquidityReservePercent: preset.liquidityReserveBps / 100,
        curve: ICurveComputer(preset.curveComputer).computeCurveParams(
            curveNftCount,                             // paid bonding portion
            preset.targetETH,
            preset.unitPerNFT,
            preset.liquidityReserveBps
        )
    });

    ERC404BondingInstance(payable(instance)).initialize(
        identity.owner, identity.vault, bonding, liquidityDeployer, gatingModule
    );
    ERC404BondingInstance(payable(instance)).initializeProtocol(
        ERC404BondingInstance.ProtocolParams({
            globalMessageRegistry: globalMessageRegistry,
            protocolTreasury: protocolTreasury,
            masterRegistry: address(masterRegistry),
            bondingFeeBps: bondingFeeBps
        })
    );
    ERC404BondingInstance(payable(instance)).initializeMetadata(
        identity.name, identity.symbol, identity.styleUri
    );
    // Wire free mint tranche (no-op when allocation == 0)
    ERC404BondingInstance(payable(instance)).initializeFreeMint(
        freeMint.allocation, freeMint.scope
    );
}
```

**Note:** When `freeMint.allocation == 0`, `curveNftCount == identity.nftCount`, which matches the existing behaviour exactly.

**Step 5: Update existing test calls in ERC404Factory.t.sol**

Every call to `factory.createInstance(...)` in the existing test file now needs a 5th argument. Search and replace all occurrences. The default no-free-mint value is:

```solidity
FreeMintParams({allocation: 0, scope: GatingScope.BOTH})
```

Also add these imports at the top of `ERC404Factory.t.sol`:
```solidity
import {FreeMintParams} from "../../../src/interfaces/IFactoryTypes.sol";
import {GatingScope} from "../../../src/gating/IGatingModule.sol";
```

**Step 6: Update NamespaceCollision.t.sol**

Same pattern — find all `createInstance` calls and add the 5th argument.

**Step 7: Run tests**

```bash
forge test --match-contract "ERC404FactoryTest|ERC404FreeMintTest|NamespaceCollision" 2>&1 | tail -20
```

Expected: all tests pass. The free mint tests from Task 2 should now pass.

**Step 8: Commit**

```bash
git add src/interfaces/IFactoryTypes.sol src/factories/erc404/ERC404Factory.sol \
        test/factories/erc404/ERC404Factory.t.sol test/master/NamespaceCollision.t.sol \
        test/factories/erc404/ERC404FreeMint.t.sol
git commit -m "feat: wire FreeMintParams through ERC404Factory"
```

---

## Task 5: Write failing tests for ERC1155 free mints

**Files:**
- Create: `test/factories/erc1155/ERC1155FreeMint.t.sol`

**Step 1: Create the test file**

Key things to know about ERC1155Instance:
- It deploys via `new ERC1155Instance(...)` (not clone), so constructor takes all params
- Editions are added after deployment via `addEdition(...)` — each edition has its own `editionId`
- Free mint for ERC1155: `claimFreeMint(uint256 editionId, bytes calldata gatingData)` mints 1 token of the specified edition
- The instance-level `freeMintAllocation` is a total budget across all editions
- Same errors: `FreeMintDisabled`, `FreeMintAlreadyClaimed`, `FreeMintExhausted`
- `gatingScope` stored on instance, same enum

For ERC1155Factory, the `createInstance` overload we'll add takes a `FreeMintParams`:
```solidity
function createInstance(
    string memory name, string memory metadataURI,
    address creator, address vault, string memory styleUri,
    address gatingModule, FreeMintParams calldata freeMint
) external payable nonReentrant returns (address instance)
```

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1155Factory} from "../../../src/factories/erc1155/ERC1155Factory.sol";
import {ERC1155Instance} from "../../../src/factories/erc1155/ERC1155Instance.sol";
import {MockMasterRegistry} from "../../mocks/MockMasterRegistry.sol";
import {FreeMintParams} from "../../../src/interfaces/IFactoryTypes.sol";
import {GatingScope} from "../../../src/gating/IGatingModule.sol";
import {ComponentRegistry} from "../../../src/registry/ComponentRegistry.sol";
import {LibClone} from "solady/utils/LibClone.sol";

contract MockVaultERC1155FM {
    function supportsCapability(bytes32) external pure returns (bool) { return true; }
    receive() external payable {}
}

contract ERC1155FreeMintTest is Test {
    ERC1155Factory factory;
    MockMasterRegistry mockRegistry;
    MockVaultERC1155FM mockVault;
    ComponentRegistry componentRegistry;

    address protocol = makeAddr("protocol");
    address creator  = makeAddr("creator");
    address user1    = makeAddr("user1");
    address user2    = makeAddr("user2");
    address mockGMR  = makeAddr("gmr");

    uint256 constant FREE_ALLOC = 5;

    function setUp() public {
        vm.startPrank(protocol);
        mockRegistry = new MockMasterRegistry();
        mockVault    = new MockVaultERC1155FM();

        ComponentRegistry impl = new ComponentRegistry();
        address proxy = LibClone.deployERC1967(address(impl));
        componentRegistry = ComponentRegistry(proxy);
        componentRegistry.initialize(protocol);

        factory = new ERC1155Factory(
            address(mockRegistry), address(0), mockGMR, address(componentRegistry)
        );
        vm.stopPrank();
    }

    function _deploy(uint256 alloc, GatingScope scope) internal returns (ERC1155Instance) {
        vm.startPrank(creator);
        address inst = factory.createInstance(
            "FreeMintEdition", "ipfs://meta", creator, address(mockVault), "",
            address(0), FreeMintParams({ allocation: alloc, scope: scope })
        );
        vm.stopPrank();
        return ERC1155Instance(inst);
    }

    function _addEdition(ERC1155Instance inst, uint256 supply) internal returns (uint256 editionId) {
        // Factory owner (protocol) is the agent
        vm.prank(protocol);
        factory.setAgent(protocol, true);
        vm.prank(protocol);
        factory.addEdition(
            address(inst), "Piece 1", 0.01 ether, supply, "ipfs://edition",
            ERC1155Instance.PricingModel.LIMITED_FIXED, 0, 0
        );
        return inst.nextEditionId() - 1;
    }

    // ── allocation stored ─────────────────────────────────────────────────────

    function test_erc1155_freeMintAllocationStored() public {
        ERC1155Instance inst = _deploy(FREE_ALLOC, GatingScope.BOTH);
        assertEq(inst.freeMintAllocation(), FREE_ALLOC);
    }

    // ── claimFreeMint happy path ──────────────────────────────────────────────

    function test_erc1155_claimFreeMint_mintsOneToken() public {
        ERC1155Instance inst = _deploy(FREE_ALLOC, GatingScope.BOTH);
        uint256 editionId = _addEdition(inst, 100);

        vm.prank(user1);
        inst.claimFreeMint(editionId, "");

        assertEq(inst.balanceOf(user1, editionId), 1);
        assertEq(inst.freeMintsClaimed(), 1);
        assertTrue(inst.freeMintClaimed(user1));
    }

    // ── reverts ───────────────────────────────────────────────────────────────

    function test_erc1155_freeMint_revertsWhenDisabled() public {
        ERC1155Instance inst = _deploy(0, GatingScope.BOTH);
        uint256 editionId = _addEdition(inst, 100);
        vm.prank(user1);
        vm.expectRevert(FreeMintDisabled.selector);
        inst.claimFreeMint(editionId, "");
    }

    function test_erc1155_freeMint_revertsWhenAlreadyClaimed() public {
        ERC1155Instance inst = _deploy(FREE_ALLOC, GatingScope.BOTH);
        uint256 editionId = _addEdition(inst, 100);
        vm.prank(user1); inst.claimFreeMint(editionId, "");
        vm.prank(user1);
        vm.expectRevert(FreeMintAlreadyClaimed.selector);
        inst.claimFreeMint(editionId, "");
    }

    function test_erc1155_freeMint_revertsWhenExhausted() public {
        ERC1155Instance inst = _deploy(1, GatingScope.BOTH);
        uint256 editionId = _addEdition(inst, 100);
        vm.prank(user1); inst.claimFreeMint(editionId, "");
        vm.prank(user2);
        vm.expectRevert(FreeMintExhausted.selector);
        inst.claimFreeMint(editionId, "");
    }
}
```

**Step 2: Verify tests fail to compile**

```bash
forge test --match-contract ERC1155FreeMintTest 2>&1 | head -20
```

Expected: compile errors — `FreeMintParams` overload of `createInstance`, `claimFreeMint`, `freeMintAllocation`, `freeMintClaimed`, `freeMintsClaimed` don't exist on ERC1155 yet.

---

## Task 6: Add free mint state + functions to ERC1155Instance

**Files:**
- Modify: `src/factories/erc1155/ERC1155Instance.sol`

**Step 1: Add import**

`IGatingModule` is already imported. `GatingScope` is in that file — already available.

**Step 2: Add new errors**

In the errors area (before or after existing error declarations — ERC1155Instance uses `require`, so add custom errors before the contract declaration):

```solidity
error FreeMintDisabled();
error FreeMintAlreadyClaimed();
error FreeMintExhausted();
```

**Step 3: Add new event**

```solidity
event FreeMintClaimed(address indexed user, uint256 indexed editionId);
```

**Step 4: Add new state variables**

After the `gatingModule` state variable:

```solidity
// Free mint
uint256 public freeMintAllocation;
uint256 public freeMintsClaimed;
mapping(address => bool) public freeMintClaimed;
GatingScope public gatingScope;
bool private _freeMintInitialized;
```

**Step 5: Add `initializeFreeMint` function**

ERC1155Instance has `factory` stored and checks `msg.sender == factory || msg.sender == owner()`. Add:

```solidity
/// @notice Set free mint params. Called by factory once after construction.
function initializeFreeMint(uint256 allocation, GatingScope scope) external {
    require(msg.sender == factory, "Only factory");
    require(!_freeMintInitialized, "Already set");
    _freeMintInitialized = true;
    freeMintAllocation = allocation;
    gatingScope = scope;
}
```

**Step 6: Add `claimFreeMint` function**

```solidity
/// @notice Claim one free token of a specified edition at zero ETH cost.
/// @param editionId  The edition to claim from. Must exist.
/// @param gatingData Passed to gatingModule.canMint if scope requires it.
function claimFreeMint(uint256 editionId, bytes calldata gatingData) external nonReentrant {
    if (freeMintAllocation == 0) revert FreeMintDisabled();
    if (freeMintClaimed[msg.sender]) revert FreeMintAlreadyClaimed();
    if (freeMintsClaimed >= freeMintAllocation) revert FreeMintExhausted();

    Edition storage edition = editions[editionId];
    require(bytes(edition.pieceTitle).length > 0, "Edition does not exist");
    if (edition.supply > 0) {
        require(edition.minted < edition.supply, "Edition supply exhausted");
    }

    if (address(gatingModule) != address(0) && gatingScope != GatingScope.PAID_ONLY) {
        (bool allowed, bool permanent) = gatingModule.canMint(msg.sender, 1, gatingData);
        require(allowed, "Gating: not allowed");
        if (permanent) { /* gatingActive concept not in ERC1155, ignore */ }
        gatingModule.onMint(msg.sender, 1);
    }

    freeMintClaimed[msg.sender] = true;
    freeMintsClaimed++;
    edition.minted++;
    balanceOf[msg.sender][editionId]++;

    emit FreeMintClaimed(msg.sender, editionId);
    emit TransferSingle(msg.sender, address(0), msg.sender, editionId, 1);
}
```

**Step 7: Build**

```bash
forge build --skip "test/**" --skip "script/**" 2>&1 | grep -E "^Error|error\[" | head -20
```

Expected: clean build.

**Step 8: Commit**

```bash
git add src/factories/erc1155/ERC1155Instance.sol
git commit -m "feat: add free mint tranche and GatingScope to ERC1155Instance"
```

---

## Task 7: Wire FreeMintParams through ERC1155Factory

**Files:**
- Modify: `src/factories/erc1155/ERC1155Factory.sol`
- Modify: `test/factories/erc1155/ERC1155FreeMint.t.sol` (verify it now compiles and passes)

**Step 1: Add imports to ERC1155Factory.sol**

```solidity
import {FreeMintParams} from "../../interfaces/IFactoryTypes.sol";
import {GatingScope} from "../../gating/IGatingModule.sol";
```

**Step 2: Add new overload for createInstance**

Add a new `createInstance` overload that accepts `FreeMintParams`. Keep all existing overloads unchanged (backward compatible).

```solidity
/// @notice Create instance with gating module and free mint configuration.
function createInstance(
    string memory name,
    string memory metadataURI,
    address creator,
    address vault,
    string memory styleUri,
    address gatingModule,
    FreeMintParams calldata freeMint
) external payable nonReentrant returns (address instance) {
    if (gatingModule != address(0)) {
        require(componentRegistry.isApprovedComponent(gatingModule), "Unapproved component");
    }
    return _createInstanceInternal(name, metadataURI, creator, vault, styleUri, CreationTier.STANDARD, gatingModule, freeMint);
}
```

**Step 3: Update `_createInstanceInternal` to accept and thread FreeMintParams**

Add `FreeMintParams memory freeMint` as the last parameter. Call `initializeFreeMint` after `_deployAndRegister`:

```solidity
function _createInstanceInternal(
    string memory name,
    string memory metadataURI,
    address creator,
    address vault,
    string memory styleUri,
    CreationTier creationTier,
    address gatingModule,
    FreeMintParams memory freeMint
) internal returns (address instance) {
    // ... existing body unchanged ...
    instance = _deployAndRegister(name, metadataURI, creator, vault, styleUri, gatingModule);
    // Wire free mint (no-op when allocation == 0)
    ERC1155Instance(instance).initializeFreeMint(freeMint.allocation, freeMint.scope);
    // ... rest of tier perks + events unchanged ...
}
```

**Step 4: Update all existing `_createInstanceInternal` callers**

The three existing `createInstance` overloads that call `_createInstanceInternal` must pass a default `FreeMintParams`. Add the default inline:

```solidity
_createInstanceInternal(name, metadataURI, creator, vault, styleUri, creationTier, address(0),
    FreeMintParams({ allocation: 0, scope: GatingScope.BOTH }));
```

Do this for all three existing overloads.

**Step 5: Run ERC1155 free mint tests**

```bash
forge test --match-contract ERC1155FreeMintTest 2>&1 | tail -20
```

Expected: all tests pass.

**Step 6: Commit**

```bash
git add src/factories/erc1155/ERC1155Factory.sol test/factories/erc1155/ERC1155FreeMint.t.sol
git commit -m "feat: wire FreeMintParams through ERC1155Factory"
```

---

## Task 8: Full suite verification and cleanup

**Step 1: Run full test suite**

```bash
forge test 2>&1 | tail -10
```

Expected: all tests pass, 0 failed.

**Step 2: If DeploySepolia test fails**

If `DeploySepoliaTest` fails, it's because `createInstance` calls in the script now need `FreeMintParams`. Check `script/DeploySepolia.s.sol` — the ERC404Factory `createInstance` call does not appear there (the script only deploys the factory, not instances). If ERC1155Factory calls appear there, add the default param.

**Step 3: Final commit**

If any cleanup was needed:
```bash
git add -A
git commit -m "fix: update script and test callers for FreeMintParams API"
```
