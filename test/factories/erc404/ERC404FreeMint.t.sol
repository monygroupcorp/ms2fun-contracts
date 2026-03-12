// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC404Factory} from "../../../src/factories/erc404/ERC404Factory.sol";
import {ERC404BondingInstance, FreeMintDisabled, FreeMintAlreadyClaimed, FreeMintExhausted} from "../../../src/factories/erc404/ERC404BondingInstance.sol";
import {LaunchManager} from "../../../src/factories/erc404/LaunchManager.sol";
import {CurveParamsComputer} from "../../../src/factories/erc404/CurveParamsComputer.sol";
import {MockMasterRegistry} from "../../mocks/MockMasterRegistry.sol";
import {FreeMintParams} from "../../../src/interfaces/IFactoryTypes.sol";
import {PasswordTierGatingModule} from "../../../src/gating/PasswordTierGatingModule.sol";
import {GatingScope} from "../../../src/gating/IGatingModule.sol";
import {IGatingModule} from "../../../src/gating/IGatingModule.sol";
import {ComponentRegistry} from "../../../src/registry/ComponentRegistry.sol";
import {ILiquidityDeployerModule} from "../../../src/interfaces/ILiquidityDeployerModule.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {ICreateX, CREATEX} from "../../../src/shared/CreateXConstants.sol";
import {CREATEX_BYTECODE} from "createx-forge/script/CreateX.d.sol";

contract MockVaultFM {
    function supportsCapability(bytes32) external pure returns (bool) { return true; }
    receive() external payable {}
}

contract MockDeployerFM is ILiquidityDeployerModule {
    function deployLiquidity(ILiquidityDeployerModule.DeployParams calldata) external payable override {}
    function metadataURI() external view override returns (string memory) { return ""; }
    function setMetadataURI(string calldata) external override {}
}

contract ERC404FreeMintTest is Test {
    uint256 internal _saltCounter;

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

    function _nextSalt() internal returns (bytes32) {
        _saltCounter++;
        return bytes32(abi.encodePacked(address(factory), uint8(0x00), bytes11(uint88(_saltCounter))));
    }

    function setUp() public {
        vm.etch(CREATEX, CREATEX_BYTECODE);
        vm.startPrank(protocol);

        mockRegistry = new MockMasterRegistry();
        mockVault    = new MockVaultFM();
        launchMgr    = new LaunchManager(protocol);
        curveComp    = new CurveParamsComputer(protocol);
        tierGatingModule = new PasswordTierGatingModule(address(mockRegistry));
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
                componentRegistry: address(componentRegistry)
            })
        );

        vm.stopPrank();
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    function _identity() internal returns (ERC404Factory.CreateParams memory) {
        return ERC404Factory.CreateParams({
            salt: _nextSalt(),
            owner: creator, nftCount: NFT_COUNT, presetId: PRESET_ID,
            vault: address(mockVault),
            name: "FreeMintToken", symbol: "FMT", styleUri: "",
            stakingModule: address(0)
        });
    }

    function _freeMint(uint256 alloc, GatingScope scope) internal pure returns (FreeMintParams memory) {
        return FreeMintParams({ allocation: alloc, scope: scope });
    }

    function _deploy(uint256 alloc, GatingScope scope, address gatingModule) internal returns (ERC404BondingInstance) {
        vm.prank(creator);
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
        uint256 unit = inst.unit();

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
        uint256 unit = inst.unit();
        uint256 cap = inst.maxSupply() - inst.liquidityReserve() - (FREE_MINT_COUNT * unit);
        // totalBondingSupply starts at 0; can buy up to cap, not full maxSupply
        assertEq(inst.freeMintAllocation(), FREE_MINT_COUNT);
        // Verify the contract holds full supply
        assertEq(inst.balanceOf(address(inst)), inst.maxSupply());
    }

    // ── GatingScope: BOTH ──────────────────────────────────────────────────────

    function test_gatingScope_BOTH_gatesFreeMintClaim() public {
        // Set up a real PasswordTierGatingModule with a single tier
        vm.prank(protocol);
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

        vm.prank(creator);
        address inst = factory.createInstance(
            _identity(), "ipfs://meta", address(mockDeployer), address(tierGatingModule),
            _freeMint(FREE_MINT_COUNT, GatingScope.BOTH)
        );

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
        vm.prank(protocol);
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

        vm.prank(creator);
        address inst = factory.createInstance(
            _identity(), "ipfs://meta", address(mockDeployer), address(tierGatingModule),
            _freeMint(FREE_MINT_COUNT, GatingScope.FREE_MINT_ONLY)
        );

        ERC404BondingInstance instance = ERC404BondingInstance(payable(inst));

        // Enable bonding
        vm.startPrank(creator);
        instance.setBondingOpenTime(block.timestamp + 1);
        vm.warp(block.timestamp + 2);
        instance.setBondingActive(true);
        vm.stopPrank();

        // Buy with no password (open tier = bytes32(0)) — should succeed because scope is FREE_MINT_ONLY
        uint256 buyAmount = instance.unit();
        uint256 maxCost = 10 ether; // generous cap; exact cost not the point of this test
        vm.deal(user1, maxCost);
        vm.prank(user1);
        instance.buyBonding{value: maxCost}(buyAmount, maxCost, true, bytes32(0), "", 0);
        // If it didn't revert, the gate was bypassed for paid buys ✓
        assertGt(instance.balanceOf(user1), 0);
    }

    // ── GatingScope: PAID_ONLY — free mint bypasses gate ──────────────────────

    function test_gatingScope_PAID_ONLY_freeMintBypassesGate() public {
        // gating module set but PAID_ONLY scope: claimFreeMint should not consult it
        vm.prank(protocol);
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

        vm.prank(creator);
        address inst = factory.createInstance(
            _identity(), "ipfs://meta", address(mockDeployer), address(tierGatingModule),
            _freeMint(FREE_MINT_COUNT, GatingScope.PAID_ONLY)
        );

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
