// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC404ZAMMFactory} from "../../../src/factories/erc404zamm/ERC404ZAMMFactory.sol";
import {ERC404ZAMMBondingInstance} from "../../../src/factories/erc404zamm/ERC404ZAMMBondingInstance.sol";
import {ZAMMLiquidityDeployerModule} from "../../../src/factories/erc404zamm/ZAMMLiquidityDeployerModule.sol";
import {CurveParamsComputer} from "../../../src/factories/erc404/CurveParamsComputer.sol";
import {MockZAMM} from "../../mocks/MockZAMM.sol";
import {BondingCurveMath} from "../../../src/factories/erc404/libraries/BondingCurveMath.sol";

// Minimal mock MasterRegistry
contract MockMasterRegistry {
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
    MockMasterRegistry masterRegistry;
    ZAMMLiquidityDeployerModule deployer;
    ERC404ZAMMBondingInstance implementation;
    CurveParamsComputer curveComputer;

    address protocol = makeAddr("protocol");
    address creator = makeAddr("creator");
    address treasury = makeAddr("treasury");
    address globalMsgRegistry = makeAddr("globalMsgRegistry");
    address vault = makeAddr("vault");

    function setUp() public {
        zamm = new MockZAMM();
        masterRegistry = new MockMasterRegistry();
        deployer = new ZAMMLiquidityDeployerModule();
        implementation = new ERC404ZAMMBondingInstance();
        curveComputer = new CurveParamsComputer(protocol);

        factory = new ERC404ZAMMFactory(
            address(implementation),
            address(masterRegistry),
            address(zamm),
            address(0), // zRouter (unused in basic tests)
            30,         // feeOrHook
            100,        // taxBps (1%)
            protocol,
            creator,
            0,          // creatorFeeBps
            50,         // creatorGraduationFeeBps
            address(deployer),
            globalMsgRegistry,
            address(curveComputer)
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

    function _defaultTierConfig() internal pure returns (ERC404ZAMMBondingInstance.TierConfig memory) {
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = keccak256("open");
        uint256[] memory caps = new uint256[](1);
        caps[0] = type(uint256).max;

        return ERC404ZAMMBondingInstance.TierConfig({
            tierType: ERC404ZAMMBondingInstance.TierType.VOLUME_CAP,
            passwordHashes: hashes,
            volumeCaps: caps,
            tierUnlockTimes: new uint256[](0)
        });
    }

    function test_createInstance_deploysAndRegisters() public {
        vm.deal(address(this), 0.01 ether);
        address instance = factory.createInstance{value: 0.01 ether}(
            "TestToken", "TST", "", 100, 0, _defaultTierConfig(), address(this), vault, ""
        );

        assertNotEq(instance, address(0));
        assertEq(ERC404ZAMMBondingInstance(payable(instance)).factory(), address(factory));
    }

    function test_createInstance_revertsOnInsufficientFee() public {
        vm.deal(address(this), 0.005 ether);
        vm.expectRevert();
        factory.createInstance{value: 0.005 ether}(
            "TestToken", "TST", "", 100, 0, _defaultTierConfig(), address(this), vault, ""
        );
    }

    function test_createInstance_revertsOnInactiveProfile() public {
        vm.deal(address(this), 0.01 ether);
        vm.expectRevert();
        factory.createInstance{value: 0.01 ether}(
            "TestToken", "TST", "", 100, 99, _defaultTierConfig(), address(this), vault, ""
        );
    }

    function test_createInstance_revertsOnDuplicateName() public {
        vm.deal(address(this), 0.02 ether);
        factory.createInstance{value: 0.01 ether}(
            "Taken", "TST", "", 100, 0, _defaultTierConfig(), address(this), vault, ""
        );

        vm.expectRevert();
        factory.createInstance{value: 0.01 ether}(
            "Taken", "TST2", "", 100, 0, _defaultTierConfig(), address(this), vault, ""
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
            "FeeTest", "FT", "", 100, 0, _defaultTierConfig(), address(this), vault, ""
        );

        uint256 treasuryBefore = treasury.balance;
        vm.prank(protocol);
        factory.withdrawProtocolFees();
        assertGt(treasury.balance, treasuryBefore);
    }

    function test_protocol_and_creator_view() public view {
        assertEq(factory.protocol(), protocol);
        assertEq(factory.creator(), creator);
    }
}
