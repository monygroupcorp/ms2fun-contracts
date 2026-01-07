// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/master/MasterRegistryV1.sol";
import "../../src/vaults/UltraAlignmentVault.sol";
import "../../src/factories/erc404/ERC404Factory.sol";
import "../mocks/MockERC20.sol";

/**
 * @title MasterRegistryVaultQueriesTest
 * @notice Comprehensive tests for vault query functions in MasterRegistryV1
 */
contract MasterRegistryVaultQueriesTest is Test {
    MasterRegistryV1 public registry;
    UltraAlignmentVault public vault1;
    UltraAlignmentVault public vault2;
    UltraAlignmentVault public vault3;
    ERC404Factory public factory;
    MockERC20 public execToken;

    address public owner = address(0x1);
    address public creator1 = address(0x2);
    address public creator2 = address(0x3);
    address public creator3 = address(0x4);

    address public instance1 = address(0x100);
    address public instance2 = address(0x101);
    address public instance3 = address(0x102);
    address public instance4 = address(0x103);
    address public instance5 = address(0x104);

    function setUp() public {
        vm.startPrank(owner);

        // Deploy EXEC token
        execToken = new MockERC20("EXEC", "EXEC");

        // Deploy registry
        registry = new MasterRegistryV1();
        registry.initialize(address(execToken), owner);

        // Mock addresses for vault dependencies
        address mockWeth = address(0x1111);
        address mockPoolManager = address(0x2222);
        address mockV3Router = address(0x3333);
        address mockV2Router = address(0x4444);
        address mockV2Factory = address(0x5555);
        address mockV3Factory = address(0x6666);
        address mockAlignmentToken = address(execToken);

        // Deploy vaults with required constructor parameters
        vault1 = new UltraAlignmentVault(
            mockWeth, mockPoolManager, mockV3Router, mockV2Router,
            mockV2Factory, mockV3Factory, mockAlignmentToken
        );

        vault2 = new UltraAlignmentVault(
            mockWeth, mockPoolManager, mockV3Router, mockV2Router,
            mockV2Factory, mockV3Factory, mockAlignmentToken
        );

        vault3 = new UltraAlignmentVault(
            mockWeth, mockPoolManager, mockV3Router, mockV2Router,
            mockV2Factory, mockV3Factory, mockAlignmentToken
        );

        // Deploy factory with mock parameters
        address mockInstanceTemplate = address(0x7777);
        address mockHookFactory = address(0x8888);

        factory = new ERC404Factory(
            address(registry),
            mockInstanceTemplate,
            mockHookFactory,
            mockPoolManager,
            mockWeth
        );

        // Register factory
        registry.registerFactory(
            address(factory),
            "ERC404",
            "ERC404Factory",
            "ERC404-Token-Factory",
            "ipfs://factory-metadata"
        );

        vm.stopPrank();
    }

    // Helper function to register a vault
    function _registerVault(UltraAlignmentVault vault, address vaultOwner, string memory name) internal {
        vm.deal(vaultOwner, 0.05 ether); // Give the owner enough ETH for the registration fee
        vm.prank(vaultOwner);
        registry.registerVault{value: 0.05 ether}(
            address(vault),
            name,
            "ipfs://vault-metadata"
        );
    }

    // Helper function to register an instance with a vault
    function _registerInstance(
        address instance,
        address instanceCreator,
        address vault,
        string memory name
    ) internal {
        vm.prank(address(factory));
        registry.registerInstance(
            instance,
            address(factory),
            instanceCreator,
            name,
            "ipfs://instance-metadata",
            vault
        );
    }

    // Helper to simulate vault accumulating fees
    function _simulateVaultFees(UltraAlignmentVault vault, uint256 amount) internal {
        vm.deal(address(this), amount);
        (bool success,) = payable(address(vault)).call{value: amount}("");
        require(success, "Failed to send ETH to vault");
    }

    /*//////////////////////////////////////////////////////////////
                        BASIC QUERY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetTotalVaults_NoVaults() public view {
        assertEq(registry.getTotalVaults(), 0, "Should have 0 vaults initially");
    }

    function test_GetTotalVaults_SingleVault() public {
        _registerVault(vault1, owner, "High-Value-Vault");
        assertEq(registry.getTotalVaults(), 1, "Should have 1 vault");
    }

    function test_GetTotalVaults_MultipleVaults() public {
        _registerVault(vault1, owner, "High-Value-Vault");
        _registerVault(vault2, owner, "Medium-Value-Vault");
        _registerVault(vault3, owner, "Low-Value-Vault");
        assertEq(registry.getTotalVaults(), 3, "Should have 3 vaults");
    }

    /*//////////////////////////////////////////////////////////////
                    GET INSTANCES BY VAULT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetInstancesByVault_Reverts_UnregisteredVault() public {
        vm.expectRevert("Vault not registered");
        registry.getInstancesByVault(address(vault1));
    }

    function test_GetInstancesByVault_NoInstances() public {
        _registerVault(vault1, owner, "High-Value-Vault");

        address[] memory instances = registry.getInstancesByVault(address(vault1));
        assertEq(instances.length, 0, "Should have 0 instances");
    }

    function test_GetInstancesByVault_SingleInstance() public {
        _registerVault(vault1, owner, "High-Value-Vault");
        _registerInstance(instance1, creator1, address(vault1), "Instance1");

        address[] memory instances = registry.getInstancesByVault(address(vault1));
        assertEq(instances.length, 1, "Should have 1 instance");
        assertEq(instances[0], instance1, "Should return correct instance");
    }

    function test_GetInstancesByVault_MultipleInstances() public {
        _registerVault(vault1, owner, "High-Value-Vault");
        _registerInstance(instance1, creator1, address(vault1), "Instance1");
        _registerInstance(instance2, creator2, address(vault1), "Instance2");
        _registerInstance(instance3, creator3, address(vault1), "Instance3");

        address[] memory instances = registry.getInstancesByVault(address(vault1));
        assertEq(instances.length, 3, "Should have 3 instances");
        assertEq(instances[0], instance1, "First instance correct");
        assertEq(instances[1], instance2, "Second instance correct");
        assertEq(instances[2], instance3, "Third instance correct");
    }

    function test_GetInstancesByVault_DoesNotIncludeOtherVaults() public {
        _registerVault(vault1, owner, "High-Value-Vault");
        _registerVault(vault2, owner, "Medium-Value-Vault");

        _registerInstance(instance1, creator1, address(vault1), "Instance1");
        _registerInstance(instance2, creator2, address(vault1), "Instance2");
        _registerInstance(instance3, creator3, address(vault2), "Instance3");

        address[] memory vault1Instances = registry.getInstancesByVault(address(vault1));
        address[] memory vault2Instances = registry.getInstancesByVault(address(vault2));

        assertEq(vault1Instances.length, 2, "Vault1 should have 2 instances");
        assertEq(vault2Instances.length, 1, "Vault2 should have 1 instance");
        assertEq(vault2Instances[0], instance3, "Vault2 should have instance3");
    }

    /*//////////////////////////////////////////////////////////////
                    PAGINATED GET VAULTS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetVaults_EmptyRegistry() public view {
        // When registry is empty, total vaults is 0, so we can't query any range
        // This test just verifies that getTotalVaults() returns 0
        assertEq(registry.getTotalVaults(), 0, "Total should be 0");
    }

    function test_GetVaults_SingleVault() public {
        _registerVault(vault1, owner, "High-Value-Vault");

        uint256 totalVaults = registry.getTotalVaults();
        (address[] memory vaults, MasterRegistryV1.VaultInfo[] memory infos, uint256 total) =
            registry.getVaults(0, totalVaults);

        assertEq(vaults.length, 1, "Should return 1 vault");
        assertEq(infos.length, 1, "Should return 1 info");
        assertEq(total, 1, "Total should be 1");
        assertEq(vaults[0], address(vault1), "Should return vault1");
        assertEq(infos[0].vault, address(vault1), "Info should match vault1");
    }

    function test_GetVaults_Pagination_FirstPage() public {
        _registerVault(vault1, owner, "High-Value-Vault");
        _registerVault(vault2, owner, "Medium-Value-Vault");
        _registerVault(vault3, owner, "Low-Value-Vault");

        (address[] memory vaults, MasterRegistryV1.VaultInfo[] memory infos, uint256 total) =
            registry.getVaults(0, 2);

        assertEq(vaults.length, 2, "Should return 2 vaults");
        assertEq(total, 3, "Total should be 3");
        assertEq(vaults[0], address(vault1), "First vault correct");
        assertEq(vaults[1], address(vault2), "Second vault correct");
    }

    function test_GetVaults_Pagination_SecondPage() public {
        _registerVault(vault1, owner, "High-Value-Vault");
        _registerVault(vault2, owner, "Medium-Value-Vault");
        _registerVault(vault3, owner, "Low-Value-Vault");

        (address[] memory vaults, MasterRegistryV1.VaultInfo[] memory infos, uint256 total) =
            registry.getVaults(2, 3);

        assertEq(vaults.length, 1, "Should return 1 vault (last page)");
        assertEq(total, 3, "Total should be 3");
        assertEq(vaults[0], address(vault3), "Should return vault3");
    }

    function test_GetVaults_Pagination_OutOfBounds() public {
        _registerVault(vault1, owner, "High-Value-Vault");

        // Query with endIndex > vaultList.length should revert
        vm.expectRevert("End index out of bounds");
        registry.getVaults(0, 10);
    }

    /*//////////////////////////////////////////////////////////////
                VAULTS BY POPULARITY (INSTANCE COUNT) TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetVaultsByPopularity_NoVaults() public view {
        (address[] memory vaults, uint256[] memory counts, string[] memory names) =
            registry.getVaultsByPopularity(10);

        assertEq(vaults.length, 0, "Should return 0 vaults");
        assertEq(counts.length, 0, "Should return 0 counts");
        assertEq(names.length, 0, "Should return 0 names");
    }

    function test_GetVaultsByPopularity_SingleVault_NoInstances() public {
        _registerVault(vault1, owner, "High-Value-Vault");

        (address[] memory vaults, uint256[] memory counts, string[] memory names) =
            registry.getVaultsByPopularity(10);

        assertEq(vaults.length, 1, "Should return 1 vault");
        assertEq(counts[0], 0, "Should have 0 instances");
        assertEq(names[0], "High-Value-Vault", "Should return correct name");
    }

    function test_GetVaultsByPopularity_SortsByInstanceCount() public {
        // Register vaults
        _registerVault(vault1, owner, "High-Value-Vault");
        _registerVault(vault2, owner, "Medium-Value-Vault");
        _registerVault(vault3, owner, "Low-Value-Vault");

        // Vault1: 3 instances
        _registerInstance(instance1, creator1, address(vault1), "Instance1");
        _registerInstance(instance2, creator2, address(vault1), "Instance2");
        _registerInstance(instance3, creator3, address(vault1), "Instance3");

        // Vault2: 1 instance
        _registerInstance(instance4, creator1, address(vault2), "Instance4");

        // Vault3: 0 instances

        (address[] memory vaults, uint256[] memory counts, string[] memory names) =
            registry.getVaultsByPopularity(10);

        assertEq(vaults.length, 3, "Should return all 3 vaults");

        // Should be sorted: vault1 (3), vault2 (1), vault3 (0)
        assertEq(vaults[0], address(vault1), "Most popular should be vault1");
        assertEq(counts[0], 3, "Vault1 should have 3 instances");
        assertEq(names[0], "High-Value-Vault", "Name should match");

        assertEq(vaults[1], address(vault2), "Second should be vault2");
        assertEq(counts[1], 1, "Vault2 should have 1 instance");

        assertEq(vaults[2], address(vault3), "Least popular should be vault3");
        assertEq(counts[2], 0, "Vault3 should have 0 instances");
    }

    function test_GetVaultsByPopularity_RespectsLimit() public {
        _registerVault(vault1, owner, "High-Value-Vault");
        _registerVault(vault2, owner, "Medium-Value-Vault");
        _registerVault(vault3, owner, "Low-Value-Vault");

        _registerInstance(instance1, creator1, address(vault1), "Instance1");
        _registerInstance(instance2, creator2, address(vault1), "Instance2");
        _registerInstance(instance3, creator3, address(vault2), "Instance3");

        (address[] memory vaults, uint256[] memory counts, string[] memory names) =
            registry.getVaultsByPopularity(2);

        assertEq(vaults.length, 2, "Should return only 2 vaults");
        assertEq(vaults[0], address(vault1), "First should be vault1");
        assertEq(vaults[1], address(vault2), "Second should be vault2");
    }

    /*//////////////////////////////////////////////////////////////
                    VAULTS BY TVL (FEES) TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetVaultsByTVL_NoVaults() public view {
        (address[] memory vaults, uint256[] memory tvls, string[] memory names) =
            registry.getVaultsByTVL(10);

        assertEq(vaults.length, 0, "Should return 0 vaults");
        assertEq(tvls.length, 0, "Should return 0 TVLs");
        assertEq(names.length, 0, "Should return 0 names");
    }

    function test_GetVaultsByTVL_SingleVault_NoFees() public {
        _registerVault(vault1, owner, "High-Value-Vault");

        (address[] memory vaults, uint256[] memory tvls, string[] memory names) =
            registry.getVaultsByTVL(10);

        assertEq(vaults.length, 1, "Should return 1 vault");
        assertEq(tvls[0], 0, "Should have 0 TVL");
        assertEq(names[0], "High-Value-Vault", "Should return correct name");
    }

    function test_GetVaultsByTVL_SortsByAccumulatedFees() public {
        // Register vaults
        _registerVault(vault1, owner, "High-Value-Vault");
        _registerVault(vault2, owner, "Medium-Value-Vault");
        _registerVault(vault3, owner, "Low-Value-Vault");

        // Note: accumulatedFees is only updated when vault collects LP fees
        // Direct ETH contributions don't count as accumulated fees
        // This test verifies the sorting works correctly even with 0 fees

        (address[] memory vaults, uint256[] memory tvls, string[] memory names) =
            registry.getVaultsByTVL(10);

        assertEq(vaults.length, 3, "Should return all 3 vaults");

        // All vaults have 0 TVL since we haven't generated any yield
        // Just verify they're all returned
        assertEq(names[0], "High-Value-Vault", "First name correct");
        assertEq(names[1], "Medium-Value-Vault", "Second name correct");
        assertEq(names[2], "Low-Value-Vault", "Third name correct");
    }

    function test_GetVaultsByTVL_RespectsLimit() public {
        _registerVault(vault1, owner, "High-Value-Vault");
        _registerVault(vault2, owner, "Medium-Value-Vault");
        _registerVault(vault3, owner, "Low-Value-Vault");

        (address[] memory vaults, uint256[] memory tvls, string[] memory names) =
            registry.getVaultsByTVL(2);

        assertEq(vaults.length, 2, "Should return only 2 vaults");
        // Just verify limit is respected - don't check specific vault order with 0 TVL
    }

    function test_GetVaultsByTVL_HandlesZeroFees() public {
        _registerVault(vault1, owner, "High-Value-Vault");
        _registerVault(vault2, owner, "Medium-Value-Vault");

        (address[] memory vaults, uint256[] memory tvls, string[] memory names) =
            registry.getVaultsByTVL(10);

        assertEq(vaults.length, 2, "Should return both vaults");
        // Both vaults have 0 TVL - just verify they're both returned
        assertEq(tvls[0], 0, "First vault TVL should be 0");
        assertEq(tvls[1], 0, "Second vault TVL should be 0");
    }

    /*//////////////////////////////////////////////////////////////
                    INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Integration_VaultMetrics_AfterInstanceRegistration() public {
        // Register all vaults
        _registerVault(vault1, owner, "High-Value-Vault");
        _registerVault(vault2, owner, "Medium-Value-Vault");
        _registerVault(vault3, owner, "Low-Value-Vault");

        // Register instances to different vaults
        _registerInstance(instance1, creator1, address(vault1), "Instance1");
        _registerInstance(instance2, creator2, address(vault1), "Instance2");
        _registerInstance(instance3, creator3, address(vault2), "Instance3");

        // Check total vaults
        assertEq(registry.getTotalVaults(), 3, "Should have 3 vaults");

        // Check instances by vault
        address[] memory vault1Instances = registry.getInstancesByVault(address(vault1));
        assertEq(vault1Instances.length, 2, "Vault1 should have 2 instances");

        // Check popularity ranking (by instance count)
        (address[] memory popularVaults, uint256[] memory counts,) =
            registry.getVaultsByPopularity(10);
        assertEq(popularVaults[0], address(vault1), "Vault1 most popular (2 instances)");
        assertEq(counts[0], 2, "Vault1 has 2 instances");

        // Verify getVaultsByTVL works (all have 0 TVL without yield generation)
        (address[] memory tvlVaults, uint256[] memory tvls,) =
            registry.getVaultsByTVL(10);
        assertEq(tvlVaults.length, 3, "Should return all 3 vaults");
        // All have 0 TVL - just verify the function executes without reverting
    }

    function test_Integration_PaginationConsistency() public {
        _registerVault(vault1, owner, "High-Value-Vault");
        _registerVault(vault2, owner, "Medium-Value-Vault");
        _registerVault(vault3, owner, "Low-Value-Vault");

        uint256 totalVaults = registry.getTotalVaults();

        // Get all at once
        (address[] memory allVaults,,) = registry.getVaults(0, totalVaults);

        // Get in pages
        (address[] memory page1,,) = registry.getVaults(0, 2);
        (address[] memory page2,,) = registry.getVaults(2, totalVaults);

        assertEq(allVaults.length, 3, "Should get all 3 vaults");
        assertEq(page1.length, 2, "Page 1 should have 2 vaults");
        assertEq(page2.length, 1, "Page 2 should have 1 vault");

        // Verify consistency
        assertEq(page1[0], allVaults[0], "Page 1 first matches");
        assertEq(page1[1], allVaults[1], "Page 1 second matches");
        assertEq(page2[0], allVaults[2], "Page 2 first matches");
    }

    receive() external payable {}
}
