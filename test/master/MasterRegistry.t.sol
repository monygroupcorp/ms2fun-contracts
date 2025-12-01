// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {MasterRegistryV1} from "../../src/master/MasterRegistryV1.sol";
import {MasterRegistry} from "../../src/master/MasterRegistry.sol";

contract MasterRegistryTest is Test {
    MasterRegistryV1 public implementation;
    MasterRegistry public proxy;
    address public execToken;
    address public owner;

    function setUp() public {
        owner = address(this);
        execToken = address(0x123); // Mock EXEC token

        // Deploy implementation
        implementation = new MasterRegistryV1();

        // Deploy proxy with exec token for governance
        bytes memory initData = abi.encodeWithSelector(
            MasterRegistryV1.initialize.selector,
            execToken,
            owner
        );
        proxy = new MasterRegistry(address(implementation), initData);
    }

    function test_Initialization() public {
        // Test initialization
        assertEq(MasterRegistryV1(address(proxy)).owner(), owner);
    }

    function test_ApplyForFactory() public {
        // Test factory application
        address factory = address(0x456);
        bytes32[] memory features = new bytes32[](0);
        
        vm.deal(address(this), 0.1 ether);
        MasterRegistryV1(address(proxy)).applyForFactory{value: 0.1 ether}(
            factory,
            "ERC404",
            "Test Factory",
            "Test Factory Display",
            "https://example.com/metadata",
            features
        );
    }
}

