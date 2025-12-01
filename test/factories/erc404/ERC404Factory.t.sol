// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {ERC404Factory} from "../../../src/factories/erc404/ERC404Factory.sol";

contract ERC404FactoryTest is Test {
    ERC404Factory public factory;
    address public masterRegistry;
    address public instanceTemplate;
    address public hookFactory;

    function setUp() public {
        masterRegistry = address(0x123);
        instanceTemplate = address(0x456);
        hookFactory = address(0x789);
        factory = new ERC404Factory(
            masterRegistry,
            instanceTemplate,
            hookFactory,
            address(0x1111111111111111111111111111111111111111),  // v4PoolManager
            address(0x2222222222222222222222222222222222222222)   // weth
        );
    }

    function test_FactoryCreation() public {
        assertEq(address(factory.masterRegistry()), masterRegistry);
        assertEq(address(factory.instanceTemplate()), instanceTemplate);
    }
}

