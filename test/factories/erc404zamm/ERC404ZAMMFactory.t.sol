// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC404ZAMMFactory} from "../../../src/factories/erc404zamm/ERC404ZAMMFactory.sol";
import {ERC404ZAMMBondingInstance} from "../../../src/factories/erc404zamm/ERC404ZAMMBondingInstance.sol";
import {ZAMMLiquidityDeployerModule} from "../../../src/factories/erc404zamm/ZAMMLiquidityDeployerModule.sol";
import {CurveParamsComputer} from "../../../src/factories/erc404/CurveParamsComputer.sol";
import {PasswordTierGatingModule} from "../../../src/gating/PasswordTierGatingModule.sol";
import {MockZAMM} from "../../mocks/MockZAMM.sol";
import {IdentityParams} from "../../../src/interfaces/IFactoryTypes.sol";
import {ComponentRegistry} from "../../../src/registry/ComponentRegistry.sol";
import {LibClone} from "solady/utils/LibClone.sol";

// Minimal mock MasterRegistry
contract MockMasterRegistryZ {
    mapping(bytes32 => bool) public takenHashes;

    function isNameTaken(string memory name) external view returns (bool) {
        return takenHashes[keccak256(bytes(name))];
    }

    function registerInstance(
        address,
        address,
        address,
        string memory name,
        string memory,
        address
    ) external {
        takenHashes[keccak256(bytes(name))] = true;
    }
}

contract ERC404ZAMMFactoryTest is Test {
    ERC404ZAMMFactory factory;
    MockZAMM zamm;
    MockMasterRegistryZ masterRegistry;
    ZAMMLiquidityDeployerModule deployer;
    ERC404ZAMMBondingInstance implementation;
    CurveParamsComputer curveComputer;
    PasswordTierGatingModule tierGatingModule;
    ComponentRegistry componentRegistry;

    address protocol = makeAddr("protocol");
    address treasury = makeAddr("treasury");
    address globalMsgRegistry = makeAddr("globalMsgRegistry");
    address vault = makeAddr("vault");
    address instanceOwner = makeAddr("instanceOwner");

    function setUp() public {
        zamm = new MockZAMM();
        masterRegistry = new MockMasterRegistryZ();
        deployer = new ZAMMLiquidityDeployerModule();
        implementation = new ERC404ZAMMBondingInstance();
        curveComputer = new CurveParamsComputer(protocol);
        tierGatingModule = new PasswordTierGatingModule();

        ComponentRegistry compRegImpl = new ComponentRegistry();
        address compRegProxy = LibClone.deployERC1967(address(compRegImpl));
        componentRegistry = ComponentRegistry(compRegProxy);
        componentRegistry.initialize(protocol);

        factory = new ERC404ZAMMFactory(
            ERC404ZAMMFactory.CoreConfig({
                implementation: address(implementation),
                masterRegistry: address(masterRegistry),
                zamm: address(zamm),
                zRouter: address(0), // zRouter (unused in basic tests)
                feeOrHook: 30,
                protocol: protocol
            }),
            ERC404ZAMMFactory.ModuleConfig({
                globalMessageRegistry: globalMsgRegistry,
                curveComputer: address(curveComputer),
                liquidityDeployer: address(deployer),
                tierGatingModule: address(tierGatingModule),
                componentRegistry: address(componentRegistry)
            })
        );

        vm.prank(protocol);
        factory.setProtocolTreasury(treasury);

        // Set a default profile (id=0)
        vm.prank(protocol);
        factory.setProfile(0, ERC404ZAMMFactory.GraduationProfile({
            targetETH: 10 ether,
            unitPerNFT: 1,
            liquidityReserveBps: 2000, // 20%
            active: true
        }));

        // vault must be a contract for the factory's check
        vm.etch(vault, hex"00");
    }

    function _identity(string memory name_, string memory symbol_) internal view returns (IdentityParams memory) {
        return IdentityParams({
            name: name_,
            symbol: symbol_,
            styleUri: "",
            owner: instanceOwner,
            vault: address(0), // vault passed separately
            nftCount: 100,
            profileId: 0
        });
    }

    function test_createInstance_deploysAndRegisters() public {
        vm.deal(address(this), 0.01 ether);
        address instance = factory.createInstance{value: 0.01 ether}(
            _identity("TestToken", "TST"),
            "",
            vault
        );

        assertNotEq(instance, address(0));
        assertEq(ERC404ZAMMBondingInstance(payable(instance)).factory(), address(factory));
    }

    function test_createInstance_revertsOnInactiveProfile() public {
        vm.deal(address(this), 0.01 ether);
        IdentityParams memory id = IdentityParams({
            name: "TestToken",
            symbol: "TST",
            styleUri: "",
            owner: instanceOwner,
            vault: address(0),
            nftCount: 100,
            profileId: 99 // inactive profile
        });
        vm.expectRevert();
        factory.createInstance{value: 0.01 ether}(id, "", vault);
    }

    function test_createInstance_revertsOnDuplicateName() public {
        vm.deal(address(this), 0.02 ether);
        factory.createInstance{value: 0.01 ether}(
            _identity("Taken", "TST"),
            "",
            vault
        );

        vm.expectRevert();
        factory.createInstance{value: 0.01 ether}(
            _identity("Taken", "TST2"),
            "",
            vault
        );
    }

    function test_setProfile_onlyProtocol() public {
        vm.expectRevert();
        factory.setProfile(1, ERC404ZAMMFactory.GraduationProfile({
            targetETH: 5 ether,
            unitPerNFT: 1,
            liquidityReserveBps: 1000,
            active: true
        }));
    }

    function test_withdrawProtocolFees() public {
        // Create an instance to accumulate fees
        vm.deal(address(this), 0.01 ether);
        factory.createInstance{value: 0.01 ether}(
            _identity("FeeTest", "FT"),
            "",
            vault
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

    function test_zammFactory_createInstanceWithGating_revertsOnUnapprovedModule() public {
        address unapprovedModule = address(0xBAD);

        vm.deal(address(this), 0.01 ether);
        vm.expectRevert("Unapproved component");
        factory.createInstance{value: 0.01 ether}(
            _identity("GatedToken", "GATE"),
            "",
            unapprovedModule,
            vault
        );
    }

    function test_zammFactory_createInstance_noGating_stillWorks() public {
        vm.deal(address(this), 0.01 ether);
        address instance = factory.createInstance{value: 0.01 ether}(
            _identity("OpenToken", "OPEN"),
            "",
            vault
        );
        assertTrue(instance != address(0));
    }
}
