// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {FrontendRegistry} from "../../src/registry/FrontendRegistry.sol";
import {IFrontendRegistry} from "../../src/registry/interfaces/IFrontendRegistry.sol";
import {LibClone} from "solady/utils/LibClone.sol";

/// @dev Mock ENS resolver that records calls
contract MockENSResolver {
    mapping(bytes32 => bytes) public contentHashes;

    function setContenthash(bytes32 node, bytes calldata hash) external {
        contentHashes[node] = hash;
    }

    function contenthash(bytes32 node) external view returns (bytes memory) {
        return contentHashes[node];
    }
}

contract FrontendRegistryTest is Test {
    FrontendRegistry public impl;
    FrontendRegistry public registry;
    MockENSResolver public resolver;

    address public owner = address(0xDA0);
    bytes32 public node1 = keccak256("ms2fun.eth");
    bytes32 public node2 = keccak256("ms2fun.wei");

    function setUp() public {
        resolver = new MockENSResolver();

        // Deploy implementation
        impl = new FrontendRegistry();

        // Deploy proxy using LibClone (ERC1967 minimal proxy pattern used in this repo)
        address proxy = LibClone.deployERC1967(address(impl));
        registry = FrontendRegistry(proxy);

        // Initialize
        registry.initialize(owner, address(resolver));
    }

    // ── ENS Name Management ──

    function test_addEnsName_addsNode() public {
        vm.prank(owner);
        registry.addEnsName(node1);
        assertTrue(registry.isEnsNode(node1));
    }

    function test_addEnsName_emitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit IFrontendRegistry.EnsNameAdded(node1);
        vm.prank(owner);
        registry.addEnsName(node1);
    }

    function test_addEnsName_revertsOnDuplicate() public {
        vm.prank(owner);
        registry.addEnsName(node1);
        vm.prank(owner);
        vm.expectRevert(FrontendRegistry.AlreadyManaged.selector);
        registry.addEnsName(node1);
    }

    function test_addEnsName_revertsIfNotOwner() public {
        vm.expectRevert();
        registry.addEnsName(node1);
    }

    function test_removeEnsName_removesNode() public {
        vm.prank(owner);
        registry.addEnsName(node1);
        vm.prank(owner);
        registry.removeEnsName(node1);
        assertFalse(registry.isEnsNode(node1));
    }

    function test_removeEnsName_emitsEvent() public {
        vm.prank(owner);
        registry.addEnsName(node1);
        vm.expectEmit(true, false, false, false);
        emit IFrontendRegistry.EnsNameRemoved(node1);
        vm.prank(owner);
        registry.removeEnsName(node1);
    }

    function test_removeEnsName_revertsIfNotManaged() public {
        vm.prank(owner);
        vm.expectRevert(FrontendRegistry.NotManaged.selector);
        registry.removeEnsName(node1);
    }

    function test_removeEnsName_revertsIfNotOwner() public {
        vm.prank(owner);
        registry.addEnsName(node1);
        vm.expectRevert();
        registry.removeEnsName(node1);
    }

    // ── publishRelease ──

    bytes public sampleHash = hex"e3010170122029f2d17be6139079dc48696d1f582a8530eb9805b561eca672b58e61f63148";
    // ^ This is a real IPFS CIDv1 content hash encoding for testing

    function _addNodes() internal {
        vm.startPrank(owner);
        registry.addEnsName(node1);
        registry.addEnsName(node2);
        vm.stopPrank();
    }

    function test_publishRelease_siteOnly_createsRelease() public {
        _addNodes();
        bytes32[] memory nodes = new bytes32[](1);
        nodes[0] = node1;
        address[] memory contracts = new address[](0);

        vm.prank(owner);
        registry.publishRelease(
            IFrontendRegistry.ReleaseType.SITE_ONLY,
            sampleHash,
            "1.0.0",
            "Initial release",
            contracts,
            nodes
        );

        assertEq(registry.releaseCount(), 1);
        (uint32 id, IFrontendRegistry.ReleaseType rt, bytes memory ch, string memory ver, , ,) =
            registry.releases(0);
        assertEq(id, 1);
        assertEq(uint8(rt), uint8(IFrontendRegistry.ReleaseType.SITE_ONLY));
        assertEq(ch, sampleHash);
        assertEq(ver, "1.0.0");
    }

    function test_publishRelease_updatesNodePointer() public {
        _addNodes();
        bytes32[] memory nodes = new bytes32[](1);
        nodes[0] = node1;
        address[] memory contracts = new address[](0);

        vm.prank(owner);
        registry.publishRelease(IFrontendRegistry.ReleaseType.SITE_ONLY, sampleHash, "1.0.0", "notes", contracts, nodes);

        assertEq(registry.nodeRelease(node1), 1);
        assertEq(registry.nodeRelease(node2), 0); // node2 not in this release
    }

    function test_publishRelease_updatesEnsContentHash() public {
        _addNodes();
        bytes32[] memory nodes = new bytes32[](1);
        nodes[0] = node1;
        address[] memory contracts = new address[](0);

        vm.prank(owner);
        registry.publishRelease(IFrontendRegistry.ReleaseType.SITE_ONLY, sampleHash, "1.0.0", "notes", contracts, nodes);

        assertEq(resolver.contentHashes(node1), sampleHash);
        assertEq(resolver.contentHashes(node2).length, 0); // node2 not updated
    }

    function test_publishRelease_emitsEvents() public {
        _addNodes();
        bytes32[] memory nodes = new bytes32[](1);
        nodes[0] = node1;
        address[] memory contracts = new address[](0);

        vm.expectEmit(true, false, false, true);
        emit IFrontendRegistry.ReleasePublished(1, IFrontendRegistry.ReleaseType.SITE_ONLY, "1.0.0", sampleHash);

        vm.expectEmit(true, true, false, false);
        emit IFrontendRegistry.NodeUpdated(node1, 1);

        vm.prank(owner);
        registry.publishRelease(IFrontendRegistry.ReleaseType.SITE_ONLY, sampleHash, "1.0.0", "notes", contracts, nodes);
    }

    function test_publishRelease_multipleNodes() public {
        _addNodes();
        bytes32[] memory nodes = new bytes32[](2);
        nodes[0] = node1;
        nodes[1] = node2;
        address[] memory contracts = new address[](0);

        vm.prank(owner);
        registry.publishRelease(IFrontendRegistry.ReleaseType.SITE_ONLY, sampleHash, "1.0.0", "notes", contracts, nodes);

        assertEq(registry.nodeRelease(node1), 1);
        assertEq(registry.nodeRelease(node2), 1);
        assertEq(resolver.contentHashes(node1), sampleHash);
        assertEq(resolver.contentHashes(node2), sampleHash);
    }

    function test_publishRelease_ecosystemStoresContracts() public {
        _addNodes();
        bytes32[] memory nodes = new bytes32[](1);
        nodes[0] = node1;
        address[] memory contracts = new address[](2);
        contracts[0] = address(0xAAA);
        contracts[1] = address(0xBBB);

        vm.prank(owner);
        registry.publishRelease(IFrontendRegistry.ReleaseType.ECOSYSTEM, sampleHash, "2.0.0", "new factory", contracts, nodes);

        address[] memory stored = registry.getReleaseContracts(1);
        assertEq(stored.length, 2);
        assertEq(stored[0], address(0xAAA));
        assertEq(stored[1], address(0xBBB));
    }

    function test_publishRelease_revertsIfNodeNotManaged() public {
        bytes32[] memory nodes = new bytes32[](1);
        nodes[0] = node1; // not added
        address[] memory contracts = new address[](0);

        vm.prank(owner);
        vm.expectRevert(FrontendRegistry.NodeNotManaged.selector);
        registry.publishRelease(IFrontendRegistry.ReleaseType.SITE_ONLY, sampleHash, "1.0.0", "notes", contracts, nodes);
    }

    function test_publishRelease_revertsIfNotOwner() public {
        _addNodes();
        bytes32[] memory nodes = new bytes32[](1);
        nodes[0] = node1;
        address[] memory contracts = new address[](0);

        vm.expectRevert();
        registry.publishRelease(IFrontendRegistry.ReleaseType.SITE_ONLY, sampleHash, "1.0.0", "notes", contracts, nodes);
    }

    function test_publishRelease_idsAreSequential() public {
        _addNodes();
        bytes32[] memory nodes = new bytes32[](1);
        nodes[0] = node1;
        address[] memory contracts = new address[](0);

        vm.startPrank(owner);
        registry.publishRelease(IFrontendRegistry.ReleaseType.SITE_ONLY, sampleHash, "1.0.0", "v1", contracts, nodes);
        registry.publishRelease(IFrontendRegistry.ReleaseType.SITE_ONLY, sampleHash, "1.1.0", "v2", contracts, nodes);
        vm.stopPrank();

        assertEq(registry.releaseCount(), 2);
        (uint32 id1,,,,,,) = registry.releases(0);
        (uint32 id2,,,,,,) = registry.releases(1);
        assertEq(id1, 1);
        assertEq(id2, 2);
    }

    // ── pointNodeToRelease ──

    function _publishTwoReleases() internal {
        _addNodes();
        bytes32[] memory nodes = new bytes32[](1);
        nodes[0] = node1;
        address[] memory contracts = new address[](0);
        vm.startPrank(owner);
        registry.publishRelease(IFrontendRegistry.ReleaseType.SITE_ONLY, sampleHash, "1.0.0", "v1", contracts, nodes);
        registry.publishRelease(IFrontendRegistry.ReleaseType.SITE_ONLY, hex"aabbcc", "1.1.0", "v2", contracts, nodes);
        vm.stopPrank();
    }

    function test_pointNodeToRelease_updatesPointer() public {
        _publishTwoReleases();
        assertEq(registry.nodeRelease(node1), 2); // currently on release 2

        vm.prank(owner);
        registry.pointNodeToRelease(node1, 1); // rollback to release 1

        assertEq(registry.nodeRelease(node1), 1);
    }

    function test_pointNodeToRelease_updatesEnsContentHash() public {
        _publishTwoReleases();

        vm.prank(owner);
        registry.pointNodeToRelease(node1, 1);

        assertEq(resolver.contentHashes(node1), sampleHash); // back to release 1's hash
    }

    function test_pointNodeToRelease_emitsNodeUpdated() public {
        _publishTwoReleases();

        vm.expectEmit(true, true, false, false);
        emit IFrontendRegistry.NodeUpdated(node1, 1);

        vm.prank(owner);
        registry.pointNodeToRelease(node1, 1);
    }

    function test_pointNodeToRelease_canPointUndeployedNode() public {
        _publishTwoReleases();
        // node2 has never been pointed to a release
        assertEq(registry.nodeRelease(node2), 0);

        vm.prank(owner);
        registry.pointNodeToRelease(node2, 1);

        assertEq(registry.nodeRelease(node2), 1);
        assertEq(resolver.contentHashes(node2), sampleHash);
    }

    function test_pointNodeToRelease_revertsOnInvalidReleaseId() public {
        _publishTwoReleases();

        vm.prank(owner);
        vm.expectRevert(FrontendRegistry.InvalidReleaseId.selector);
        registry.pointNodeToRelease(node1, 0);

        vm.prank(owner);
        vm.expectRevert(FrontendRegistry.InvalidReleaseId.selector);
        registry.pointNodeToRelease(node1, 99);
    }

    function test_pointNodeToRelease_revertsIfNodeNotManaged() public {
        _publishTwoReleases();
        bytes32 unknown = keccak256("unknown.eth");

        vm.prank(owner);
        vm.expectRevert(FrontendRegistry.NodeNotManaged.selector);
        registry.pointNodeToRelease(unknown, 1);
    }

    function test_pointNodeToRelease_revertsIfNotOwner() public {
        _publishTwoReleases();
        vm.expectRevert();
        registry.pointNodeToRelease(node1, 1);
    }

    // ── Initialization & Upgradeability ──

    function test_initialize_revertsOnDoubleInit() public {
        vm.expectRevert(Ownable.AlreadyInitialized.selector);
        registry.initialize(owner, address(resolver));
    }

    function test_initialize_revertsOnZeroOwner() public {
        address newImpl = address(new FrontendRegistry());
        address proxy = LibClone.deployERC1967(newImpl);
        FrontendRegistry r = FrontendRegistry(proxy);

        vm.expectRevert(FrontendRegistry.InvalidAddress.selector);
        r.initialize(address(0), address(resolver));
    }

    function test_initialize_revertsOnZeroResolver() public {
        address newImpl = address(new FrontendRegistry());
        address proxy = LibClone.deployERC1967(newImpl);
        FrontendRegistry r = FrontendRegistry(proxy);

        vm.expectRevert(FrontendRegistry.InvalidAddress.selector);
        r.initialize(owner, address(0));
    }

    function test_owner_isSetCorrectly() public {
        assertEq(registry.owner(), owner);
    }

    function test_upgradeAuthorization_revertsIfNotOwner() public {
        address newImpl = address(new FrontendRegistry());
        vm.expectRevert();
        registry.upgradeToAndCall(newImpl, "");
    }

    function test_upgradeAuthorization_succeedsAsOwner() public {
        address newImpl = address(new FrontendRegistry());
        vm.prank(owner);
        registry.upgradeToAndCall(newImpl, "");
        // State preserved after upgrade
        assertEq(registry.owner(), owner);
    }
}
