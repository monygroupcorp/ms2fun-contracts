// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {GrandCentral} from "../../src/dao/GrandCentral.sol";
import {RevenueConductor} from "../../src/dao/conductors/RevenueConductor.sol";
import {ProtocolTreasuryV1} from "../../src/treasury/ProtocolTreasuryV1.sol";
import {MockSafe} from "../mocks/MockSafe.sol";

contract RevenueConductorTest is Test {
    GrandCentral public dao;
    MockSafe public mockSafe;
    ProtocolTreasuryV1 public treasury;
    RevenueConductor public router;

    address public founder = makeAddr("founder");
    address public alice = makeAddr("alice");
    address public nobody = makeAddr("nobody");

    uint256 constant INITIAL_SHARES = 1000;

    function setUp() public {
        mockSafe = new MockSafe();
        dao = new GrandCentral(address(mockSafe), founder, INITIAL_SHARES, 5 days, 2 days, 0, 1, 66);

        treasury = new ProtocolTreasuryV1();
        treasury.initialize(address(this)); // test contract is owner

        // Deploy router: 100% dividend initially
        router = new RevenueConductor(address(dao), address(treasury), 10000, 0, 0);

        // Register router as manager conductor
        address[] memory addrs = new address[](1);
        addrs[0] = address(router);
        uint256[] memory perms = new uint256[](1);
        perms[0] = 2; // manager
        vm.prank(address(dao));
        dao.setConductors(addrs, perms);

        // Authorize router on treasury
        treasury.setAuthorizedRouter(address(router));

        // Fund Safe so pool funding checks pass
        vm.deal(address(mockSafe), 100 ether);
    }

    // ============ Constructor ============

    function test_Constructor_SetsImmutables() public view {
        assertEq(address(router.dao()), address(dao));
        assertEq(address(router.treasury()), address(treasury));
    }

    function test_Constructor_SetsInitialRatio() public view {
        assertEq(router.dividendBps(), 10000);
        assertEq(router.ragequitBps(), 0);
        assertEq(router.reserveBps(), 0);
    }

    function test_Constructor_RevertIfBpsMismatch() public {
        vm.expectRevert("bps must sum to 10000");
        new RevenueConductor(address(dao), address(treasury), 5000, 3000, 1000);
    }

    function test_Constructor_RevertIfZeroDao() public {
        vm.expectRevert("invalid dao");
        new RevenueConductor(address(0), address(treasury), 10000, 0, 0);
    }

    function test_Constructor_RevertIfZeroTreasury() public {
        vm.expectRevert("invalid treasury");
        new RevenueConductor(address(dao), address(0), 10000, 0, 0);
    }

    // ============ Sweep — Access Control ============

    function test_Sweep_RevertIfNotShareholder() public {
        vm.deal(address(treasury), 10 ether);
        vm.prank(nobody);
        vm.expectRevert("!shareholder");
        router.sweep();
    }

    function test_Sweep_WorksForShareholder() public {
        vm.deal(address(treasury), 10 ether);
        vm.prank(founder);
        router.sweep();
        // 100% dividend — claims pool should be funded
        assertEq(dao.claimsPoolBalance(), 10 ether);
    }

    // ============ Sweep — 100% Dividend ============

    function test_Sweep_AllToDividend() public {
        vm.deal(address(treasury), 10 ether);
        vm.prank(founder);
        router.sweep();

        assertEq(dao.claimsPoolBalance(), 10 ether);
        assertEq(dao.ragequitPool(), 0);
        assertEq(address(treasury).balance, 0);
    }

    // ============ Sweep — Three-Way Split ============

    function test_Sweep_ThreeWaySplit() public {
        // Reconfigure: 90% div, 5% rage, 5% reserve
        vm.prank(address(dao));
        router.setRatio(9000, 500, 500);

        vm.deal(address(treasury), 10 ether);
        vm.prank(founder);
        router.sweep();

        // Reserve stays: 0.5 ETH
        assertEq(address(treasury).balance, 0.5 ether);
        // Dividend: 9000/(9000+500) * 9.5 = ~9.0 ETH
        // Ragequit: remainder = ~0.5 ETH
        assertEq(dao.claimsPoolBalance() + dao.ragequitPool(), 9.5 ether);
        assertEq(router.totalRouted(), 9.5 ether);
    }

    // ============ Sweep — No Balance ============

    function test_Sweep_RevertIfNoBalance() public {
        vm.prank(founder);
        vm.expectRevert("nothing to route");
        router.sweep();
    }

    // ============ Sweep — Tracks Total Routed ============

    function test_Sweep_TracksTotalRouted() public {
        vm.deal(address(treasury), 5 ether);
        vm.prank(founder);
        router.sweep();
        assertEq(router.totalRouted(), 5 ether);

        vm.deal(address(treasury), 3 ether);
        vm.prank(founder);
        router.sweep();
        assertEq(router.totalRouted(), 8 ether);
    }

    // ============ Sweep — Only Ragequit (no dividend) ============

    function test_Sweep_OnlyRagequit() public {
        vm.prank(address(dao));
        router.setRatio(0, 10000, 0);

        vm.deal(address(treasury), 4 ether);
        vm.prank(founder);
        router.sweep();

        assertEq(dao.ragequitPool(), 4 ether);
        assertEq(dao.claimsPoolBalance(), 0);
    }

    // ============ Sweep — Emits Event ============

    function test_Sweep_EmitsEvent() public {
        vm.deal(address(treasury), 10 ether);

        vm.prank(founder);
        vm.expectEmit(false, false, false, true);
        emit RevenueConductor.Swept(10 ether, 10 ether, 0, 0);
        router.sweep();
    }

    // ============ setRatio ============

    function test_SetRatio_OnlyDAO() public {
        vm.prank(founder);
        vm.expectRevert(bytes("!dao"));
        router.setRatio(5000, 3000, 2000);
    }

    function test_SetRatio_RevertIfBpsMismatch() public {
        vm.prank(address(dao));
        vm.expectRevert("bps must sum to 10000");
        router.setRatio(5000, 3000, 1000);
    }

    function test_SetRatio_UpdatesRatio() public {
        vm.prank(address(dao));
        router.setRatio(8000, 1000, 1000);

        assertEq(router.dividendBps(), 8000);
        assertEq(router.ragequitBps(), 1000);
        assertEq(router.reserveBps(), 1000);
    }

    function test_SetRatio_EmitsEvent() public {
        vm.prank(address(dao));
        vm.expectEmit(false, false, false, true);
        emit RevenueConductor.RatioUpdated(8000, 1000, 1000);
        router.setRatio(8000, 1000, 1000);
    }

    // ============ GrandCentral — Manager Can Fund Pools ============

    function test_ManagerCanFundClaimsPool() public {
        // Router is manager — it calls fundClaimsPool internally via sweep
        // But let's test the modifier directly
        vm.deal(address(treasury), 5 ether);
        vm.prank(founder);
        router.sweep();
        assertGt(dao.claimsPoolBalance(), 0);
    }

    function test_ManagerCanFundRagequitPool() public {
        vm.prank(address(dao));
        router.setRatio(0, 10000, 0);

        vm.deal(address(treasury), 5 ether);
        vm.prank(founder);
        router.sweep();
        assertGt(dao.ragequitPool(), 0);
    }

    // ============ Treasury — Authorized Router ============

    function test_Treasury_AuthorizedRouterCanWithdraw() public {
        vm.deal(address(treasury), 5 ether);
        vm.prank(founder);
        router.sweep();
        // If we got here without revert, the authorized router withdrawal worked
        assertEq(router.totalRouted(), 5 ether);
    }

    function test_Treasury_SetAuthorizedRouter_OnlyOwner() public {
        vm.prank(nobody);
        vm.expectRevert();
        treasury.setAuthorizedRouter(nobody);
    }

    function test_Treasury_RandomCannotWithdraw() public {
        vm.deal(address(treasury), 5 ether);
        vm.prank(nobody);
        vm.expectRevert();
        treasury.withdrawETH(nobody, 5 ether);
    }
}
