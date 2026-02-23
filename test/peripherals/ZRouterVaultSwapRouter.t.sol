// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ZRouterVaultSwapRouter} from "../../src/peripherals/ZRouterVaultSwapRouter.sol";
import {IVaultSwapRouter} from "../../src/interfaces/IVaultSwapRouter.sol";
import {MockZRouter} from "../mocks/MockZRouter.sol";
import {MockEXECToken} from "../mocks/MockEXECToken.sol";

contract ZRouterVaultSwapRouterTest is Test {
    ZRouterVaultSwapRouter public router;
    MockZRouter public mockZRouter;
    MockEXECToken public token;

    address public vault;
    address public recipient;

    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;

    function setUp() public {
        vault = makeAddr("vault");
        recipient = makeAddr("recipient");
        token = new MockEXECToken(1_000_000e18);
        mockZRouter = new MockZRouter();

        // Pre-fund mockZRouter with ETH and tokens for swaps
        vm.deal(address(mockZRouter), 100 ether);
        token.transfer(address(mockZRouter), 100_000e18);
        // 1e15 ratio: 1000e18 tokens → 1e18 wei (1 ETH), fits within 100 ETH mock balance
        mockZRouter.setOutRatio(1e15);

        router = new ZRouterVaultSwapRouter(address(mockZRouter), FEE, TICK_SPACING);
    }

    // ── Config ──────────────────────────────────────────────────────────────

    function test_config_setsZRouter() public view {
        assertEq(router.zRouter(), address(mockZRouter));
    }

    function test_config_setsFee() public view {
        assertEq(router.fee(), FEE);
    }

    function test_config_setsTickSpacing() public view {
        assertEq(router.tickSpacing(), TICK_SPACING);
    }

    function test_implementsInterface() public view {
        // Static check: ensure ZRouterVaultSwapRouter satisfies IVaultSwapRouter
        IVaultSwapRouter iface = IVaultSwapRouter(address(router));
        assertTrue(address(iface) != address(0));
    }

    // ── swapETHForToken ──────────────────────────────────────────────────────

    function test_swapETHForToken_returnsTokens() public {
        vm.deal(vault, 1 ether);
        vm.prank(vault);
        uint256 received = router.swapETHForToken{value: 1 ether}(
            address(token),
            0,
            recipient
        );
        assertGt(received, 0, "should receive tokens");
    }

    function test_swapETHForToken_deliversToRecipient() public {
        vm.deal(vault, 1 ether);
        uint256 balBefore = token.balanceOf(recipient);
        vm.prank(vault);
        uint256 received = router.swapETHForToken{value: 1 ether}(
            address(token),
            0,
            recipient
        );
        assertEq(token.balanceOf(recipient) - balBefore, received);
    }

    function test_swapETHForToken_respectsMinOut() public {
        vm.deal(vault, 1 ether);
        vm.prank(vault);
        vm.expectRevert();
        router.swapETHForToken{value: 1 ether}(
            address(token),
            type(uint256).max, // impossibly high minOut
            recipient
        );
    }

    // ── swapTokenForETH ──────────────────────────────────────────────────────

    function test_swapTokenForETH_returnsETH() public {
        // Give vault some tokens and approve router
        token.transfer(vault, 1000e18);
        vm.prank(vault);
        token.approve(address(router), 1000e18);

        vm.prank(vault);
        uint256 ethReceived = router.swapTokenForETH(
            address(token),
            1000e18,
            0,
            recipient
        );
        assertGt(ethReceived, 0, "should receive ETH");
    }

    function test_swapTokenForETH_deliversETHToRecipient() public {
        token.transfer(vault, 1000e18);
        vm.prank(vault);
        token.approve(address(router), 1000e18);

        uint256 balBefore = recipient.balance;
        vm.prank(vault);
        uint256 ethReceived = router.swapTokenForETH(
            address(token),
            1000e18,
            0,
            recipient
        );
        assertEq(recipient.balance - balBefore, ethReceived);
    }

    function test_swapTokenForETH_pullsTokenFromCaller() public {
        token.transfer(vault, 1000e18);
        vm.prank(vault);
        token.approve(address(router), 1000e18);

        uint256 balBefore = token.balanceOf(vault);
        vm.prank(vault);
        router.swapTokenForETH(address(token), 1000e18, 0, recipient);
        assertEq(balBefore - token.balanceOf(vault), 1000e18);
    }

    function test_swapTokenForETH_respectsMinOut() public {
        token.transfer(vault, 1000e18);
        vm.prank(vault);
        token.approve(address(router), 1000e18);

        vm.prank(vault);
        vm.expectRevert();
        router.swapTokenForETH(
            address(token),
            1000e18,
            type(uint256).max, // impossibly high minOut
            recipient
        );
    }
}
