// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {MasterRegistryV1} from "../../src/master/MasterRegistryV1.sol";
import {MasterRegistry} from "../../src/master/MasterRegistry.sol";
import {ERC404Factory} from "../../src/factories/erc404/ERC404Factory.sol";
import {ERC404StakingModule} from "../../src/factories/erc404/ERC404StakingModule.sol";
import {LaunchManager} from "../../src/factories/erc404/LaunchManager.sol";
import {CurveParamsComputer} from "../../src/factories/erc404/CurveParamsComputer.sol";
import {PasswordTierGatingModule} from "../../src/gating/PasswordTierGatingModule.sol";
import {ERC1155Factory} from "../../src/factories/erc1155/ERC1155Factory.sol";
import {GlobalMessageRegistry} from "../../src/registry/GlobalMessageRegistry.sol";
import {ERC404BondingInstance} from "../../src/factories/erc404/ERC404BondingInstance.sol";
import {MockEXECToken} from "../mocks/MockEXECToken.sol";
import {MockZRouter} from "../mocks/MockZRouter.sol";
import {MockVaultPriceValidator} from "../mocks/MockVaultPriceValidator.sol";
import {IVaultPriceValidator} from "../../src/interfaces/IVaultPriceValidator.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IdentityParams} from "../../src/interfaces/IFactoryTypes.sol";

/**
 * @title MockHook
 * @notice Simple mock hook for testing
 */
contract MockHook {
    // Minimal mock hook contract
}

/// @dev Mock vault that returns a hook address and satisfies factory checks
contract MockVaultWithHook {
    address private _hook;
    constructor(address hookAddr) { _hook = hookAddr; }
    function hook() external view returns (address) { return _hook; }
    function supportsCapability(bytes32) external pure returns (bool) { return true; }
    receive() external payable {}
}

/**
 * @title NamespaceCollisionTest
 * @notice Tests that project names are unique across all factory types
 */
contract MockMasterRegistryForStakingN {
    mapping(address => bool) public instances;
    function setInstance(address a, bool v) external { instances[a] = v; }
    function isRegisteredInstance(address a) external view returns (bool) { return instances[a]; }
}

contract NamespaceCollisionTest is Test {
    MasterRegistryV1 public implementation;
    MasterRegistry public proxy;
    MasterRegistryV1 public registry;

    ERC404Factory public erc404Factory;
    ERC1155Factory public erc1155Factory;

    MockHook public mockHook;
    MockVaultWithHook public mockVault;  // vault with hook() for ERC404 factory
    MockMasterRegistryForStakingN public stakingRegistry;
    ERC404StakingModule public stakingModule;
    MockEXECToken public execToken;

    address public owner = address(0x1);
    address public creator1 = address(0x2);
    address public creator2 = address(0x3);

    // Mock infrastructure
    address public mockV4PoolManager = address(0x1111111111111111111111111111111111111111);
    address public mockWETH = address(0x2222222222222222222222222222222222222222);
    address public mockInstanceTemplate = address(0x4444444444444444444444444444444444444444);

    // Test constants
    uint256 constant INSTANCE_FEE = 0.01 ether;

    function setUp() public {
        vm.startPrank(owner);

        // Deploy EXEC token (used as alignment token for vault)
        execToken = new MockEXECToken(1000000e18);

        // Deploy MasterRegistry with proxy
        implementation = new MasterRegistryV1();
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address)",
            owner
        );
        proxy = new MasterRegistry(address(implementation), initData);

        // Get the actual inner proxy address (the wrapper uses call, which changes msg.sender)
        address innerProxy = proxy.getProxyAddress();
        registry = MasterRegistryV1(innerProxy);

        // Deploy mock hook and vault with hook
        mockHook = new MockHook();
        mockVault = new MockVaultWithHook(address(mockHook));

        // Deploy staking module
        stakingRegistry = new MockMasterRegistryForStakingN();
        stakingModule = new ERC404StakingModule(address(stakingRegistry));

        // Deploy global message registry
        GlobalMessageRegistry globalMsgRegistry = new GlobalMessageRegistry();
        globalMsgRegistry.initialize(owner, address(registry));

        // Deploy LaunchManager and CurveParamsComputer
        LaunchManager launchManager = new LaunchManager(owner);
        CurveParamsComputer curveComputer = new CurveParamsComputer(owner);
        PasswordTierGatingModule tierGatingModule = new PasswordTierGatingModule();

        // Deploy ERC404Factory
        ERC404BondingInstance nsImpl = new ERC404BondingInstance();
        erc404Factory = new ERC404Factory(
            ERC404Factory.CoreConfig({
                implementation: address(nsImpl),
                masterRegistry: address(registry),
                instanceTemplate: mockInstanceTemplate,
                v4PoolManager: mockV4PoolManager,
                weth: mockWETH,
                protocol: owner,
                creator: address(0xC1EA),
                creatorFeeBps: 2000,
                creatorGraduationFeeBps: 40
            }),
            ERC404Factory.ModuleConfig({
                stakingModule: address(stakingModule),
                liquidityDeployer: address(0x600),
                globalMessageRegistry: address(globalMsgRegistry),
                launchManager: address(launchManager),
                curveComputer: address(curveComputer),
                tierGatingModule: address(tierGatingModule)
            })
        );

        // Deploy ERC1155Factory
        erc1155Factory = new ERC1155Factory(
            address(registry),
            mockInstanceTemplate,
            address(0xC1EA),
            2000,
            address(globalMsgRegistry)
        );

        // Set protocol treasury on both factories
        erc404Factory.setProtocolTreasury(address(0xFEE));
        erc1155Factory.setProtocolTreasury(address(0xFEE));

        // Setup graduation profile for ERC404
        ERC404Factory.GraduationProfile memory profile = ERC404Factory.GraduationProfile({
            targetETH: 15 ether,
            unitPerNFT: 1_000_000,
            poolFee: 3000,
            tickSpacing: 60,
            liquidityReserveBps: 1000,
            active: true
        });
        erc404Factory.setProfile(1, profile);

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

    function _erc404Identity(string memory name_, string memory symbol_, address vault_)
        internal
        view
        returns (IdentityParams memory)
    {
        return IdentityParams({
            name: name_,
            symbol: symbol_,
            styleUri: "",
            owner: msg.sender,
            vault: vault_,
            nftCount: 10,
            profileId: 1
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
            _erc404Identity("poggers", "POG", address(mockVault)),
            "ipfs://metadata",
            ERC404Factory.CreationTier.STANDARD
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

        // Creator1 creates ERC1155 instance named "poggers"
        vm.startPrank(creator1);
        erc1155Factory.createInstance{value: INSTANCE_FEE}(
            "poggers",
            "ipfs://metadata",
            creator1,
            address(mockVault),
            ""
        );
        vm.stopPrank();

        // Creator2 tries to create ERC404 instance with same name - should FAIL
        vm.startPrank(creator2);
        vm.expectRevert("Name already taken");
        erc404Factory.createInstance{value: INSTANCE_FEE}(
            _erc404Identity("poggers", "POG", address(mockVault)),
            "ipfs://metadata",
            ERC404Factory.CreationTier.STANDARD
        );
        vm.stopPrank();
    }

    /**
     * @notice CRITICAL TEST: ERC1155 cannot use name already taken by ERC404
     */
    function test_crossFactory_erc404ThenErc1155_reverts() public {
        vm.deal(creator1, 1 ether);
        vm.deal(creator2, 1 ether);

        // Creator1 creates ERC404 instance named "poggers"
        vm.startPrank(creator1);
        erc404Factory.createInstance{value: INSTANCE_FEE}(
            _erc404Identity("poggers", "POG", address(mockVault)),
            "ipfs://metadata",
            ERC404Factory.CreationTier.STANDARD
        );
        vm.stopPrank();

        // Creator2 tries to create ERC1155 instance with same name - should FAIL
        vm.startPrank(creator2);
        vm.expectRevert("Name already taken");
        erc1155Factory.createInstance{value: INSTANCE_FEE}(
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

        // Creator1 creates instance named "POGGERS" (uppercase)
        vm.startPrank(creator1);
        erc1155Factory.createInstance{value: INSTANCE_FEE}(
            "POGGERS",
            "ipfs://metadata",
            creator1,
            address(mockVault),
            ""
        );
        vm.stopPrank();

        // Creator2 tries "poggers" (lowercase) - should FAIL
        vm.startPrank(creator2);
        vm.expectRevert("Name already taken");
        erc404Factory.createInstance{value: INSTANCE_FEE}(
            _erc404Identity("poggers", "POG", address(mockVault)),
            "ipfs://metadata",
            ERC404Factory.CreationTier.STANDARD
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
            _erc404Identity("poggers", "POG", address(mockVault)),
            "ipfs://metadata",
            ERC404Factory.CreationTier.STANDARD
        );
        vm.stopPrank();

        vm.startPrank(creator2);
        vm.expectRevert("Name already taken");
        erc404Factory.createInstance{value: INSTANCE_FEE}(
            _erc404Identity("poggers", "POG2", address(mockVault)),
            "ipfs://metadata2",
            ERC404Factory.CreationTier.STANDARD
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
            "poggers",
            "ipfs://metadata",
            creator1,
            address(mockVault),
            ""
        );
        vm.stopPrank();

        vm.startPrank(creator2);
        address instance2 = erc404Factory.createInstance{value: INSTANCE_FEE}(
            _erc404Identity("different_name", "DIFF", address(mockVault)),
            "ipfs://metadata",
            ERC404Factory.CreationTier.STANDARD
        );
        vm.stopPrank();

        assertTrue(instance1 != address(0), "First instance should be created");
        assertTrue(instance2 != address(0), "Second instance should be created");
        assertTrue(instance1 != instance2, "Instances should be different");
    }
}
