// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/vaults/uni/UniAlignmentVaultFactory.sol";
import {UniAlignmentVault} from "../../src/vaults/uni/UniAlignmentVault.sol";
import {IVaultPriceValidator} from "../../src/interfaces/IVaultPriceValidator.sol";
import {IAlignmentRegistry} from "../../src/master/interfaces/IAlignmentRegistry.sol";
import {MockZRouter} from "../mocks/MockZRouter.sol";
import {MockVaultPriceValidator} from "../mocks/MockVaultPriceValidator.sol";
import {MockAlignmentRegistry} from "../mocks/MockAlignmentRegistry.sol";
import {MockEXECToken} from "../mocks/MockEXECToken.sol";
import {CREATEX} from "../../src/shared/CreateXConstants.sol";
import {CREATEX_BYTECODE} from "createx-forge/script/CreateX.d.sol";

contract UniAlignmentVaultFactoryTest is Test {
    UniAlignmentVaultFactory public factory;
    MockEXECToken public alignmentToken;
    MockAlignmentRegistry public mockRegistry;

    address public owner;
    address public mockPoolManager;
    address public mockWeth;

    MockZRouter public mockZRouter;
    MockVaultPriceValidator public mockPriceValidator;

    uint256 internal _saltCounter;

    uint256 constant TARGET_ID = 1;

    event VaultDeployed(address indexed vault, address indexed alignmentToken);

    function _nextSalt() internal returns (bytes32) {
        _saltCounter++;
        return bytes32(abi.encodePacked(address(factory), uint8(0x00), bytes11(uint88(_saltCounter))));
    }

    function setUp() public {
        vm.etch(CREATEX, CREATEX_BYTECODE);
        owner = address(this);
        mockPoolManager = makeAddr("poolManager");
        mockWeth = makeAddr("weth");

        alignmentToken = new MockEXECToken(1000000e18);

        mockZRouter = new MockZRouter();
        mockPriceValidator = new MockVaultPriceValidator();
        mockRegistry = new MockAlignmentRegistry();
        mockRegistry.setTargetActive(TARGET_ID, true);
        mockRegistry.setTokenInTarget(TARGET_ID, address(alignmentToken), true);

        factory = new UniAlignmentVaultFactory(
            mockWeth,
            mockPoolManager,
            address(mockZRouter),
            3000,
            60,
            IVaultPriceValidator(address(mockPriceValidator)),
            IAlignmentRegistry(address(mockRegistry))
        );
    }

    function test_deployVault_setsAlignmentToken() public {
        address vault = factory.deployVault(
            _nextSalt(),
            address(alignmentToken),
            TARGET_ID,
            IVaultPriceValidator(address(0))
        );

        assertEq(UniAlignmentVault(payable(vault)).alignmentToken(), address(alignmentToken));
    }

    function test_deployVault_usesFactoryZRouterConfig() public {
        address vault = factory.deployVault(
            _nextSalt(),
            address(alignmentToken),
            TARGET_ID,
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
            _nextSalt(),
            address(alignmentToken),
            TARGET_ID,
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
        mockRegistry.setTokenInTarget(TARGET_ID, address(token2), true);

        address vault1 = factory.deployVault(
            _nextSalt(),
            address(alignmentToken),
            TARGET_ID,
            IVaultPriceValidator(address(0))
        );

        address vault2 = factory.deployVault(
            _nextSalt(),
            address(token2),
            TARGET_ID,
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
            _nextSalt(),
            address(alignmentToken),
            TARGET_ID,
            IVaultPriceValidator(address(0))
        );
    }

    function test_deployVault_revertsWhenTokenNotInTarget() public {
        address rogueToken = address(0xBAD);

        vm.expectRevert(UniAlignmentVault.TokenNotInTarget.selector);
        factory.deployVault(
            _nextSalt(),
            rogueToken,
            TARGET_ID,
            IVaultPriceValidator(address(0))
        );
    }

    function test_deployVault_revertsWhenTargetNotActive() public {
        mockRegistry.setTargetActive(TARGET_ID, false);

        vm.expectRevert(UniAlignmentVault.TargetNotActive.selector);
        factory.deployVault(
            _nextSalt(),
            address(alignmentToken),
            TARGET_ID,
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
        assertEq(address(factory.alignmentRegistry()), address(mockRegistry));
        assertTrue(factory.vaultImplementation() != address(0));
    }
}
