// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PasswordTierGatingModule} from "../../src/gating/PasswordTierGatingModule.sol";

contract PasswordTierGatingModuleTest is Test {
    PasswordTierGatingModule module;
    address instance1 = address(0xAAAA);
    address instance2 = address(0xBBBB);
    address user1 = address(0x1111);

    function setUp() public {
        module = new PasswordTierGatingModule();
    }

    function _volumeCapConfig() internal pure returns (PasswordTierGatingModule.TierConfig memory) {
        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = keccak256("tier1password");
        hashes[1] = keccak256("tier2password");
        uint256[] memory caps = new uint256[](2);
        caps[0] = 100e18;
        caps[1] = 500e18;
        return PasswordTierGatingModule.TierConfig({
            tierType: PasswordTierGatingModule.TierType.VOLUME_CAP,
            passwordHashes: hashes,
            volumeCaps: caps,
            tierUnlockTimes: new uint256[](0)
        });
    }

    // --- configureFor ---

    function test_configureFor_setsConfig() public {
        vm.prank(address(this)); // simulates factory calling on behalf of instance1
        module.configureFor(instance1, _volumeCapConfig());
        assertTrue(module.configured(instance1));
    }

    function test_configureFor_revertsIfAlreadyConfigured() public {
        module.configureFor(instance1, _volumeCapConfig());
        vm.expectRevert(PasswordTierGatingModule.AlreadyConfigured.selector);
        module.configureFor(instance1, _volumeCapConfig());
    }

    function test_configureFor_isolatedPerInstance() public {
        module.configureFor(instance1, _volumeCapConfig());
        assertFalse(module.configured(instance2));
    }

    // --- canMint / onMint (VOLUME_CAP) ---

    function test_canMint_openTier_noPassword() public {
        module.configureFor(instance1, _volumeCapConfig());
        vm.prank(instance1);
        // open tier (no password) = unlimited
        assertTrue(module.canMint(user1, 1e18, abi.encode(bytes32(0))));
    }

    function test_canMint_correctPassword_withinCap() public {
        module.configureFor(instance1, _volumeCapConfig());
        vm.prank(instance1);
        assertTrue(module.canMint(user1, 50e18, abi.encode(keccak256("tier1password"))));
    }

    function test_canMint_wrongPassword_reverts() public {
        module.configureFor(instance1, _volumeCapConfig());
        vm.prank(instance1);
        vm.expectRevert(PasswordTierGatingModule.InvalidPassword.selector);
        module.canMint(user1, 1e18, abi.encode(keccak256("wrongpassword")));
    }

    function test_onMint_tracksVolume() public {
        module.configureFor(instance1, _volumeCapConfig());
        vm.startPrank(instance1);
        module.canMint(user1, 50e18, abi.encode(keccak256("tier1password")));
        module.onMint(user1, 50e18);
        // second buy: 50+60=110 > cap of 100 → should revert
        vm.expectRevert(PasswordTierGatingModule.VolumeCapExceeded.selector);
        module.canMint(user1, 60e18, abi.encode(keccak256("tier1password")));
        vm.stopPrank();
    }

    function test_volumeState_isolatedPerInstance() public {
        module.configureFor(instance1, _volumeCapConfig());
        module.configureFor(instance2, _volumeCapConfig());
        vm.prank(instance1);
        module.onMint(user1, 90e18);
        // instance2's user1 should be unaffected
        vm.prank(instance2);
        assertTrue(module.canMint(user1, 90e18, abi.encode(keccak256("tier1password"))));
    }
}
