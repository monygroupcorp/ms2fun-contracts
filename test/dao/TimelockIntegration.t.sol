// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Timelock} from "solady/accounts/Timelock.sol";
import {ERC7821} from "solady/accounts/ERC7821.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {MasterRegistryV1} from "../../src/master/MasterRegistryV1.sol";
import {MasterRegistry} from "../../src/master/MasterRegistry.sol";
import {TestHelpers} from "../helpers/TestHelpers.sol";

/// @dev Minimal V2 mock for testing UUPS upgrades through the timelock.
contract MasterRegistryV2Mock is MasterRegistryV1 {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract TimelockIntegrationTest is Test {
    Timelock public timelock;
    MasterRegistryV1 public registry;
    address public registryProxy;

    address public safe = makeAddr("safe");
    address public alice = makeAddr("alice");

    uint256 constant MIN_DELAY = 48 hours;
    bytes32 constant MODE = 0x0100000000007821000100000000000000000000000000000000000000000000;

    function setUp() public {
        // Deploy timelock
        timelock = new Timelock();

        address[] memory proposers = new address[](1);
        proposers[0] = safe;

        address[] memory executors = new address[](1);
        executors[0] = timelock.OPEN_ROLE_HOLDER();

        address[] memory cancellers = new address[](1);
        cancellers[0] = safe;

        timelock.initialize(MIN_DELAY, safe, proposers, executors, cancellers);

        // Deploy MasterRegistryV1 behind proxy, owned by timelock
        MasterRegistryV1 impl = new MasterRegistryV1();
        bytes memory initData = abi.encodeWithSignature("initialize(address)", address(timelock));
        MasterRegistry wrapper = new MasterRegistry(address(impl), initData);
        registryProxy = TestHelpers.getProxyAddress(wrapper);
        registry = MasterRegistryV1(registryProxy);

        assertEq(registry.owner(), address(timelock));
    }

    // ========== Helpers ==========

    function _buildExecutionData(ERC7821.Call[] memory calls, bytes32 salt)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(calls, abi.encode(bytes32(0), salt));
    }

    function _propose(bytes memory executionData, uint256 delay)
        internal
        returns (bytes32 id)
    {
        vm.prank(safe);
        id = timelock.propose(MODE, executionData, delay);
    }

    // ========== Test: Propose + Execute Upgrade ==========

    function test_ProposeAndExecuteUpgrade() public {
        MasterRegistryV2Mock newImpl = new MasterRegistryV2Mock();

        ERC7821.Call[] memory calls = new ERC7821.Call[](1);
        calls[0] = ERC7821.Call({
            to: registryProxy,
            value: 0,
            data: abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(newImpl), "")
        });

        bytes memory executionData = _buildExecutionData(calls, bytes32(uint256(1)));
        bytes32 id = _propose(executionData, MIN_DELAY);

        assertEq(uint256(timelock.operationState(id)), uint256(Timelock.OperationState.Waiting));

        vm.warp(block.timestamp + MIN_DELAY);

        assertEq(uint256(timelock.operationState(id)), uint256(Timelock.OperationState.Ready));

        timelock.execute(MODE, executionData);

        assertEq(uint256(timelock.operationState(id)), uint256(Timelock.OperationState.Done));
        assertEq(MasterRegistryV2Mock(registryProxy).version(), 2);
    }

    // ========== Test: Propose + Execute Owner Function ==========

    function test_ProposeAndExecuteOwnerFunction() public {
        ERC7821.Call[] memory calls = new ERC7821.Call[](1);
        calls[0] = ERC7821.Call({
            to: registryProxy,
            value: 0,
            data: abi.encodeWithSelector(Ownable.transferOwnership.selector, alice)
        });

        bytes memory executionData = _buildExecutionData(calls, bytes32(uint256(2)));
        bytes32 id = _propose(executionData, MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);
        timelock.execute(MODE, executionData);

        assertEq(uint256(timelock.operationState(id)), uint256(Timelock.OperationState.Done));
        assertEq(registry.owner(), alice);
    }

    // ========== Test: Early Execution Reverts ==========

    function test_EarlyExecutionReverts() public {
        MasterRegistryV2Mock newImpl = new MasterRegistryV2Mock();

        ERC7821.Call[] memory calls = new ERC7821.Call[](1);
        calls[0] = ERC7821.Call({
            to: registryProxy,
            value: 0,
            data: abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(newImpl), "")
        });

        bytes memory executionData = _buildExecutionData(calls, bytes32(uint256(3)));
        _propose(executionData, MIN_DELAY);

        // Try to execute before delay — should revert
        vm.expectRevert();
        timelock.execute(MODE, executionData);
    }

    // ========== Test: Cancel During Delay ==========

    function test_CancelDuringDelay() public {
        MasterRegistryV2Mock newImpl = new MasterRegistryV2Mock();

        ERC7821.Call[] memory calls = new ERC7821.Call[](1);
        calls[0] = ERC7821.Call({
            to: registryProxy,
            value: 0,
            data: abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(newImpl), "")
        });

        bytes memory executionData = _buildExecutionData(calls, bytes32(uint256(4)));
        bytes32 id = _propose(executionData, MIN_DELAY);

        // Safe cancels
        vm.prank(safe);
        timelock.cancel(id);

        assertEq(uint256(timelock.operationState(id)), uint256(Timelock.OperationState.Unset));

        // Execution should revert even after delay
        vm.warp(block.timestamp + MIN_DELAY);
        vm.expectRevert();
        timelock.execute(MODE, executionData);
    }

    // ========== Test: Unauthorized Propose Reverts ==========

    function test_UnauthorizedProposeReverts() public {
        ERC7821.Call[] memory calls = new ERC7821.Call[](1);
        calls[0] = ERC7821.Call({
            to: registryProxy,
            value: 0,
            data: abi.encodeWithSelector(Ownable.transferOwnership.selector, alice)
        });

        bytes memory executionData = _buildExecutionData(calls, bytes32(uint256(5)));

        // Alice is not a proposer
        vm.prank(alice);
        vm.expectRevert();
        timelock.propose(MODE, executionData, MIN_DELAY);
    }

    // ========== Test: Unauthorized Cancel Reverts ==========

    function test_UnauthorizedCancelReverts() public {
        ERC7821.Call[] memory calls = new ERC7821.Call[](1);
        calls[0] = ERC7821.Call({
            to: registryProxy,
            value: 0,
            data: abi.encodeWithSelector(Ownable.transferOwnership.selector, alice)
        });

        bytes memory executionData = _buildExecutionData(calls, bytes32(uint256(6)));
        bytes32 id = _propose(executionData, MIN_DELAY);

        // Alice is not a canceller
        vm.prank(alice);
        vm.expectRevert();
        timelock.cancel(id);
    }

    // ========== Test: Batch Operation ==========

    function test_BatchOperation() public {
        MasterRegistryV2Mock newImpl = new MasterRegistryV2Mock();

        // Batch: upgrade + transferOwnership in a single proposal
        ERC7821.Call[] memory calls = new ERC7821.Call[](2);
        calls[0] = ERC7821.Call({
            to: registryProxy,
            value: 0,
            data: abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(newImpl), "")
        });
        calls[1] = ERC7821.Call({
            to: registryProxy,
            value: 0,
            data: abi.encodeWithSelector(Ownable.transferOwnership.selector, alice)
        });

        bytes memory executionData = _buildExecutionData(calls, bytes32(uint256(7)));
        bytes32 id = _propose(executionData, MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);
        timelock.execute(MODE, executionData);

        assertEq(uint256(timelock.operationState(id)), uint256(Timelock.OperationState.Done));
        assertEq(MasterRegistryV2Mock(registryProxy).version(), 2);
        assertEq(registry.owner(), alice);
    }

    // ========== Test: Delay Below Minimum Reverts ==========

    function test_InsufficientDelayReverts() public {
        ERC7821.Call[] memory calls = new ERC7821.Call[](1);
        calls[0] = ERC7821.Call({
            to: registryProxy,
            value: 0,
            data: abi.encodeWithSelector(Ownable.transferOwnership.selector, alice)
        });

        bytes memory executionData = _buildExecutionData(calls, bytes32(uint256(8)));

        // Propose with delay less than minimum
        vm.prank(safe);
        vm.expectRevert();
        timelock.propose(MODE, executionData, MIN_DELAY - 1);
    }
}
