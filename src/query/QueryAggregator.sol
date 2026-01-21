// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UUPSUpgradeable} from "solady/utils/UUPSUpgradeable.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {IMasterRegistry} from "../master/interfaces/IMasterRegistry.sol";
import {IAlignmentVault} from "../interfaces/IAlignmentVault.sol";
import {IInstance} from "../interfaces/IInstance.sol";

/// @notice Interface for FeaturedQueueManager
interface IFeaturedQueueManager {
    function getFeaturedInstances(uint256 startIndex, uint256 endIndex)
        external view returns (address[] memory instances, uint256 total);

    function getRentalInfo(address instance) external view returns (
        IMasterRegistry.RentalSlot memory rental,
        uint256 position,
        uint256 renewalDeposit,
        bool isExpired
    );

    function queueLength() external view returns (uint256);
}

/// @notice Interface for GlobalMessageRegistry
interface IGlobalMessageRegistry {
    struct GlobalMessage {
        address instance;
        address sender;
        uint256 packedData;
        string message;
    }

    function getRecentMessages(uint256 count) external view returns (GlobalMessage[] memory);
}

/// @notice Interface for ERC404 balance queries
interface IERC404Balance {
    function balanceOf(address account) external view returns (uint256);
}

/// @notice Interface for ERC1155 balance queries
interface IERC1155Balance {
    function balanceOf(address account, uint256 id) external view returns (uint256);
    function getEditionCount() external view returns (uint256);
    function getAllEditionIds() external view returns (uint256[] memory);
}

/// @notice Interface for ERC404 staking queries
interface IERC404Staking {
    function stakingEnabled() external view returns (bool);
    function stakedBalance(address user) external view returns (uint256);
    function calculatePendingRewards(address staker) external view returns (uint256);
}

/**
 * @title QueryAggregator
 * @notice Read-only aggregator that batches queries across multiple registry contracts
 * @dev Reduces frontend RPC calls from 80+ to 1-3 per page by aggregating data from:
 *      - MasterRegistry (instances, factories, vaults)
 *      - FeaturedQueueManager (featured queue positions)
 *      - GlobalMessageRegistry (recent activity)
 *      - Individual instance contracts (dynamic card data)
 */
contract QueryAggregator is UUPSUpgradeable, Ownable {
    // ============ Data Structures ============

    /// @notice All data needed to render a project card in the UI
    struct ProjectCard {
        // From MasterRegistry.InstanceInfo
        address instance;
        string name;
        string metadataURI;
        address creator;
        uint256 registeredAt;
        // From MasterRegistry.FactoryInfo
        address factory;
        string contractType;
        string factoryTitle;
        // From MasterRegistry.VaultInfo
        address vault;
        string vaultName;
        // From instance.getCardData()
        uint256 currentPrice;
        uint256 totalSupply;
        uint256 maxSupply;
        bool isActive;
        bytes extraData;
        // From FeaturedQueueManager
        uint256 featuredPosition;
        uint256 featuredExpires;
    }

    /// @notice Compact vault info for leaderboards
    struct VaultSummary {
        address vault;
        string name;
        uint256 tvl;
        uint256 instanceCount;
    }

    /// @notice ERC404 token holdings for a user
    struct ERC404Holding {
        address instance;
        string name;
        uint256 tokenBalance;
        uint256 nftBalance;
        uint256 stakedBalance;
        uint256 pendingRewards;
    }

    /// @notice ERC1155 edition holdings for a user
    struct ERC1155Holding {
        address instance;
        string name;
        uint256[] editionIds;
        uint256[] balances;
    }

    /// @notice Vault benefactor position for a user
    struct VaultPosition {
        address vault;
        string name;
        uint256 contribution;
        uint256 shares;
        uint256 claimable;
    }

    // ============ State Variables ============

    IMasterRegistry public masterRegistry;
    IFeaturedQueueManager public featuredQueueManager;
    IGlobalMessageRegistry public globalMessageRegistry;

    uint256 public constant MAX_QUERY_LIMIT = 50;

    bool private _initialized;

    // ============ Events ============

    event Initialized(address masterRegistry, address featuredQueueManager, address globalMessageRegistry);

    // ============ Constructor ============

    constructor() {
        _initializeOwner(msg.sender);
    }

    // ============ Initialization ============

    /**
     * @notice Initialize the aggregator with registry addresses
     * @param _masterRegistry MasterRegistry contract address
     * @param _featuredQueueManager FeaturedQueueManager contract address
     * @param _globalMessageRegistry GlobalMessageRegistry contract address
     * @param _owner Owner address
     */
    function initialize(
        address _masterRegistry,
        address _featuredQueueManager,
        address _globalMessageRegistry,
        address _owner
    ) external {
        require(!_initialized, "Already initialized");
        require(_masterRegistry != address(0), "Invalid master registry");
        require(_featuredQueueManager != address(0), "Invalid featured queue manager");
        require(_globalMessageRegistry != address(0), "Invalid global message registry");
        require(_owner != address(0), "Invalid owner");

        _initialized = true;
        _setOwner(_owner);

        masterRegistry = IMasterRegistry(_masterRegistry);
        featuredQueueManager = IFeaturedQueueManager(_featuredQueueManager);
        globalMessageRegistry = IGlobalMessageRegistry(_globalMessageRegistry);

        emit Initialized(_masterRegistry, _featuredQueueManager, _globalMessageRegistry);
    }

    // ============ Main Query Methods ============

    /**
     * @notice Fetches all data needed for the home page in one call
     * @param offset Starting index in featured queue
     * @param limit Number of projects to return (max 50)
     * @return projects Fully populated ProjectCard array
     * @return totalFeatured Total count in featured queue (for pagination)
     * @return topVaults Top 3 vaults by TVL
     * @return recentActivity Last 5 global messages
     */
    function getHomePageData(uint256 offset, uint256 limit)
        external view returns (
            ProjectCard[] memory projects,
            uint256 totalFeatured,
            VaultSummary[] memory topVaults,
            IGlobalMessageRegistry.GlobalMessage[] memory recentActivity
        )
    {
        require(limit <= MAX_QUERY_LIMIT, "Limit too high");

        // 1. Get queue length for bounds checking
        uint256 queueLen = featuredQueueManager.queueLength();
        totalFeatured = queueLen;

        // 2. Get top 3 vaults by TVL (do this regardless of featured count)
        topVaults = _getTopVaults(3);

        // 3. Get recent activity (do this regardless of featured count)
        recentActivity = globalMessageRegistry.getRecentMessages(5);

        // 4. Handle bounds clamping for featured projects
        if (offset >= queueLen) {
            // Return empty projects if offset is past end
            projects = new ProjectCard[](0);
            return (projects, totalFeatured, topVaults, recentActivity);
        }

        // Clamp endIndex to queue bounds
        uint256 endIndex = offset + limit;
        if (endIndex > queueLen) {
            endIndex = queueLen;
        }

        // 5. Get featured instances from queue
        (address[] memory featuredAddresses, ) =
            featuredQueueManager.getFeaturedInstances(offset, endIndex);

        // 6. Hydrate each into ProjectCard
        projects = new ProjectCard[](featuredAddresses.length);
        for (uint256 i = 0; i < featuredAddresses.length; i++) {
            projects[i] = _hydrateProject(featuredAddresses[i]);
        }
    }

    /**
     * @notice Fetches ProjectCard data for multiple instances
     * @param instances Array of instance addresses
     * @return cards Fully populated ProjectCard array
     */
    function getProjectCardsBatch(address[] calldata instances)
        external view returns (ProjectCard[] memory cards)
    {
        require(instances.length <= MAX_QUERY_LIMIT, "Too many instances");

        cards = new ProjectCard[](instances.length);
        for (uint256 i = 0; i < instances.length; i++) {
            cards[i] = _hydrateProject(instances[i]);
        }
    }

    /**
     * @notice Fetches all holdings for a user across specified instances and vaults
     * @param user User address to query
     * @param instances Array of instance addresses to check
     * @return erc404Holdings All ERC404 token/NFT holdings with non-zero balance
     * @return erc1155Holdings All ERC1155 edition holdings with non-zero balance
     * @return vaultPositions All vault benefactor positions with non-zero shares
     * @return totalClaimable Sum of all claimable rewards (ETH)
     */
    function getPortfolioData(address user, address[] calldata instances)
        external view returns (
            ERC404Holding[] memory erc404Holdings,
            ERC1155Holding[] memory erc1155Holdings,
            VaultPosition[] memory vaultPositions,
            uint256 totalClaimable
        )
    {
        // Temporary arrays (we'll trim later)
        ERC404Holding[] memory tempERC404 = new ERC404Holding[](instances.length);
        ERC1155Holding[] memory tempERC1155 = new ERC1155Holding[](instances.length);
        uint256 erc404Count = 0;
        uint256 erc1155Count = 0;

        for (uint256 i = 0; i < instances.length; i++) {
            address instance = instances[i];

            // Get instance info to determine type
            try masterRegistry.getInstanceInfo(instance) returns (IMasterRegistry.InstanceInfo memory info) {
                // Get factory info to determine contract type
                try masterRegistry.getFactoryInfoByAddress(info.factory) returns (IMasterRegistry.FactoryInfo memory factoryInfo) {
                    bytes32 typeHash = keccak256(bytes(factoryInfo.contractType));

                    if (typeHash == keccak256("ERC404")) {
                        ERC404Holding memory holding = _getERC404Holding(instance, user, info.name);
                        if (holding.tokenBalance > 0 || holding.stakedBalance > 0) {
                            tempERC404[erc404Count++] = holding;
                            totalClaimable += holding.pendingRewards;
                        }
                    } else if (typeHash == keccak256("ERC1155")) {
                        ERC1155Holding memory holding = _getERC1155Holding(instance, user, info.name);
                        if (holding.editionIds.length > 0) {
                            tempERC1155[erc1155Count++] = holding;
                        }
                    }
                } catch {}
            } catch {}
        }

        // Trim arrays to actual size
        erc404Holdings = new ERC404Holding[](erc404Count);
        for (uint256 i = 0; i < erc404Count; i++) {
            erc404Holdings[i] = tempERC404[i];
        }

        erc1155Holdings = new ERC1155Holding[](erc1155Count);
        for (uint256 i = 0; i < erc1155Count; i++) {
            erc1155Holdings[i] = tempERC1155[i];
        }

        // Get vault positions
        vaultPositions = _getVaultPositions(user);

        // Add vault claimable to total
        for (uint256 i = 0; i < vaultPositions.length; i++) {
            totalClaimable += vaultPositions[i].claimable;
        }
    }

    /**
     * @notice Fetches ranked vault list
     * @param sortBy 0 = by TVL, 1 = by popularity (instance count)
     * @param limit Number of vaults to return (max 50)
     * @return vaults Sorted VaultSummary array
     */
    function getVaultLeaderboard(uint8 sortBy, uint256 limit)
        external view returns (VaultSummary[] memory vaults)
    {
        require(limit <= MAX_QUERY_LIMIT, "Limit too high");

        if (sortBy == 0) {
            // Sort by TVL - delegate to existing method
            (address[] memory addrs, uint256[] memory tvls, string[] memory names) =
                masterRegistry.getVaultsByTVL(limit);

            vaults = new VaultSummary[](addrs.length);
            for (uint256 i = 0; i < addrs.length; i++) {
                try masterRegistry.getVaultInfo(addrs[i]) returns (IMasterRegistry.VaultInfo memory info) {
                    vaults[i] = VaultSummary({
                        vault: addrs[i],
                        name: names[i],
                        tvl: tvls[i],
                        instanceCount: info.instanceCount
                    });
                } catch {
                    vaults[i] = VaultSummary({
                        vault: addrs[i],
                        name: names[i],
                        tvl: tvls[i],
                        instanceCount: 0
                    });
                }
            }
        } else {
            // Sort by popularity - delegate to existing method
            (address[] memory addrs, uint256[] memory counts, string[] memory names) =
                masterRegistry.getVaultsByPopularity(limit);

            vaults = new VaultSummary[](addrs.length);
            for (uint256 i = 0; i < addrs.length; i++) {
                // Fetch TVL separately
                uint256 tvl = 0;
                try IAlignmentVault(payable(addrs[i])).accumulatedFees() returns (uint256 fees) {
                    tvl = fees;
                } catch {}

                vaults[i] = VaultSummary({
                    vault: addrs[i],
                    name: names[i],
                    tvl: tvl,
                    instanceCount: counts[i]
                });
            }
        }
    }

    // ============ Internal Helpers ============

    /**
     * @notice Hydrate an instance address into a full ProjectCard
     * @param instance Instance address
     * @return card Fully populated ProjectCard
     */
    function _hydrateProject(address instance) internal view returns (ProjectCard memory card) {
        // 1. Get registry info
        try masterRegistry.getInstanceInfo(instance) returns (IMasterRegistry.InstanceInfo memory info) {
            card.instance = instance;
            card.name = info.name;
            card.metadataURI = info.metadataURI;
            card.creator = info.creator;
            card.registeredAt = info.registeredAt;
            card.factory = info.factory;
            card.vault = info.vault;

            // 2. Get factory info
            try masterRegistry.getFactoryInfoByAddress(info.factory) returns (IMasterRegistry.FactoryInfo memory factoryInfo) {
                card.contractType = factoryInfo.contractType;
                card.factoryTitle = factoryInfo.title;
            } catch {}

            // 3. Get vault info
            if (info.vault != address(0)) {
                try masterRegistry.getVaultInfo(info.vault) returns (IMasterRegistry.VaultInfo memory vaultInfo) {
                    card.vaultName = vaultInfo.name;
                } catch {}
            }

            // 4. Get dynamic data from instance
            try IInstance(instance).getCardData() returns (
                uint256 price,
                uint256 supply,
                uint256 maxSupply,
                bool active,
                bytes memory extra
            ) {
                card.currentPrice = price;
                card.totalSupply = supply;
                card.maxSupply = maxSupply;
                card.isActive = active;
                card.extraData = extra;
            } catch {}

            // 5. Get featured status
            try featuredQueueManager.getRentalInfo(instance) returns (
                IMasterRegistry.RentalSlot memory rental,
                uint256 position,
                uint256,
                bool isExpired
            ) {
                if (position > 0 && !isExpired) {
                    card.featuredPosition = position;
                    card.featuredExpires = rental.expiresAt;
                }
            } catch {}
        } catch {}
    }

    /**
     * @notice Get top vaults by TVL
     * @param limit Number of vaults to return
     * @return vaults VaultSummary array
     */
    function _getTopVaults(uint256 limit) internal view returns (VaultSummary[] memory vaults) {
        try masterRegistry.getVaultsByTVL(limit) returns (
            address[] memory addrs,
            uint256[] memory tvls,
            string[] memory names
        ) {
            vaults = new VaultSummary[](addrs.length);
            for (uint256 i = 0; i < addrs.length; i++) {
                uint256 instanceCount = 0;
                try masterRegistry.getVaultInfo(addrs[i]) returns (IMasterRegistry.VaultInfo memory info) {
                    instanceCount = info.instanceCount;
                } catch {}

                vaults[i] = VaultSummary({
                    vault: addrs[i],
                    name: names[i],
                    tvl: tvls[i],
                    instanceCount: instanceCount
                });
            }
        } catch {
            vaults = new VaultSummary[](0);
        }
    }

    /**
     * @notice Get ERC404 holding for a user
     */
    function _getERC404Holding(address instance, address user, string memory name_)
        internal view returns (ERC404Holding memory holding)
    {
        holding.instance = instance;
        holding.name = name_;

        // Get token balance
        try IERC404Balance(instance).balanceOf(user) returns (uint256 balance) {
            holding.tokenBalance = balance;
            // NFT balance is tokenBalance / 1e24 (1M tokens per NFT)
            holding.nftBalance = balance / (1000000 * 1e18);
        } catch {}

        // Get staking info
        try IERC404Staking(instance).stakingEnabled() returns (bool enabled) {
            if (enabled) {
                try IERC404Staking(instance).stakedBalance(user) returns (uint256 staked) {
                    holding.stakedBalance = staked;
                } catch {}

                try IERC404Staking(instance).calculatePendingRewards(user) returns (uint256 pending) {
                    holding.pendingRewards = pending;
                } catch {}
            }
        } catch {}
    }

    /**
     * @notice Get ERC1155 holding for a user
     */
    function _getERC1155Holding(address instance, address user, string memory name_)
        internal view returns (ERC1155Holding memory holding)
    {
        holding.instance = instance;
        holding.name = name_;

        // Get all edition IDs
        try IERC1155Balance(instance).getAllEditionIds() returns (uint256[] memory editionIds) {
            // Check balance for each edition
            uint256[] memory tempBalances = new uint256[](editionIds.length);
            uint256 nonZeroCount = 0;

            for (uint256 i = 0; i < editionIds.length; i++) {
                try IERC1155Balance(instance).balanceOf(user, editionIds[i]) returns (uint256 balance) {
                    if (balance > 0) {
                        tempBalances[nonZeroCount] = balance;
                        nonZeroCount++;
                    }
                } catch {}
            }

            // Trim to non-zero balances
            if (nonZeroCount > 0) {
                holding.editionIds = new uint256[](nonZeroCount);
                holding.balances = new uint256[](nonZeroCount);

                uint256 idx = 0;
                for (uint256 i = 0; i < editionIds.length && idx < nonZeroCount; i++) {
                    try IERC1155Balance(instance).balanceOf(user, editionIds[i]) returns (uint256 balance) {
                        if (balance > 0) {
                            holding.editionIds[idx] = editionIds[i];
                            holding.balances[idx] = balance;
                            idx++;
                        }
                    } catch {}
                }
            }
        } catch {}
    }

    /**
     * @notice Get vault positions for a user
     */
    function _getVaultPositions(address user) internal view returns (VaultPosition[] memory positions) {
        // Get all vaults
        try masterRegistry.getVaultList() returns (address[] memory vaultAddrs) {
            VaultPosition[] memory tempPositions = new VaultPosition[](vaultAddrs.length);
            uint256 positionCount = 0;

            for (uint256 i = 0; i < vaultAddrs.length; i++) {
                address vaultAddr = vaultAddrs[i];

                try IAlignmentVault(payable(vaultAddr)).getBenefactorShares(user) returns (uint256 shares) {
                    if (shares > 0) {
                        VaultPosition memory pos;
                        pos.vault = vaultAddr;
                        pos.shares = shares;

                        // Get vault name
                        try masterRegistry.getVaultInfo(vaultAddr) returns (IMasterRegistry.VaultInfo memory info) {
                            pos.name = info.name;
                        } catch {}

                        // Get contribution
                        try IAlignmentVault(payable(vaultAddr)).getBenefactorContribution(user) returns (uint256 contribution) {
                            pos.contribution = contribution;
                        } catch {}

                        // Get claimable
                        try IAlignmentVault(payable(vaultAddr)).calculateClaimableAmount(user) returns (uint256 claimable) {
                            pos.claimable = claimable;
                        } catch {}

                        tempPositions[positionCount++] = pos;
                    }
                } catch {}
            }

            // Trim to actual size
            positions = new VaultPosition[](positionCount);
            for (uint256 i = 0; i < positionCount; i++) {
                positions[i] = tempPositions[i];
            }
        } catch {
            positions = new VaultPosition[](0);
        }
    }

    // ============ Admin Functions ============

    /**
     * @notice Update registry addresses
     * @param _masterRegistry New MasterRegistry address
     * @param _featuredQueueManager New FeaturedQueueManager address
     * @param _globalMessageRegistry New GlobalMessageRegistry address
     */
    function setRegistries(
        address _masterRegistry,
        address _featuredQueueManager,
        address _globalMessageRegistry
    ) external onlyOwner {
        if (_masterRegistry != address(0)) {
            masterRegistry = IMasterRegistry(_masterRegistry);
        }
        if (_featuredQueueManager != address(0)) {
            featuredQueueManager = IFeaturedQueueManager(_featuredQueueManager);
        }
        if (_globalMessageRegistry != address(0)) {
            globalMessageRegistry = IGlobalMessageRegistry(_globalMessageRegistry);
        }
    }

    // ============ UUPS ============

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
