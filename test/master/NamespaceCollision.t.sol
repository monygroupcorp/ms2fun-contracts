// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {MasterRegistryV1} from "../../src/master/MasterRegistryV1.sol";
import {MasterRegistry} from "../../src/master/MasterRegistry.sol";
import {ERC404Factory} from "../../src/factories/erc404/ERC404Factory.sol";
import {ERC1155Factory} from "../../src/factories/erc1155/ERC1155Factory.sol";
import {ERC404BondingInstance} from "../../src/factories/erc404/ERC404BondingInstance.sol";
import {UltraAlignmentVault} from "../../src/vaults/UltraAlignmentVault.sol";
import {MockEXECToken} from "../mocks/MockEXECToken.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

/**
 * @title MockHook
 * @notice Simple mock hook for testing
 */
contract MockHook {
    // Minimal mock hook contract
}

/**
 * @title NamespaceCollisionTest
 * @notice Tests that project names are unique across all factory types
 * @dev Proves that two projects cannot have the same name, regardless of whether
 *      they were created via ERC404Factory or ERC1155Factory
 */
contract NamespaceCollisionTest is Test {
    MasterRegistryV1 public implementation;
    MasterRegistry public proxy;
    MasterRegistryV1 public registry;

    ERC404Factory public erc404Factory;
    ERC1155Factory public erc1155Factory;

    UltraAlignmentVault public vault;
    MockHook public mockHook;
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
    uint256 constant MAX_SUPPLY = 10_000_000 * 1e18;

    ERC404BondingInstance.BondingCurveParams defaultCurveParams;
    ERC404BondingInstance.TierConfig defaultTierConfig;

    function setUp() public {
        vm.startPrank(owner);

        // Deploy EXEC token for governance
        execToken = new MockEXECToken(1000000e18);

        // Deploy MasterRegistry with proxy
        implementation = new MasterRegistryV1();
        bytes memory initData = abi.encodeWithSelector(
            MasterRegistryV1.initialize.selector,
            address(execToken),
            owner
        );
        proxy = new MasterRegistry(address(implementation), initData);

        // Get the actual inner proxy address (the wrapper uses call, which changes msg.sender)
        address innerProxy = proxy.getProxyAddress();
        registry = MasterRegistryV1(innerProxy);

        // Deploy vault
        vault = new UltraAlignmentVault(
            mockWETH,
            mockV4PoolManager,
            address(0x5555555555555555555555555555555555555555), // V3 router
            address(0x6666666666666666666666666666666666666666), // V2 router
            address(0x7777777777777777777777777777777777777777), // V2 factory
            address(0x8888888888888888888888888888888888888888), // V3 factory
            address(execToken)
        );

        // Set V4 pool key
        PoolKey memory mockPoolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(execToken)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        vault.setV4PoolKey(mockPoolKey);

        // Deploy mock hook
        mockHook = new MockHook();

        // Deploy ERC404Factory
        erc404Factory = new ERC404Factory(
            address(registry),
            mockInstanceTemplate,
            mockV4PoolManager,
            mockWETH
        );

        // Deploy ERC1155Factory
        erc1155Factory = new ERC1155Factory(
            address(registry),
            mockInstanceTemplate
        );

        // Register both factories with MasterRegistry (as dictator)
        // Note: titles must be alphanumeric, hyphens, underscores only (no spaces)
        bytes32[] memory features = new bytes32[](0);
        registry.registerFactory(
            address(erc404Factory),
            "ERC404",
            "ERC404-Factory",
            "ERC404 Factory",
            "ipfs://erc404-factory"
        );
        registry.registerFactory(
            address(erc1155Factory),
            "ERC1155",
            "ERC1155-Factory",
            "ERC1155 Factory",
            "ipfs://erc1155-factory"
        );

        // Setup default bonding curve parameters for ERC404
        defaultCurveParams = ERC404BondingInstance.BondingCurveParams({
            initialPrice: 0.025 ether,
            quarticCoeff: 3 gwei,
            cubicCoeff: 1333333333,
            quadraticCoeff: 2 gwei,
            normalizationFactor: 1e7
        });

        bytes32[] memory passwordHashes = new bytes32[](2);
        passwordHashes[0] = keccak256("password1");
        passwordHashes[1] = keccak256("password2");

        uint256[] memory volumeCaps = new uint256[](2);
        volumeCaps[0] = 1000 * 1e18;
        volumeCaps[1] = 10000 * 1e18;

        defaultTierConfig = ERC404BondingInstance.TierConfig({
            tierType: ERC404BondingInstance.TierType.VOLUME_CAP,
            passwordHashes: passwordHashes,
            volumeCaps: volumeCaps,
            tierUnlockTimes: new uint256[](0)
        });

        vm.stopPrank();
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
            "poggers",
            "POG",
            "ipfs://metadata",
            MAX_SUPPLY,
            10,
            defaultCurveParams,
            defaultTierConfig,
            creator1,
            address(vault),
            address(mockHook),
            ""
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
            address(vault),
            ""
        );

        vm.stopPrank();

        assertTrue(registry.isNameTaken("poggers"), "Name should be taken after ERC1155 creation");
    }

    /**
     * @notice CRITICAL TEST: ERC404 cannot use name already taken by ERC1155
     * @dev This proves cross-factory namespace protection works
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
            address(vault),
            ""
        );
        vm.stopPrank();

        // Creator2 tries to create ERC404 instance with same name - should FAIL
        vm.startPrank(creator2);
        vm.expectRevert("Name already taken");
        erc404Factory.createInstance{value: INSTANCE_FEE}(
            "poggers",
            "POG",
            "ipfs://metadata",
            MAX_SUPPLY,
            10,
            defaultCurveParams,
            defaultTierConfig,
            creator2,
            address(vault),
            address(mockHook),
            ""
        );
        vm.stopPrank();
    }

    /**
     * @notice CRITICAL TEST: ERC1155 cannot use name already taken by ERC404
     * @dev This proves cross-factory namespace protection works in reverse
     */
    function test_crossFactory_erc404ThenErc1155_reverts() public {
        vm.deal(creator1, 1 ether);
        vm.deal(creator2, 1 ether);

        // Creator1 creates ERC404 instance named "poggers"
        vm.startPrank(creator1);
        erc404Factory.createInstance{value: INSTANCE_FEE}(
            "poggers",
            "POG",
            "ipfs://metadata",
            MAX_SUPPLY,
            10,
            defaultCurveParams,
            defaultTierConfig,
            creator1,
            address(vault),
            address(mockHook),
            ""
        );
        vm.stopPrank();

        // Creator2 tries to create ERC1155 instance with same name - should FAIL
        vm.startPrank(creator2);
        vm.expectRevert("Name already taken");
        erc1155Factory.createInstance{value: INSTANCE_FEE}(
            "poggers",
            "ipfs://metadata",
            creator2,
            address(vault),
            ""
        );
        vm.stopPrank();
    }

    /**
     * @notice Test case-insensitive collision detection
     * @dev "POGGERS" and "poggers" should be considered the same name
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
            address(vault),
            ""
        );
        vm.stopPrank();

        // Creator2 tries "poggers" (lowercase) - should FAIL
        vm.startPrank(creator2);
        vm.expectRevert("Name already taken");
        erc404Factory.createInstance{value: INSTANCE_FEE}(
            "poggers",
            "POG",
            "ipfs://metadata",
            MAX_SUPPLY,
            10,
            defaultCurveParams,
            defaultTierConfig,
            creator2,
            address(vault),
            address(mockHook),
            ""
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
            "poggers",
            "POG",
            "ipfs://metadata",
            MAX_SUPPLY,
            10,
            defaultCurveParams,
            defaultTierConfig,
            creator1,
            address(vault),
            address(mockHook),
            ""
        );
        vm.stopPrank();

        vm.startPrank(creator2);
        vm.expectRevert("Name already taken");
        erc404Factory.createInstance{value: INSTANCE_FEE}(
            "poggers",
            "POG2",
            "ipfs://metadata2",
            MAX_SUPPLY,
            10,
            defaultCurveParams,
            defaultTierConfig,
            creator2,
            address(vault),
            address(mockHook),
            ""
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
            address(vault),
            ""
        );
        vm.stopPrank();

        vm.startPrank(creator2);
        address instance2 = erc404Factory.createInstance{value: INSTANCE_FEE}(
            "different_name",
            "DIFF",
            "ipfs://metadata",
            MAX_SUPPLY,
            10,
            defaultCurveParams,
            defaultTierConfig,
            creator2,
            address(vault),
            address(mockHook),
            ""
        );
        vm.stopPrank();

        assertTrue(instance1 != address(0), "First instance should be created");
        assertTrue(instance2 != address(0), "Second instance should be created");
        assertTrue(instance1 != instance2, "Instances should be different");
    }
}
