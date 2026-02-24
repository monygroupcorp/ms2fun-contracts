// test/factories/erc404cypher/ERC404CypherFactory.t.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC404CypherFactory} from "../../../src/factories/erc404cypher/ERC404CypherFactory.sol";
import {ERC404CypherBondingInstance} from "../../../src/factories/erc404cypher/ERC404CypherBondingInstance.sol";
import {CypherLiquidityDeployerModule} from "../../../src/factories/erc404cypher/CypherLiquidityDeployerModule.sol";
import {UltraAlignmentCypherVault} from "../../../src/vaults/cypher/UltraAlignmentCypherVault.sol";
import {UltraAlignmentCypherVaultFactory} from "../../../src/vaults/cypher/UltraAlignmentCypherVaultFactory.sol";
import {CurveParamsComputer} from "../../../src/factories/erc404/CurveParamsComputer.sol";
import {MockAlgebraFactory, MockAlgebraPositionManager, MockAlgebraSwapRouter} from "../../mocks/MockCypherAlgebra.sol";
import {MockWETH} from "../../mocks/MockWETH.sol";
import {MockMasterRegistry} from "../../mocks/MockMasterRegistry.sol";

contract ERC404CypherFactoryTest is Test {
    ERC404CypherFactory factory;
    MockMasterRegistry masterRegistry;
    CypherLiquidityDeployerModule deployer;
    ERC404CypherBondingInstance implementation;
    UltraAlignmentCypherVaultFactory vaultFactory;
    CurveParamsComputer curveComputer;
    MockAlgebraFactory algebraFactory;
    MockAlgebraPositionManager positionManager;
    MockAlgebraSwapRouter swapRouter;
    MockWETH weth;

    address protocol = makeAddr("protocol");
    address creator = makeAddr("creator");
    address treasury = makeAddr("treasury");
    address globalMsgRegistry = makeAddr("globalMsgRegistry");
    address instanceCreator = makeAddr("instanceCreator");
    address alignmentTarget = makeAddr("alignmentTarget");

    function setUp() public {
        masterRegistry = new MockMasterRegistry();
        deployer = new CypherLiquidityDeployerModule();
        implementation = new ERC404CypherBondingInstance();
        curveComputer = new CurveParamsComputer(protocol);
        algebraFactory = new MockAlgebraFactory();
        positionManager = new MockAlgebraPositionManager();
        swapRouter = new MockAlgebraSwapRouter();
        weth = new MockWETH();

        UltraAlignmentCypherVault vaultImpl = new UltraAlignmentCypherVault();
        vaultFactory = new UltraAlignmentCypherVaultFactory(address(vaultImpl));

        factory = new ERC404CypherFactory(
            address(implementation),
            address(masterRegistry),
            address(vaultFactory),
            address(deployer),
            address(algebraFactory),
            address(positionManager),
            address(swapRouter),
            address(weth),
            protocol,
            creator,
            0,    // creatorFeeBps
            50,   // creatorGraduationFeeBps
            globalMsgRegistry,
            address(curveComputer)
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

    function _defaultTierConfig() internal pure returns (ERC404CypherBondingInstance.TierConfig memory) {
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = keccak256("open");
        uint256[] memory caps = new uint256[](1);
        caps[0] = type(uint256).max;

        return ERC404CypherBondingInstance.TierConfig({
            tierType: ERC404CypherBondingInstance.TierType.VOLUME_CAP,
            passwordHashes: hashes,
            volumeCaps: caps,
            tierUnlockTimes: new uint256[](0)
        });
    }

    function test_createInstance_deploysInstanceAndVault() public {
        vm.deal(address(this), 0.01 ether);
        address instance = factory.createInstance{value: 0.01 ether}(
            "CypherToken", "CYPH", "", 100, 0, _defaultTierConfig(),
            instanceCreator, alignmentTarget, ""
        );

        assertNotEq(instance, address(0));
        ERC404CypherBondingInstance inst = ERC404CypherBondingInstance(payable(instance));
        assertEq(inst.factory(), address(factory));
        assertNotEq(address(inst.vault()), address(0));
        assertEq(inst.weth(), address(weth));
        assertEq(inst.algebraFactory(), address(algebraFactory));
    }

    function test_createInstance_revertsOnInsufficientFee() public {
        vm.deal(address(this), 0.005 ether);
        vm.expectRevert();
        factory.createInstance{value: 0.005 ether}(
            "CypherToken", "CYPH", "", 100, 0, _defaultTierConfig(),
            instanceCreator, alignmentTarget, ""
        );
    }

    function test_createInstance_revertsOnInactiveProfile() public {
        vm.deal(address(this), 0.01 ether);
        vm.expectRevert();
        factory.createInstance{value: 0.01 ether}(
            "CypherToken", "CYPH", "", 100, 99, _defaultTierConfig(),
            instanceCreator, alignmentTarget, ""
        );
    }

    function test_createInstance_revertsOnDuplicateName() public {
        vm.deal(address(this), 0.02 ether);
        factory.createInstance{value: 0.01 ether}(
            "Taken", "TST", "", 100, 0, _defaultTierConfig(),
            instanceCreator, alignmentTarget, ""
        );
        // Real MasterRegistry marks name taken on registerInstance; simulate that here
        masterRegistry.markNameTaken("Taken");
        vm.expectRevert();
        factory.createInstance{value: 0.01 ether}(
            "Taken", "TST2", "", 100, 0, _defaultTierConfig(),
            instanceCreator, alignmentTarget, ""
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
            "FeeTest", "FT", "", 100, 0, _defaultTierConfig(),
            instanceCreator, alignmentTarget, ""
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
