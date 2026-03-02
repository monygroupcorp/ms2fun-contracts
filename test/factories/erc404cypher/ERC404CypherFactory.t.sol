// test/factories/erc404cypher/ERC404CypherFactory.t.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC404CypherFactory} from "../../../src/factories/erc404cypher/ERC404CypherFactory.sol";
import {ERC404CypherBondingInstance} from "../../../src/factories/erc404cypher/ERC404CypherBondingInstance.sol";
import {CypherLiquidityDeployerModule} from "../../../src/factories/erc404cypher/CypherLiquidityDeployerModule.sol";
import {CurveParamsComputer} from "../../../src/factories/erc404/CurveParamsComputer.sol";
import {PasswordTierGatingModule} from "../../../src/gating/PasswordTierGatingModule.sol";
import {MockAlgebraFactory, MockAlgebraPositionManager, MockAlgebraSwapRouter} from "../../mocks/MockCypherAlgebra.sol";
import {MockWETH} from "../../mocks/MockWETH.sol";
import {MockMasterRegistry} from "../../mocks/MockMasterRegistry.sol";
import {IdentityParams} from "../../../src/interfaces/IFactoryTypes.sol";
import {ComponentRegistry} from "../../../src/registry/ComponentRegistry.sol";
import {LibClone} from "solady/utils/LibClone.sol";

/// @dev Minimal vault stub — just needs code at the address
contract MockMinimalVault {
    receive() external payable {}
}

contract ERC404CypherFactoryTest is Test {
    ERC404CypherFactory factory;
    MockMasterRegistry masterRegistry;
    CypherLiquidityDeployerModule deployer;
    ERC404CypherBondingInstance implementation;
    CurveParamsComputer curveComputer;
    PasswordTierGatingModule tierGatingModule;
    ComponentRegistry componentRegistry;
    MockAlgebraFactory algebraFactory;
    MockAlgebraPositionManager positionManager;
    MockAlgebraSwapRouter swapRouter;
    MockWETH weth;

    address protocol = makeAddr("protocol");
    address creator = makeAddr("creator");
    address treasury = makeAddr("treasury");
    address globalMsgRegistry = makeAddr("globalMsgRegistry");
    address instanceCreator = makeAddr("instanceCreator");
    address mockVault; // deployed in setUp as MockMinimalVault

    function setUp() public {
        masterRegistry = new MockMasterRegistry();
        deployer = new CypherLiquidityDeployerModule();
        implementation = new ERC404CypherBondingInstance();
        curveComputer = new CurveParamsComputer(protocol);
        tierGatingModule = new PasswordTierGatingModule();
        algebraFactory = new MockAlgebraFactory();
        positionManager = new MockAlgebraPositionManager();
        swapRouter = new MockAlgebraSwapRouter();
        weth = new MockWETH();

        ComponentRegistry compRegImpl = new ComponentRegistry();
        address compRegProxy = LibClone.deployERC1967(address(compRegImpl));
        componentRegistry = ComponentRegistry(compRegProxy);
        componentRegistry.initialize(protocol);
        mockVault = address(new MockMinimalVault());

        factory = new ERC404CypherFactory(
            ERC404CypherFactory.CoreConfig({
                implementation: address(implementation),
                masterRegistry: address(masterRegistry),
                liquidityDeployer: address(deployer),
                algebraFactory: address(algebraFactory),
                positionManager: address(positionManager),
                swapRouter: address(swapRouter),
                weth: address(weth),
                protocol: protocol
            }),
            ERC404CypherFactory.ModuleConfig({
                globalMessageRegistry: globalMsgRegistry,
                curveComputer: address(curveComputer),
                tierGatingModule: address(tierGatingModule),
                componentRegistry: address(componentRegistry)
            })
        );

        vm.prank(protocol);
        factory.setProtocolTreasury(treasury);

        vm.prank(protocol);
        factory.setProfile(0, ERC404CypherFactory.GraduationProfile({
            targetETH: 10 ether,
            unitPerNFT: 1,
            liquidityReserveBps: 2000,
            active: true
        }));
    }

    function _identity(string memory name_, string memory symbol_) internal view returns (IdentityParams memory) {
        return IdentityParams({
            name: name_,
            symbol: symbol_,
            styleUri: "",
            owner: instanceCreator,
            vault: address(0), // unused: vault is passed as separate param to createInstance
            nftCount: 100,
            profileId: 0
        });
    }

    function test_createInstance_deploysInstanceAndVault() public {
        vm.deal(address(this), 0.01 ether);
        address instance = factory.createInstance{value: 0.01 ether}(
            _identity("CypherToken", "CYPH"),
            "",
            mockVault
        );

        assertNotEq(instance, address(0));
        ERC404CypherBondingInstance inst = ERC404CypherBondingInstance(payable(instance));
        assertEq(inst.factory(), address(factory));
        assertNotEq(address(inst.vault()), address(0));
        assertEq(inst.weth(), address(weth));
        assertEq(inst.algebraFactory(), address(algebraFactory));
    }

    function test_createInstance_revertsOnInactiveProfile() public {
        vm.deal(address(this), 0.01 ether);
        IdentityParams memory id = IdentityParams({
            name: "CypherToken",
            symbol: "CYPH",
            styleUri: "",
            owner: instanceCreator,
            vault: address(0),
            nftCount: 100,
            profileId: 99 // inactive profile
        });
        vm.expectRevert();
        factory.createInstance{value: 0.01 ether}(id, "", mockVault);
    }

    function test_createInstance_revertsOnDuplicateName() public {
        vm.deal(address(this), 0.02 ether);
        factory.createInstance{value: 0.01 ether}(
            _identity("Taken", "TST"),
            "",
            mockVault
        );
        // Real MasterRegistry marks name taken on registerInstance; simulate that here
        masterRegistry.markNameTaken("Taken");
        vm.expectRevert();
        factory.createInstance{value: 0.01 ether}(
            _identity("Taken", "TST2"),
            "",
            mockVault
        );
    }

    function test_setProfile_onlyProtocol() public {
        vm.expectRevert();
        factory.setProfile(1, ERC404CypherFactory.GraduationProfile({
            targetETH: 5 ether,
            unitPerNFT: 1,
            liquidityReserveBps: 1000,
            active: true
        }));
    }

    function test_withdrawProtocolFees() public {
        vm.deal(address(this), 0.01 ether);
        factory.createInstance{value: 0.01 ether}(
            _identity("FeeTest", "FT"),
            "",
            mockVault
        );

        uint256 treasuryBefore = treasury.balance;
        vm.prank(protocol);
        factory.withdrawProtocolFees();
        assertGt(treasury.balance, treasuryBefore);
    }

    function test_protocol_view() public view {
        assertEq(factory.protocol(), protocol);
    }

    // ── ComponentRegistry validation ──────────────────────────────────────────

    function test_cypherFactory_createInstanceWithGating_revertsOnUnapprovedModule() public {
        address unapprovedModule = address(0xBAD);

        vm.deal(address(this), 0.01 ether);
        vm.expectRevert("Unapproved component");
        factory.createInstance{value: 0.01 ether}(
            _identity("GatedToken", "GATE"),
            "",
            unapprovedModule,
            mockVault
        );
    }

    function test_cypherFactory_createInstance_noGating_stillWorks() public {
        vm.deal(address(this), 0.01 ether);
        address instance = factory.createInstance{value: 0.01 ether}(
            _identity("OpenToken", "OPEN"),
            "",
            mockVault
        );
        assertTrue(instance != address(0));
    }

    /// @dev After refactor, createInstance must accept a pre-deployed vault and wire it directly.
    function test_createInstance_acceptsPreExistingVault() public {
        // Deploy a minimal vault (any contract with code will do)
        address preDeployedVault = address(new MockMinimalVault());

        vm.deal(address(this), 0.01 ether);
        address instance = factory.createInstance{value: 0.01 ether}(
            _identity("VaultToken", "VT"),
            "",
            preDeployedVault
        );

        // Instance must be wired to the exact vault we passed, not a newly-created one
        assertEq(address(ERC404CypherBondingInstance(payable(instance)).vault()), preDeployedVault);
    }

    /// @dev Factory must be constructible without a vaultFactory argument.
    function test_createInstance_noVaultFactoryNeeded() public view {
        // If CoreConfig has no vaultFactory field, this test passes at compile time.
        // Verify that the factory (deployed in setUp without vaultFactory) works.
        assertNotEq(address(factory), address(0));
    }
}
