// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {ERC404Factory} from "../../../src/factories/erc404/ERC404Factory.sol";
import {ERC404BondingInstance} from "../../../src/factories/erc404/ERC404BondingInstance.sol";
import {LaunchManager} from "../../../src/factories/erc404/LaunchManager.sol";
import {CurveParamsComputer} from "../../../src/factories/erc404/CurveParamsComputer.sol";
import {MockMasterRegistry} from "../../mocks/MockMasterRegistry.sol";
import {BondingCurveMath} from "../../../src/factories/erc404/libraries/BondingCurveMath.sol";
import {FreeMintParams} from "../../../src/interfaces/IFactoryTypes.sol";
import {GatingScope} from "../../../src/gating/IGatingModule.sol";
import {ComponentRegistry} from "../../../src/registry/ComponentRegistry.sol";
import {PasswordTierGatingModule} from "../../../src/gating/PasswordTierGatingModule.sol";
import {ILiquidityDeployerModule} from "../../../src/interfaces/ILiquidityDeployerModule.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {ICreateX, CREATEX} from "../../../src/shared/CreateXConstants.sol";
import {CREATEX_BYTECODE} from "createx-forge/script/CreateX.d.sol";

contract MockVault {
    function supportsCapability(bytes32) external pure returns (bool) { return true; }
    receive() external payable {}
}

/// @dev Plain vault with no hook() function
contract PlainVault {
    function supportsCapability(bytes32) external pure returns (bool) { return true; }
    receive() external payable {}
}

/// @dev Minimal mock liquidity deployer — just accepts the call
contract MockLiquidityDeployer is ILiquidityDeployerModule {
    bool public called;
    function deployLiquidity(ILiquidityDeployerModule.DeployParams calldata) external payable override {
        called = true;
    }
    function metadataURI() external view override returns (string memory) { return ""; }
    function setMetadataURI(string calldata) external override {}
}

contract ERC404FactoryTest is Test {
    ERC404Factory public factory;
    LaunchManager public launchMgr;
    CurveParamsComputer public curveComp;
    MockMasterRegistry public mockRegistry;
    MockVault public mockVault;
    ComponentRegistry public componentRegistry;
    MockLiquidityDeployer public mockDeployer;

    uint256 internal _saltCounter;

    address public protocolAdmin = address(0x9);
    address public creator1 = address(0x2);
    address public creator2 = address(0x3);
    address public nonOwner = address(0x5);

    address public mockGMR = address(0x5555555555555555555555555555555555555555);

    uint256 constant INSTANCE_CREATION_FEE = 0.01 ether;
    uint256 constant DEFAULT_NFT_COUNT = 10;
    uint256 constant DEFAULT_PRESET_ID = 1;

    event InstanceCreated(
        address indexed instance,
        address indexed creator,
        string name,
        string symbol,
        address indexed vault
    );

    function _nextSalt() internal returns (bytes32) {
        _saltCounter++;
        return bytes32(abi.encodePacked(address(factory), uint8(0x00), bytes11(uint88(_saltCounter))));
    }

    function setUp() public {
        vm.etch(CREATEX, CREATEX_BYTECODE);
        vm.startPrank(protocolAdmin);

        mockRegistry = new MockMasterRegistry();
        mockVault = new MockVault();
        launchMgr = new LaunchManager(protocolAdmin);
        curveComp = new CurveParamsComputer(protocolAdmin);
        mockDeployer = new MockLiquidityDeployer();

        ComponentRegistry compRegImpl = new ComponentRegistry();
        address compRegProxy = LibClone.deployERC1967(address(compRegImpl));
        componentRegistry = ComponentRegistry(compRegProxy);
        componentRegistry.initialize(protocolAdmin);

        // Approve the curve computer and default deployer
        componentRegistry.approveComponent(address(curveComp), keccak256("curve"), "StandardCurve");
        componentRegistry.approveComponent(address(mockDeployer), keccak256("liquidity"), "MockDeployer");

        // Set up default preset
        launchMgr.setPreset(DEFAULT_PRESET_ID, LaunchManager.Preset({
            targetETH: 15 ether,
            unitPerNFT: 1e6,
            liquidityReserveBps: 2000,
            curveComputer: address(curveComp),
            active: true
        }));

        ERC404BondingInstance impl = new ERC404BondingInstance();
        factory = new ERC404Factory(
            ERC404Factory.CoreConfig({
                implementation: address(impl),
                masterRegistry: address(mockRegistry),
                protocol: protocolAdmin
            }),
            ERC404Factory.ModuleConfig({
                globalMessageRegistry: mockGMR,
                launchManager: address(launchMgr),
                componentRegistry: address(componentRegistry)
            })
        );

        vm.stopPrank();
    }

    // ========================
    // Helper: build default IdentityParams
    // ========================

    function _identity(
        string memory name_,
        string memory symbol_,
        address owner_
    ) internal returns (ERC404Factory.CreateParams memory) {
        return ERC404Factory.CreateParams({
            salt: _nextSalt(),
            owner: owner_,
            nftCount: DEFAULT_NFT_COUNT,
            presetId: uint8(DEFAULT_PRESET_ID),
            vault: address(mockVault),
            name: name_,
            symbol: symbol_,
            styleUri: "",
            stakingModule: address(0)
        });
    }

    // ========================
    // Instance Creation Tests
    // ========================

    function test_createInstance_successfulCreation() public {
        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);
        address instance = factory.createInstance{value: INSTANCE_CREATION_FEE}(
            _identity("TestToken", "TEST", creator1),
            "ipfs://metadata",
            address(mockDeployer),
            address(0),
            FreeMintParams({allocation: 0, scope: GatingScope.BOTH})
        );
        assertTrue(instance != address(0), "Instance should be created");
        vm.stopPrank();
    }

    function test_createInstance_withVault() public {
        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);
        address instance = factory.createInstance{value: INSTANCE_CREATION_FEE}(
            _identity("TestToken", "TEST", creator1),
            "ipfs://metadata",
            address(mockDeployer),
            address(0),
            FreeMintParams({allocation: 0, scope: GatingScope.BOTH})
        );
        assertTrue(instance != address(0));
        vm.stopPrank();
    }

    function test_createInstance_vaultRequired() public {
        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);
        vm.expectRevert(ERC404Factory.VaultRequired.selector);
        factory.createInstance{value: INSTANCE_CREATION_FEE}(
            ERC404Factory.CreateParams({
                salt: _nextSalt(),
                owner: creator1,
                nftCount: DEFAULT_NFT_COUNT,
                presetId: uint8(DEFAULT_PRESET_ID),
                vault: address(0),
                name: "TestToken",
                symbol: "TEST",
                styleUri: "",
                stakingModule: address(0)
            }),
            "ipfs://metadata",
            address(mockDeployer),
            address(0),
            FreeMintParams({allocation: 0, scope: GatingScope.BOTH})
        );
        vm.stopPrank();
    }

    function test_createInstance_invalidName() public {
        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);
        vm.expectRevert(ERC404Factory.InvalidName.selector);
        factory.createInstance{value: INSTANCE_CREATION_FEE}(
            _identity("", "TEST", creator1),
            "ipfs://metadata",
            address(mockDeployer),
            address(0),
            FreeMintParams({allocation: 0, scope: GatingScope.BOTH})
        );
        vm.stopPrank();
    }

    function test_createInstance_invalidSymbol() public {
        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);
        vm.expectRevert(ERC404Factory.InvalidSymbol.selector);
        factory.createInstance{value: INSTANCE_CREATION_FEE}(
            _identity("TestToken", "", creator1),
            "ipfs://metadata",
            address(mockDeployer),
            address(0),
            FreeMintParams({allocation: 0, scope: GatingScope.BOTH})
        );
        vm.stopPrank();
    }

    function test_createInstance_invalidNftCount() public {
        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);
        vm.expectRevert(ERC404Factory.InvalidNftCount.selector);
        factory.createInstance{value: INSTANCE_CREATION_FEE}(
            ERC404Factory.CreateParams({
                salt: _nextSalt(),
                owner: creator1,
                nftCount: 0,
                presetId: uint8(DEFAULT_PRESET_ID),
                vault: address(mockVault),
                name: "TestToken",
                symbol: "TEST",
                styleUri: "",
                stakingModule: address(0)
            }),
            "ipfs://metadata",
            address(mockDeployer),
            address(0),
            FreeMintParams({allocation: 0, scope: GatingScope.BOTH})
        );
        vm.stopPrank();
    }

    function test_createInstance_invalidCreator() public {
        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);
        vm.expectRevert(ERC404Factory.InvalidOwner.selector);
        factory.createInstance{value: INSTANCE_CREATION_FEE}(
            ERC404Factory.CreateParams({
                salt: _nextSalt(),
                owner: address(0),
                nftCount: DEFAULT_NFT_COUNT,
                presetId: uint8(DEFAULT_PRESET_ID),
                vault: address(mockVault),
                name: "TestToken",
                symbol: "TEST",
                styleUri: "",
                stakingModule: address(0)
            }),
            "ipfs://metadata",
            address(mockDeployer),
            address(0),
            FreeMintParams({allocation: 0, scope: GatingScope.BOTH})
        );
        vm.stopPrank();
    }

    // ========================
    // Infrastructure Tests
    // ========================

    function test_masterRegistry_initialization() public view {
        assertEq(address(factory.masterRegistry()), address(mockRegistry));
    }

    function test_features() public view {
        bytes32[] memory factoryFeatures = factory.features();
        assertTrue(factoryFeatures.length > 0, "Factory should have features");
    }

    // ========================
    // Multiple Instances Tests
    // ========================

    function test_createInstance_multipleSequential() public {
        vm.deal(creator1, 1 ether);
        vm.deal(creator2, 1 ether);

        vm.startPrank(creator1);
        address instance1 = factory.createInstance{value: INSTANCE_CREATION_FEE}(
            _identity("Token1", "TK1", creator1),
            "ipfs://metadata1",
            address(mockDeployer),
            address(0),
            FreeMintParams({allocation: 0, scope: GatingScope.BOTH})
        );
        vm.stopPrank();

        vm.startPrank(creator2);
        address instance2 = factory.createInstance{value: INSTANCE_CREATION_FEE}(
            _identity("Token2", "TK2", creator2),
            "ipfs://metadata2",
            address(mockDeployer),
            address(0),
            FreeMintParams({allocation: 0, scope: GatingScope.BOTH})
        );
        vm.stopPrank();

        assertTrue(instance1 != address(0));
        assertTrue(instance2 != address(0));
        assertTrue(instance1 != instance2);
    }

    function test_createInstance_eventEmission() public {
        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);
        vm.expectEmit(false, true, true, false);
        emit InstanceCreated(address(0), creator1, "EventToken", "EVT", address(mockVault));
        factory.createInstance{value: INSTANCE_CREATION_FEE}(
            _identity("EventToken", "EVT", creator1),
            "ipfs://metadata",
            address(mockDeployer),
            address(0),
            FreeMintParams({allocation: 0, scope: GatingScope.BOTH})
        );
        vm.stopPrank();
    }

    // ========================
    // Reentrancy Tests
    // ========================

    function test_createInstance_nonReentrant() public {
        vm.deal(creator1, 2 ether);
        vm.startPrank(creator1);

        address instance1 = factory.createInstance{value: INSTANCE_CREATION_FEE}(
            _identity("Token1", "TK1", creator1),
            "ipfs://metadata1",
            address(mockDeployer),
            address(0),
            FreeMintParams({allocation: 0, scope: GatingScope.BOTH})
        );
        assertTrue(instance1 != address(0));

        address instance2 = factory.createInstance{value: INSTANCE_CREATION_FEE}(
            _identity("Token2", "TK2", creator1),
            "ipfs://metadata2",
            address(mockDeployer),
            address(0),
            FreeMintParams({allocation: 0, scope: GatingScope.BOTH})
        );
        assertTrue(instance2 != address(0));
        vm.stopPrank();
    }

    function test_createInstance_differentCreator() public {
        vm.deal(creator1, 1 ether);
        // creator1 must be a registered agent to create on behalf of creator2
        mockRegistry.setAgent(creator1, true);
        vm.startPrank(creator1);
        address instance = factory.createInstance{value: INSTANCE_CREATION_FEE}(
            _identity("TestToken", "TEST", creator2),
            "ipfs://metadata",
            address(mockDeployer),
            address(0),
            FreeMintParams({allocation: 0, scope: GatingScope.BOTH})
        );
        assertTrue(instance != address(0));
        // Agent-created instance should have delegation enabled
        assertTrue(ERC404BondingInstance(payable(instance)).agentDelegationEnabled());
        vm.stopPrank();
    }

    // ========================
    // Protocol Treasury Tests
    // ========================

    function test_SetProtocolTreasury() public {
        vm.startPrank(protocolAdmin);
        factory.setProtocolTreasury(address(0xBEEF));
        assertEq(factory.protocolTreasury(), address(0xBEEF));
        vm.stopPrank();
    }

    function test_SetProtocolTreasury_RevertNonOwner() public {
        vm.startPrank(nonOwner);
        vm.expectRevert();
        factory.setProtocolTreasury(address(0xBEEF));
        vm.stopPrank();
    }

    function test_SetProtocolTreasury_RevertZeroAddress() public {
        vm.startPrank(protocolAdmin);
        vm.expectRevert(ERC404Factory.InvalidAddress.selector);
        factory.setProtocolTreasury(address(0));
        vm.stopPrank();
    }

    function test_CreateInstance_FeeGoesDirectlyToTreasury() public {
        address treasury = address(0xBEEF);
        vm.startPrank(protocolAdmin);
        factory.setProtocolTreasury(treasury);
        vm.stopPrank();

        vm.deal(creator1, 1 ether);
        vm.prank(creator1);
        factory.createInstance{value: INSTANCE_CREATION_FEE}(
            _identity("FeeToken", "FEE", creator1),
            "ipfs://metadata",
            address(mockDeployer),
            address(0),
            FreeMintParams({allocation: 0, scope: GatingScope.BOTH})
        );

        assertEq(treasury.balance, INSTANCE_CREATION_FEE);
        assertEq(address(factory).balance, 0);
    }

    // ========================
    // Bonding Fee BPS Tests
    // ========================

    function test_SetBondingFeeBps() public {
        vm.startPrank(protocolAdmin);
        factory.setBondingFeeBps(200);
        assertEq(factory.bondingFeeBps(), 200);
        vm.stopPrank();
    }

    function test_SetBondingFeeBps_RevertExceedsCap() public {
        vm.startPrank(protocolAdmin);
        vm.expectRevert(ERC404Factory.MaxBondingFeeExceeded.selector);
        factory.setBondingFeeBps(301);
        vm.stopPrank();
    }

    function test_SetBondingFeeBps_RevertNonOwner() public {
        vm.startPrank(nonOwner);
        vm.expectRevert();
        factory.setBondingFeeBps(200);
        vm.stopPrank();
    }

    function test_BondingFeeBps_DefaultValue() public view {
        assertEq(factory.bondingFeeBps(), 100);
    }

    // ========================
    // Role-Based Access Tests
    // ========================

    function test_protocolRole_canSetBondingFee() public {
        vm.startPrank(protocolAdmin);
        factory.setBondingFeeBps(200);
        assertEq(factory.bondingFeeBps(), 200);
        vm.stopPrank();
    }

    // ========================
    // Curve Params Tests (on CurveParamsComputer)
    // ========================

    function test_computeCurveParams_standardProfile() public view {
        uint256 nftCount = 100;
        BondingCurveMath.Params memory params = curveComp.computeCurveParams(nftCount, 15 ether, 1e6, 2000);
        uint256 totalSupply = nftCount * 1e6 * 1e18;
        uint256 maxBondingSupply = totalSupply - (totalSupply * 2000) / 10000;
        uint256 totalCost = BondingCurveMath.calculateCost(params, 0, maxBondingSupply);
        assertApproxEqRel(totalCost, 15 ether, 0.01e18);
    }

    function test_computeCurveParams_nicheProfile() public view {
        uint256 nftCount = 50;
        BondingCurveMath.Params memory params = curveComp.computeCurveParams(nftCount, 5 ether, 1e9, 2000);
        uint256 totalSupply = nftCount * 1e9 * 1e18;
        uint256 maxBondingSupply = totalSupply - (totalSupply * 2000) / 10000;
        uint256 totalCost = BondingCurveMath.calculateCost(params, 0, maxBondingSupply);
        assertApproxEqRel(totalCost, 5 ether, 0.01e18);
    }

    function test_computeCurveParams_ambitiousProfile() public view {
        uint256 nftCount = 500;
        BondingCurveMath.Params memory params = curveComp.computeCurveParams(nftCount, 30 ether, 1e3, 2000);
        uint256 totalSupply = nftCount * 1e3 * 1e18;
        uint256 maxBondingSupply = totalSupply - (totalSupply * 2000) / 10000;
        uint256 totalCost = BondingCurveMath.calculateCost(params, 0, maxBondingSupply);
        assertApproxEqRel(totalCost, 30 ether, 0.01e18);
    }

    // ========================
    // createInstance with preset Tests
    // ========================

    function test_createInstance_withPreset() public {
        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);
        address instance = factory.createInstance{value: INSTANCE_CREATION_FEE}(
            ERC404Factory.CreateParams({
                salt: _nextSalt(),
                owner: creator1,
                nftCount: 100,
                presetId: uint8(DEFAULT_PRESET_ID),
                vault: address(mockVault),
                name: "TestToken",
                symbol: "TEST",
                styleUri: "",
                stakingModule: address(0)
            }),
            "ipfs://metadata",
            address(mockDeployer),
            address(0),
            FreeMintParams({allocation: 0, scope: GatingScope.BOTH})
        );
        assertTrue(instance != address(0));
        ERC404BondingInstance inst = ERC404BondingInstance(payable(instance));
        assertEq(inst.maxSupply(), 100 * 1e6 * 1e18);
        assertEq(inst.unit(), 1e6 * 1e18);
        vm.stopPrank();
    }

    function test_createInstance_inactivePresetReverts() public {
        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);
        vm.expectRevert(abi.encodeWithSignature("PresetNotActive()"));
        factory.createInstance{value: INSTANCE_CREATION_FEE}(
            ERC404Factory.CreateParams({
                salt: _nextSalt(),
                owner: creator1,
                nftCount: 100,
                presetId: uint8(5), // inactive preset
                vault: address(mockVault),
                name: "TestToken",
                symbol: "TEST",
                styleUri: "",
                stakingModule: address(0)
            }),
            "ipfs://metadata",
            address(mockDeployer),
            address(0),
            FreeMintParams({allocation: 0, scope: GatingScope.BOTH})
        );
        vm.stopPrank();
    }

    function test_createInstance_zeroNftCountReverts() public {
        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);
        vm.expectRevert(ERC404Factory.InvalidNftCount.selector);
        factory.createInstance{value: INSTANCE_CREATION_FEE}(
            ERC404Factory.CreateParams({
                salt: _nextSalt(),
                owner: creator1,
                nftCount: 0,
                presetId: uint8(DEFAULT_PRESET_ID),
                vault: address(mockVault),
                name: "TestToken",
                symbol: "TEST",
                styleUri: "",
                stakingModule: address(0)
            }),
            "ipfs://metadata",
            address(mockDeployer),
            address(0),
            FreeMintParams({allocation: 0, scope: GatingScope.BOTH})
        );
        vm.stopPrank();
    }

    // ── ComponentRegistry validation ──────────────────────────────────────────

    function test_createInstance_validatesLiquidityDeployer() public {
        vm.deal(creator1, 1 ether);
        vm.prank(creator1);
        vm.expectRevert(ERC404Factory.UnapprovedLiquidityDeployer.selector);
        factory.createInstance{value: INSTANCE_CREATION_FEE}(
            _identity("Token", "TKN", creator1),
            "ipfs://",
            address(0xDEAD),  // unapproved deployer
            address(0),
            FreeMintParams({allocation: 0, scope: GatingScope.BOTH})
        );
    }

    function test_createInstance_withApprovedDeployer_succeeds() public {
        vm.deal(creator1, 1 ether);
        vm.prank(creator1);
        address instance = factory.createInstance{value: INSTANCE_CREATION_FEE}(
            _identity("Token", "TKN", creator1),
            "ipfs://",
            address(mockDeployer),
            address(0),
            FreeMintParams({allocation: 0, scope: GatingScope.BOTH})
        );
        assertTrue(instance != address(0));
        assertEq(
            address(ERC404BondingInstance(payable(instance)).liquidityDeployer()),
            address(mockDeployer)
        );
    }

    function test_createInstanceWithGating_revertsOnUnapprovedModule() public {
        address unapprovedModule = address(0xBAD6A7);

        vm.deal(creator1, 1 ether);
        vm.prank(creator1);
        vm.expectRevert(ERC404Factory.UnapprovedGatingModule.selector);
        factory.createInstance{value: INSTANCE_CREATION_FEE}(
            _identity("TestToken", "TEST", creator1),
            "ipfs://Qmtest",
            address(mockDeployer),
            unapprovedModule,
            FreeMintParams({allocation: 0, scope: GatingScope.BOTH})
        );
    }

    function test_createInstanceWithGating_succeedsWithApprovedModule() public {
        address gatingModule = address(new PasswordTierGatingModule(address(mockRegistry)));
        vm.prank(protocolAdmin);
        componentRegistry.approveComponent(gatingModule, keccak256("gating"), "PasswordTierGating");

        vm.deal(creator1, 1 ether);
        vm.prank(creator1);
        address instance = factory.createInstance{value: INSTANCE_CREATION_FEE}(
            _identity("GatedToken", "GATE", creator1),
            "ipfs://Qmtest",
            address(mockDeployer),
            gatingModule,
            FreeMintParams({allocation: 0, scope: GatingScope.BOTH})
        );

        assertTrue(instance != address(0));
    }

    function test_createInstanceWithGating_zeroAddressSkipsValidation() public {
        vm.deal(creator1, 1 ether);
        vm.prank(creator1);
        address instance = factory.createInstance{value: INSTANCE_CREATION_FEE}(
            _identity("OpenToken", "OPEN", creator1),
            "ipfs://Qmtest",
            address(mockDeployer),
            address(0),
            FreeMintParams({allocation: 0, scope: GatingScope.BOTH})
        );

        assertTrue(instance != address(0));
    }

    function test_createInstance_withGating_storesModule() public {
        address gatingModule = address(new PasswordTierGatingModule(address(mockRegistry)));
        vm.prank(protocolAdmin);
        componentRegistry.approveComponent(gatingModule, keccak256("gating"), "PasswordTierGating2");

        vm.deal(creator1, 1 ether);
        vm.prank(creator1);
        address instance = factory.createInstance{value: INSTANCE_CREATION_FEE}(
            _identity("GatedToken2", "GATE2", creator1),
            "ipfs://Qmtest",
            address(mockDeployer),
            gatingModule,
            FreeMintParams({allocation: 0, scope: GatingScope.BOTH})
        );

        assertEq(
            address(ERC404BondingInstance(payable(instance)).gatingModule()),
            gatingModule
        );
        assertTrue(ERC404BondingInstance(payable(instance)).gatingActive());
    }

    function test_createInstance_noGating_gatingActiveFalse() public {
        vm.deal(creator1, 1 ether);
        vm.prank(creator1);
        address instance = factory.createInstance{value: INSTANCE_CREATION_FEE}(
            _identity("OpenToken2", "OPEN2", creator1),
            "ipfs://Qmtest",
            address(mockDeployer),
            address(0),
            FreeMintParams({allocation: 0, scope: GatingScope.BOTH})
        );
        assertFalse(ERC404BondingInstance(payable(instance)).gatingActive());
    }

    /// @dev A plain vault with no hook() function must be accepted.
    function test_createInstance_noHookRequired() public {
        address plainVault = address(new PlainVault());

        vm.deal(creator1, 1 ether);
        vm.prank(creator1);
        address instance = factory.createInstance{value: INSTANCE_CREATION_FEE}(
            ERC404Factory.CreateParams({
                salt: _nextSalt(),
                owner: creator1,
                nftCount: DEFAULT_NFT_COUNT,
                presetId: uint8(DEFAULT_PRESET_ID),
                vault: plainVault,
                name: "PlainVaultToken",
                symbol: "PVT",
                styleUri: "",
                stakingModule: address(0)
            }),
            "ipfs://metadata",
            address(mockDeployer),
            address(0),
            FreeMintParams({allocation: 0, scope: GatingScope.BOTH})
        );
        assertTrue(instance != address(0));
    }
}
