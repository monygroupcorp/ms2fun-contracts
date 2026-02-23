// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/vaults/UltraAlignmentVaultFactory.sol";
import "../../src/vaults/UltraAlignmentVault.sol";
import {IVaultSwapRouter} from "../../src/interfaces/IVaultSwapRouter.sol";
import {IVaultPriceValidator} from "../../src/interfaces/IVaultPriceValidator.sol";
import {MockVaultSwapRouter} from "../mocks/MockVaultSwapRouter.sol";
import {MockVaultPriceValidator} from "../mocks/MockVaultPriceValidator.sol";
import {MockEXECToken} from "../mocks/MockEXECToken.sol";

contract UltraAlignmentVaultFactoryTest is Test {
    UltraAlignmentVaultFactory public factory;
    MockEXECToken public alignmentToken;

    address public owner;
    address public mockPoolManager;
    address public mockV3Router;
    address public mockV2Router;
    address public mockV2Factory;
    address public mockV3Factory;
    address public mockWeth;

    event VaultDeployed(address indexed vault, address indexed alignmentToken, address indexed creator);

    function setUp() public {
        owner = address(this);
        mockPoolManager = makeAddr("poolManager");
        mockV3Router = makeAddr("v3Router");
        mockV2Router = makeAddr("v2Router");
        mockV2Factory = makeAddr("v2Factory");
        mockV3Factory = makeAddr("v3Factory");
        mockWeth = makeAddr("weth");

        alignmentToken = new MockEXECToken(1000000e18);

        factory = new UltraAlignmentVaultFactory(
            mockWeth,
            mockPoolManager,
            mockV3Router,
            mockV2Router,
            mockV2Factory,
            mockV3Factory
        );
    }

    function test_deployVault_setsAlignmentToken() public {
        address vault = factory.deployVault(
            address(alignmentToken),
            owner,
            100,
            IVaultSwapRouter(address(0)),
            IVaultPriceValidator(address(0))
        );

        assertEq(UltraAlignmentVault(payable(vault)).alignmentToken(), address(alignmentToken));
    }

    function test_deployVault_usesDefaultSwapRouter() public {
        address vault = factory.deployVault(
            address(alignmentToken),
            owner,
            100,
            IVaultSwapRouter(address(0)),
            IVaultPriceValidator(address(0))
        );

        assertEq(
            address(UltraAlignmentVault(payable(vault)).swapRouter()),
            address(factory.defaultSwapRouter()),
            "Should use default swap router"
        );
        assertEq(
            address(UltraAlignmentVault(payable(vault)).priceValidator()),
            address(factory.defaultPriceValidator()),
            "Should use default price validator"
        );
    }

    function test_deployVault_acceptsCustomSwapRouter() public {
        MockVaultSwapRouter customRouter = new MockVaultSwapRouter();
        MockVaultPriceValidator customValidator = new MockVaultPriceValidator();

        address vault = factory.deployVault(
            address(alignmentToken),
            owner,
            100,
            IVaultSwapRouter(address(customRouter)),
            IVaultPriceValidator(address(customValidator))
        );

        assertEq(
            address(UltraAlignmentVault(payable(vault)).swapRouter()),
            address(customRouter),
            "Should use custom swap router"
        );
        assertEq(
            address(UltraAlignmentVault(payable(vault)).priceValidator()),
            address(customValidator),
            "Should use custom price validator"
        );
    }

    function test_deployVault_differentInstancesAreIndependent() public {
        MockEXECToken token2 = new MockEXECToken(1000000e18);

        address vault1 = factory.deployVault(
            address(alignmentToken),
            owner,
            100,
            IVaultSwapRouter(address(0)),
            IVaultPriceValidator(address(0))
        );

        address vault2 = factory.deployVault(
            address(token2),
            owner,
            200,
            IVaultSwapRouter(address(0)),
            IVaultPriceValidator(address(0))
        );

        assertTrue(vault1 != vault2, "Vaults should be different addresses");
        assertEq(UltraAlignmentVault(payable(vault1)).alignmentToken(), address(alignmentToken));
        assertEq(UltraAlignmentVault(payable(vault2)).alignmentToken(), address(token2));
        assertEq(UltraAlignmentVault(payable(vault1)).creatorYieldCutBps(), 100);
        assertEq(UltraAlignmentVault(payable(vault2)).creatorYieldCutBps(), 200);
    }

    function test_deployVault_emitsVaultDeployed() public {
        vm.expectEmit(false, true, true, false);
        emit VaultDeployed(address(0), address(alignmentToken), owner);

        factory.deployVault(
            address(alignmentToken),
            owner,
            100,
            IVaultSwapRouter(address(0)),
            IVaultPriceValidator(address(0))
        );
    }

    function test_constructor_storesAddresses() public view {
        assertEq(factory.weth(), mockWeth);
        assertEq(factory.poolManager(), mockPoolManager);
        assertEq(factory.v3Router(), mockV3Router);
        assertEq(factory.v2Router(), mockV2Router);
        assertEq(factory.v2Factory(), mockV2Factory);
        assertEq(factory.v3Factory(), mockV3Factory);
        assertTrue(address(factory.defaultSwapRouter()) != address(0));
        assertTrue(address(factory.defaultPriceValidator()) != address(0));
        assertTrue(factory.vaultImplementation() != address(0));
    }
}
