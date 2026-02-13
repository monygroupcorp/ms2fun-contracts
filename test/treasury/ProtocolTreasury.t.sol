// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ProtocolTreasuryV1} from "../../src/treasury/ProtocolTreasuryV1.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

/// @notice Minimal ERC721 mock for testing treasury NFT handling
contract MockERC721 {
    mapping(uint256 => address) public ownerOf;

    function mint(address to, uint256 tokenId) external {
        ownerOf[tokenId] = to;
    }

    function transferFrom(address from, address to, uint256 tokenId) external {
        require(ownerOf[tokenId] == from, "Not owner");
        ownerOf[tokenId] = to;
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata data) external {
        require(ownerOf[tokenId] == from, "Not owner");
        ownerOf[tokenId] = to;
        // Call onERC721Received if recipient is a contract
        if (to.code.length > 0) {
            (bool success, bytes memory ret) = to.call(
                abi.encodeWithSignature("onERC721Received(address,address,uint256,bytes)", msg.sender, from, tokenId, data)
            );
            require(success && abi.decode(ret, (bytes4)) == bytes4(0x150b7a02), "Not receiver");
        }
    }
}

/// @notice Minimal ERC20 mock
contract MockERC20 {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract ProtocolTreasuryTest is Test {
    ProtocolTreasuryV1 public implementation;
    ProtocolTreasuryV1 public treasury;
    MockERC721 public nft;
    MockERC20 public token;

    address public owner = address(0x1);
    address public alice = address(0x2);
    address public bob = address(0x3);

    function setUp() public {
        implementation = new ProtocolTreasuryV1();
        bytes memory initData = abi.encodeWithSelector(ProtocolTreasuryV1.initialize.selector, owner);
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        treasury = ProtocolTreasuryV1(payable(address(proxy)));

        nft = new MockERC721();
        token = new MockERC20();

        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    // ========== Initialization ==========

    function test_initialize() public view {
        assertEq(treasury.owner(), owner);
    }

    function test_initialize_revertDouble() public {
        vm.expectRevert("Already initialized");
        treasury.initialize(address(0x999));
    }

    // ========== Revenue Intake ==========

    function test_deposit_bondingFee() public {
        vm.prank(alice);
        treasury.deposit{value: 1 ether}(ProtocolTreasuryV1.Source.BONDING_FEE);

        assertEq(treasury.getBalance(), 1 ether);
        (uint256 received,) = treasury.getRevenueBySource(ProtocolTreasuryV1.Source.BONDING_FEE);
        assertEq(received, 1 ether);
    }

    function test_deposit_multipleSourcesTrackedSeparately() public {
        vm.prank(alice);
        treasury.deposit{value: 1 ether}(ProtocolTreasuryV1.Source.BONDING_FEE);
        vm.prank(bob);
        treasury.deposit{value: 2 ether}(ProtocolTreasuryV1.Source.CREATION_FEE);
        vm.prank(alice);
        treasury.deposit{value: 0.5 ether}(ProtocolTreasuryV1.Source.QUEUE_REVENUE);

        (uint256 bonding,) = treasury.getRevenueBySource(ProtocolTreasuryV1.Source.BONDING_FEE);
        (uint256 creation,) = treasury.getRevenueBySource(ProtocolTreasuryV1.Source.CREATION_FEE);
        (uint256 queue,) = treasury.getRevenueBySource(ProtocolTreasuryV1.Source.QUEUE_REVENUE);

        assertEq(bonding, 1 ether);
        assertEq(creation, 2 ether);
        assertEq(queue, 0.5 ether);
        assertEq(treasury.getBalance(), 3.5 ether);
    }

    function test_deposit_revertZeroValue() public {
        vm.prank(alice);
        vm.expectRevert("No value");
        treasury.deposit{value: 0}(ProtocolTreasuryV1.Source.BONDING_FEE);
    }

    function test_receive_taggedAsOther() public {
        vm.prank(alice);
        (bool success,) = address(treasury).call{value: 1 ether}("");
        assertTrue(success);

        (uint256 other,) = treasury.getRevenueBySource(ProtocolTreasuryV1.Source.OTHER);
        assertEq(other, 1 ether);
    }

    // ========== ETH Withdrawal ==========

    function test_withdrawETH() public {
        vm.prank(alice);
        treasury.deposit{value: 5 ether}(ProtocolTreasuryV1.Source.BONDING_FEE);

        vm.prank(owner);
        treasury.withdrawETH(bob, 3 ether);

        assertEq(bob.balance, 13 ether);
        assertEq(treasury.getBalance(), 2 ether);
    }

    function test_withdrawETH_revertNonOwner() public {
        vm.prank(alice);
        treasury.deposit{value: 1 ether}(ProtocolTreasuryV1.Source.BONDING_FEE);

        vm.prank(alice);
        vm.expectRevert();
        treasury.withdrawETH(alice, 1 ether);
    }

    function test_withdrawETH_revertInsufficientBalance() public {
        vm.prank(owner);
        vm.expectRevert("Insufficient balance");
        treasury.withdrawETH(bob, 1 ether);
    }

    function test_withdrawETH_revertZeroAddress() public {
        vm.prank(alice);
        treasury.deposit{value: 1 ether}(ProtocolTreasuryV1.Source.BONDING_FEE);

        vm.prank(owner);
        vm.expectRevert("Invalid recipient");
        treasury.withdrawETH(address(0), 1 ether);
    }

    // ========== ERC721 ==========

    function test_receiveERC721() public {
        nft.mint(alice, 1);

        vm.prank(alice);
        nft.safeTransferFrom(alice, address(treasury), 1, "");

        assertEq(nft.ownerOf(1), address(treasury));
    }

    function test_withdrawERC721() public {
        nft.mint(address(treasury), 42);

        vm.prank(owner);
        treasury.withdrawERC721(address(nft), bob, 42);

        assertEq(nft.ownerOf(42), bob);
    }

    function test_withdrawERC721_revertNonOwner() public {
        nft.mint(address(treasury), 1);

        vm.prank(alice);
        vm.expectRevert();
        treasury.withdrawERC721(address(nft), alice, 1);
    }

    // ========== ERC20 ==========

    function test_withdrawERC20() public {
        token.mint(address(treasury), 1000);

        vm.prank(owner);
        treasury.withdrawERC20(address(token), bob, 500);

        assertEq(token.balanceOf(bob), 500);
        assertEq(token.balanceOf(address(treasury)), 500);
    }

    function test_withdrawERC20_revertNonOwner() public {
        token.mint(address(treasury), 1000);

        vm.prank(alice);
        vm.expectRevert();
        treasury.withdrawERC20(address(token), alice, 1000);
    }

    // ========== V4 Configuration ==========

    function test_setV4PoolManager() public {
        vm.prank(owner);
        treasury.setV4PoolManager(address(0x999));
        assertEq(treasury.v4PoolManager(), address(0x999));
    }

    function test_setV4PoolManager_RevertNonOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        treasury.setV4PoolManager(address(0x999));
    }

    function test_setV4PoolManager_RevertZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert("Invalid pool manager");
        treasury.setV4PoolManager(address(0));
    }

    function test_setWETH() public {
        vm.prank(owner);
        treasury.setWETH(address(0x888));
        assertEq(treasury.weth(), address(0x888));
    }

    function test_setWETH_RevertNonOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        treasury.setWETH(address(0x888));
    }

    function test_setWETH_RevertZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert("Invalid WETH");
        treasury.setWETH(address(0));
    }

    // ========== POL Revert Tests ==========

    function test_receivePOL_RevertV4NotConfigured() public {
        // WETH set but V4 not configured
        vm.prank(owner);
        treasury.setWETH(address(0x888));

        PoolKey memory key = _dummyPoolKey();
        vm.prank(alice);
        vm.expectRevert("V4 not configured");
        treasury.receivePOL(key, -887220, 887220, 1 ether, 1 ether);
    }

    function test_receivePOL_RevertWETHNotConfigured() public {
        // V4 set but WETH not configured
        vm.prank(owner);
        treasury.setV4PoolManager(address(0x999));

        PoolKey memory key = _dummyPoolKey();
        vm.prank(alice);
        vm.expectRevert("WETH not configured");
        treasury.receivePOL(key, -887220, 887220, 1 ether, 1 ether);
    }

    function test_claimPOLFees_RevertNoPosition() public {
        vm.prank(alice);
        vm.expectRevert("No POL position");
        treasury.claimPOLFees(address(0xDEAD));
    }

    // ========== POL Views ==========

    function test_polInstanceCount_InitiallyZero() public {
        assertEq(treasury.polInstanceCount(), 0);
    }

    function test_getPolPosition_EmptyForUnknown() public {
        (int24 tickLower, int24 tickUpper, bytes32 salt, uint128 liquidity) = treasury.getPolPosition(address(0xDEAD));
        assertEq(tickLower, 0);
        assertEq(tickUpper, 0);
        assertEq(salt, bytes32(0));
        assertEq(liquidity, 0);
    }

    // ========== POL Revenue Source ==========

    function test_polFees_SourceTracking() public {
        // Verify POL_FEES source enum works
        (uint256 received, uint256 withdrawn) = treasury.getRevenueBySource(ProtocolTreasuryV1.Source.POL_FEES);
        assertEq(received, 0);
        assertEq(withdrawn, 0);
    }

    // Note: Full receivePOL integration tests require V4 PoolManager (fork tests)
    // Unit tests verify config, reverts, and view functions

    // ========== Helpers ==========

    function _dummyPoolKey() internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0xAAA)),
            currency1: Currency.wrap(address(0xBBB)),
            fee: 3000,
            tickSpacing: int24(60),
            hooks: IHooks(address(0))
        });
    }
}
