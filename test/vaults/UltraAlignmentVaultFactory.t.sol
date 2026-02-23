// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/vaults/UltraAlignmentVaultFactory.sol";
import "../../src/vaults/UltraAlignmentVault.sol";
import {IVaultPriceValidator} from "../../src/interfaces/IVaultPriceValidator.sol";
import {MockZRouter} from "../mocks/MockZRouter.sol";
import {MockVaultPriceValidator} from "../mocks/MockVaultPriceValidator.sol";
import {MockEXECToken} from "../mocks/MockEXECToken.sol";

contract UltraAlignmentVaultFactoryTest is Test {
    UltraAlignmentVaultFactory public factory;
    MockEXECToken public alignmentToken;

    address public owner;
    address public mockPoolManager;
    address public mockWeth;

    MockZRouter public mockZRouter;
    MockVaultPriceValidator public mockPriceValidator;

    event VaultDeployed(address indexed vault, address indexed alignmentToken, address indexed creator);

    function setUp() public {
        owner = address(this);
        mockPoolManager = makeAddr("poolManager");
        mockWeth = makeAddr("weth");

        alignmentToken = new MockEXECToken(1000000e18);

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
    }

    function test_deployVault_setsAlignmentToken() public {
        address vault = factory.deployVault(
            address(alignmentToken),
            owner,
            100,
            IVaultPriceValidator(address(0))
        );

        assertEq(UltraAlignmentVault(payable(vault)).alignmentToken(), address(alignmentToken));
    }

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

    function test_deployVault_differentInstancesAreIndependent() public {
        MockEXECToken token2 = new MockEXECToken(1000000e18);

        address vault1 = factory.deployVault(
            address(alignmentToken),
            owner,
            100,
            IVaultPriceValidator(address(0))
        );

        address vault2 = factory.deployVault(
            address(token2),
            owner,
            200,
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
            IVaultPriceValidator(address(0))
        );
    }

    function test_constructor_storesAddresses() public view {
        assertEq(factory.weth(), mockWeth);
        assertEq(factory.poolManager(), mockPoolManager);
        assertEq(factory.zRouter(), address(mockZRouter));
        assertEq(factory.zRouterFee(), 3000);
        assertEq(factory.zRouterTickSpacing(), 60);
        assertEq(address(factory.defaultPriceValidator()), address(mockPriceValidator));
        assertTrue(factory.vaultImplementation() != address(0));
    }
}
