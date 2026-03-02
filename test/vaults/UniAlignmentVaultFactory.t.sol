// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/vaults/uni/UniAlignmentVaultFactory.sol";
import "../../src/vaults/uni/UniAlignmentVault.sol";
import {IVaultPriceValidator} from "../../src/interfaces/IVaultPriceValidator.sol";
import {MockZRouter} from "../mocks/MockZRouter.sol";
import {MockVaultPriceValidator} from "../mocks/MockVaultPriceValidator.sol";
import {MockEXECToken} from "../mocks/MockEXECToken.sol";

contract UniAlignmentVaultFactoryTest is Test {
    UniAlignmentVaultFactory public factory;
    MockEXECToken public alignmentToken;

    address public owner;
    address public mockPoolManager;
    address public mockWeth;

    MockZRouter public mockZRouter;
    MockVaultPriceValidator public mockPriceValidator;

    event VaultDeployed(address indexed vault, address indexed alignmentToken);

    function setUp() public {
        owner = address(this);
        mockPoolManager = makeAddr("poolManager");
        mockWeth = makeAddr("weth");

        alignmentToken = new MockEXECToken(1000000e18);

        mockZRouter = new MockZRouter();
        mockPriceValidator = new MockVaultPriceValidator();

        factory = new UniAlignmentVaultFactory(
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
            IVaultPriceValidator(address(0))
        );

        assertEq(UniAlignmentVault(payable(vault)).alignmentToken(), address(alignmentToken));
    }

    function test_deployVault_usesFactoryZRouterConfig() public {
        address vault = factory.deployVault(
            address(alignmentToken),
            IVaultPriceValidator(address(0))
        );

        assertEq(UniAlignmentVault(payable(vault)).zRouter(), factory.zRouter(), "Should use factory zRouter");
        assertEq(UniAlignmentVault(payable(vault)).zRouterFee(), factory.zRouterFee(), "Should use factory fee");
        assertEq(UniAlignmentVault(payable(vault)).zRouterTickSpacing(), factory.zRouterTickSpacing(), "Should use factory tickSpacing");
        assertEq(
            address(UniAlignmentVault(payable(vault)).priceValidator()),
            address(factory.defaultPriceValidator()),
            "Should use default price validator"
        );
    }

    function test_deployVault_acceptsCustomPriceValidator() public {
        MockVaultPriceValidator customValidator = new MockVaultPriceValidator();

        address vault = factory.deployVault(
            address(alignmentToken),
            IVaultPriceValidator(address(customValidator))
        );

        assertEq(
            address(UniAlignmentVault(payable(vault)).priceValidator()),
            address(customValidator),
            "Should use custom price validator"
        );
    }

    function test_deployVault_differentInstancesAreIndependent() public {
        MockEXECToken token2 = new MockEXECToken(1000000e18);

        address vault1 = factory.deployVault(
            address(alignmentToken),
            IVaultPriceValidator(address(0))
        );

        address vault2 = factory.deployVault(
            address(token2),
            IVaultPriceValidator(address(0))
        );

        assertTrue(vault1 != vault2, "Vaults should be different addresses");
        assertEq(UniAlignmentVault(payable(vault1)).alignmentToken(), address(alignmentToken));
        assertEq(UniAlignmentVault(payable(vault2)).alignmentToken(), address(token2));
    }

    function test_deployVault_emitsVaultDeployed() public {
        vm.expectEmit(false, true, false, false);
        emit VaultDeployed(address(0), address(alignmentToken));

        factory.deployVault(
            address(alignmentToken),
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
