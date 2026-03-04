// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {MasterRegistryV1} from "../../src/master/MasterRegistryV1.sol";
import {MasterRegistry} from "../../src/master/MasterRegistry.sol";
import {ERC404Factory} from "../../src/factories/erc404/ERC404Factory.sol";
import {LaunchManager} from "../../src/factories/erc404/LaunchManager.sol";
import {CurveParamsComputer} from "../../src/factories/erc404/CurveParamsComputer.sol";
import {PasswordTierGatingModule} from "../../src/gating/PasswordTierGatingModule.sol";
import {ERC1155Factory} from "../../src/factories/erc1155/ERC1155Factory.sol";
import {GlobalMessageRegistry} from "../../src/registry/GlobalMessageRegistry.sol";
import {ERC404BondingInstance} from "../../src/factories/erc404/ERC404BondingInstance.sol";
import {ComponentRegistry} from "../../src/registry/ComponentRegistry.sol";
import {ILiquidityDeployerModule} from "../../src/interfaces/ILiquidityDeployerModule.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {IdentityParams, FreeMintParams} from "../../src/interfaces/IFactoryTypes.sol";
import {GatingScope} from "../../src/gating/IGatingModule.sol";
import {CREATEX} from "../../src/shared/CreateXConstants.sol";
import {CREATEX_BYTECODE} from "createx-forge/script/CreateX.d.sol";

/// @dev Mock vault that satisfies factory checks
contract MockVaultForNamespace {
    function supportsCapability(bytes32) external pure returns (bool) { return true; }
    receive() external payable {}
}

/// @dev Minimal mock liquidity deployer
contract MockLiquidityDeployerNS is ILiquidityDeployerModule {
    function deployLiquidity(ILiquidityDeployerModule.DeployParams calldata) external payable override {}
}

/**
 * @title NamespaceCollisionTest
 * @notice Tests that project names are unique across all factory types
 */
contract NamespaceCollisionTest is Test {
    MasterRegistryV1 public implementation;
    MasterRegistry public proxy;
    MasterRegistryV1 public registry;

    ERC404Factory public erc404Factory;
    ERC1155Factory public erc1155Factory;

    MockVaultForNamespace public mockVault;
    MockLiquidityDeployerNS public mockDeployer;

    address public owner = address(0x1);
    address public creator1 = address(0x2);
    address public creator2 = address(0x3);

    uint256 internal _saltCounter;

    function _nextErc1155Salt() internal returns (bytes32) {
        _saltCounter++;
        return bytes32(abi.encodePacked(address(erc1155Factory), uint8(0x00), bytes11(uint88(_saltCounter))));
    }

    function _nextErc404Salt() internal returns (bytes32) {
        _saltCounter++;
        return bytes32(abi.encodePacked(address(erc404Factory), uint8(0x00), bytes11(uint88(_saltCounter))));
    }

    // Test constants
    uint256 constant INSTANCE_FEE = 0.01 ether;
    uint256 constant DEFAULT_PRESET_ID = 1;

    function setUp() public {
        vm.etch(CREATEX, CREATEX_BYTECODE);
        vm.startPrank(owner);

        // Deploy MasterRegistry with proxy
        implementation = new MasterRegistryV1();
        bytes memory initData = abi.encodeWithSignature("initialize(address)", owner);
        proxy = new MasterRegistry(address(implementation), initData);
        registry = MasterRegistryV1(address(proxy));

        mockVault = new MockVaultForNamespace();
        mockDeployer = new MockLiquidityDeployerNS();

        // Deploy global message registry
        GlobalMessageRegistry globalMsgRegistry = new GlobalMessageRegistry();
        globalMsgRegistry.initialize(owner, address(registry));

        // Deploy LaunchManager and CurveParamsComputer
        LaunchManager launchManager = new LaunchManager(owner);
        CurveParamsComputer curveComputer = new CurveParamsComputer(owner);
        PasswordTierGatingModule tierGatingModule = new PasswordTierGatingModule();

        // Deploy ComponentRegistry
        ComponentRegistry compRegImpl = new ComponentRegistry();
        address compRegProxy = LibClone.deployERC1967(address(compRegImpl));
        ComponentRegistry componentRegistry = ComponentRegistry(compRegProxy);
        componentRegistry.initialize(owner);
        componentRegistry.approveComponent(address(curveComputer), keccak256("curve"), "StandardCurve");
        componentRegistry.approveComponent(address(mockDeployer), keccak256("liquidity"), "MockDeployer");

        // Set up default preset
        launchManager.setPreset(DEFAULT_PRESET_ID, LaunchManager.Preset({
            targetETH: 15 ether,
            unitPerNFT: 1_000_000,
            liquidityReserveBps: 1000,
            curveComputer: address(curveComputer),
            active: true
        }));

        // Deploy ERC404Factory
        ERC404BondingInstance nsImpl = new ERC404BondingInstance();
        erc404Factory = new ERC404Factory(
            ERC404Factory.CoreConfig({
                implementation: address(nsImpl),
                masterRegistry: address(registry),
                protocol: owner
            }),
            ERC404Factory.ModuleConfig({
                globalMessageRegistry: address(globalMsgRegistry),
                launchManager: address(launchManager),
                tierGatingModule: address(tierGatingModule),
                componentRegistry: address(componentRegistry)
            })
        );

        // Deploy ERC1155Factory
        erc1155Factory = new ERC1155Factory(
            address(registry),
            address(0), // no instance template needed
            address(globalMsgRegistry),
            address(0)
        );

        // Set protocol treasury on both factories
        erc404Factory.setProtocolTreasury(address(0xFEE));
        erc1155Factory.setProtocolTreasury(address(0xFEE));

        // Register both factories with MasterRegistry
        registry.registerFactory(
            address(erc404Factory),
            "ERC404",
            "ERC404-Factory",
            "ERC404 Factory",
            "ipfs://erc404-factory",
            new bytes32[](0)
        );
        registry.registerFactory(
            address(erc1155Factory),
            "ERC1155",
            "ERC1155-Factory",
            "ERC1155 Factory",
            "ipfs://erc1155-factory",
            new bytes32[](0)
        );

        vm.stopPrank();
    }

    function _erc404Identity(string memory name_, string memory symbol_, address vault_, address owner_)
        internal
        returns (IdentityParams memory)
    {
        return IdentityParams({
            salt: _nextErc404Salt(),
            name: name_,
            symbol: symbol_,
            styleUri: "",
            owner: owner_,
            vault: vault_,
            nftCount: 10,
            presetId: uint8(DEFAULT_PRESET_ID),
            creationTier: 0
        });
    }

    /**
     * @notice Test that isNameTaken correctly reports name availability
     */
    function test_isNameTaken_initiallyFalse() public {
        assertFalse(registry.isNameTaken("poggers"), "Name should not be taken initially");
        assertFalse(registry.isNameTaken("POGGERS"), "Case variant should not be taken");
    }

    /**
     * @notice Test ERC404 instance creation marks name as taken
     */
    function test_erc404Creation_marksNameTaken() public {
        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);

        erc404Factory.createInstance{value: INSTANCE_FEE}(
            _erc404Identity("poggers", "POG", address(mockVault), creator1),
            "ipfs://metadata",
            address(mockDeployer),
            address(0),
            FreeMintParams({allocation: 0, scope: GatingScope.BOTH})
        );

        vm.stopPrank();

        assertTrue(registry.isNameTaken("poggers"), "Name should be taken after ERC404 creation");
        assertTrue(registry.isNameTaken("POGGERS"), "Case variant should also be taken");
    }

    /**
     * @notice Test ERC1155 instance creation marks name as taken
     */
    function test_erc1155Creation_marksNameTaken() public {
        vm.deal(creator1, 1 ether);
        vm.startPrank(creator1);

        erc1155Factory.createInstance{value: INSTANCE_FEE}(
            _nextErc1155Salt(),
            "poggers",
            "ipfs://metadata",
            creator1,
            address(mockVault),
            ""
        );

        vm.stopPrank();

        assertTrue(registry.isNameTaken("poggers"), "Name should be taken after ERC1155 creation");
    }

    /**
     * @notice CRITICAL TEST: ERC404 cannot use name already taken by ERC1155
     */
    function test_crossFactory_erc1155ThenErc404_reverts() public {
        vm.deal(creator1, 1 ether);
        vm.deal(creator2, 1 ether);

        vm.startPrank(creator1);
        erc1155Factory.createInstance{value: INSTANCE_FEE}(
            _nextErc1155Salt(),
            "poggers",
            "ipfs://metadata",
            creator1,
            address(mockVault),
            ""
        );
        vm.stopPrank();

        vm.startPrank(creator2);
        vm.expectRevert(MasterRegistryV1.NameAlreadyTaken.selector);
        erc404Factory.createInstance{value: INSTANCE_FEE}(
            _erc404Identity("poggers", "POG", address(mockVault), creator2),
            "ipfs://metadata",
            address(mockDeployer),
            address(0),
            FreeMintParams({allocation: 0, scope: GatingScope.BOTH})
        );
        vm.stopPrank();
    }

    /**
     * @notice CRITICAL TEST: ERC1155 cannot use name already taken by ERC404
     */
    function test_crossFactory_erc404ThenErc1155_reverts() public {
        vm.deal(creator1, 1 ether);
        vm.deal(creator2, 1 ether);

        vm.startPrank(creator1);
        erc404Factory.createInstance{value: INSTANCE_FEE}(
            _erc404Identity("poggers", "POG", address(mockVault), creator1),
            "ipfs://metadata",
            address(mockDeployer),
            address(0),
            FreeMintParams({allocation: 0, scope: GatingScope.BOTH})
        );
        vm.stopPrank();

        vm.startPrank(creator2);
        vm.expectRevert(ERC1155Factory.NameAlreadyTaken.selector);
        erc1155Factory.createInstance{value: INSTANCE_FEE}(
            _nextErc1155Salt(),
            "poggers",
            "ipfs://metadata",
            creator2,
            address(mockVault),
            ""
        );
        vm.stopPrank();
    }

    /**
     * @notice Test case-insensitive collision detection
     */
    function test_crossFactory_caseInsensitive_reverts() public {
        vm.deal(creator1, 1 ether);
        vm.deal(creator2, 1 ether);

        vm.startPrank(creator1);
        erc1155Factory.createInstance{value: INSTANCE_FEE}(
            _nextErc1155Salt(),
            "POGGERS",
            "ipfs://metadata",
            creator1,
            address(mockVault),
            ""
        );
        vm.stopPrank();

        vm.startPrank(creator2);
        vm.expectRevert(MasterRegistryV1.NameAlreadyTaken.selector);
        erc404Factory.createInstance{value: INSTANCE_FEE}(
            _erc404Identity("poggers", "POG", address(mockVault), creator2),
            "ipfs://metadata",
            address(mockDeployer),
            address(0),
            FreeMintParams({allocation: 0, scope: GatingScope.BOTH})
        );
        vm.stopPrank();
    }

    /**
     * @notice Test same factory type also blocks duplicate names
     */
    function test_sameFactory_erc404_duplicateName_reverts() public {
        vm.deal(creator1, 1 ether);
        vm.deal(creator2, 1 ether);

        vm.startPrank(creator1);
        erc404Factory.createInstance{value: INSTANCE_FEE}(
            _erc404Identity("poggers", "POG", address(mockVault), creator1),
            "ipfs://metadata",
            address(mockDeployer),
            address(0),
            FreeMintParams({allocation: 0, scope: GatingScope.BOTH})
        );
        vm.stopPrank();

        vm.startPrank(creator2);
        vm.expectRevert(MasterRegistryV1.NameAlreadyTaken.selector);
        erc404Factory.createInstance{value: INSTANCE_FEE}(
            _erc404Identity("poggers", "POG2", address(mockVault), creator2),
            "ipfs://metadata2",
            address(mockDeployer),
            address(0),
            FreeMintParams({allocation: 0, scope: GatingScope.BOTH})
        );
        vm.stopPrank();
    }

    /**
     * @notice Test that different names work fine
     */
    function test_differentNames_succeed() public {
        vm.deal(creator1, 1 ether);
        vm.deal(creator2, 1 ether);

        vm.startPrank(creator1);
        address instance1 = erc1155Factory.createInstance{value: INSTANCE_FEE}(
            _nextErc1155Salt(),
            "poggers",
            "ipfs://metadata",
            creator1,
            address(mockVault),
            ""
        );
        vm.stopPrank();

        vm.startPrank(creator2);
        address instance2 = erc404Factory.createInstance{value: INSTANCE_FEE}(
            _erc404Identity("different_name", "DIFF", address(mockVault), creator2),
            "ipfs://metadata",
            address(mockDeployer),
            address(0),
            FreeMintParams({allocation: 0, scope: GatingScope.BOTH})
        );
        vm.stopPrank();

        assertTrue(instance1 != address(0), "First instance should be created");
        assertTrue(instance2 != address(0), "Second instance should be created");
        assertTrue(instance1 != instance2, "Instances should be different");
    }
}
