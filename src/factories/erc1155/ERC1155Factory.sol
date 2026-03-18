// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IMasterRegistry} from "../../master/interfaces/IMasterRegistry.sol";
import {ERC1155Instance} from "./ERC1155Instance.sol";
import {IFactory} from "../../interfaces/IFactory.sol";
import {IComponentRegistry} from "../../registry/interfaces/IComponentRegistry.sol";
import {FeatureUtils} from "../../master/libraries/FeatureUtils.sol";
import {FreeMintParams} from "../../interfaces/IFactoryTypes.sol";
import {GatingScope} from "../../gating/IGatingModule.sol";
import {ICreateX, CREATEX} from "../../shared/CreateXConstants.sol";

/**
 * @title ERC1155Factory
 * @notice Deploys and registers ERC1155 edition instances.
 *         Single responsibility: validate → deploy via CREATE3 → register.
 *         Protocol fees flow directly to treasury — no custody.
 *         Promotion (featured placements, badges) is handled externally.
 */
contract ERC1155Factory is Ownable, ReentrancyGuard, IFactory {
    error InvalidAddress();
    error UnapprovedComponent();
    error InvalidName();
    error VaultMustBeContract();
    error NameAlreadyTaken();
    error NotAuthorizedAgent();

    IMasterRegistry public masterRegistry;
    address public immutable globalMessageRegistry;
    IComponentRegistry public immutable componentRegistry;
    address public protocolTreasury;
    address public weth;
    address public dynamicPricingModule;

    bytes32[] internal _features;

    /// @notice Parameters for instance creation. Defined here — not in shared IFactoryTypes —
    ///         because CreateParams is specific to this factory type.
    struct CreateParams {
        string name;
        string metadataURI;
        address creator;
        address vault;
        string styleUri;
        address gatingModule;    // address(0) = open
        FreeMintParams freeMint;
    }

    event InstanceCreated(
        address indexed instance,
        address indexed creator,
        string name,
        address indexed vault
    );
    event ProtocolTreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    constructor(
        address _masterRegistry,
        address _globalMessageRegistry,
        address _componentRegistry,
        address _weth
    ) {
        _initializeOwner(msg.sender);
        if (_globalMessageRegistry == address(0)) revert InvalidAddress();
        masterRegistry = IMasterRegistry(_masterRegistry);
        globalMessageRegistry = _globalMessageRegistry;
        componentRegistry = IComponentRegistry(_componentRegistry);
        weth = _weth;
        _features.push(FeatureUtils.GATING);
    }

    /// @notice Deploy a new ERC1155 instance. Any ETH forwarded directly to treasury.
    function createInstance(
        bytes32 salt,
        CreateParams calldata params
    ) external payable nonReentrant returns (address instance) {
        if (params.gatingModule != address(0)) {
            if (!componentRegistry.isApprovedComponent(params.gatingModule)) revert UnapprovedComponent();
        }

        // Forward fee directly to treasury — factory holds no ETH
        if (msg.value > 0 && protocolTreasury != address(0)) {
            SafeTransferLib.safeTransferETH(protocolTreasury, msg.value);
        }

        if (bytes(params.name).length == 0) revert InvalidName();
        if (params.creator == address(0)) revert InvalidAddress();
        if (params.vault == address(0)) revert InvalidAddress();
        if (params.vault.code.length == 0) revert VaultMustBeContract();

        bool agentCreated = false;
        if (msg.sender != params.creator) {
            if (!masterRegistry.isAgent(msg.sender)) revert NotAuthorizedAgent();
            agentCreated = true;
        }

        if (masterRegistry.isNameTaken(params.name)) revert NameAlreadyTaken();

        instance = _deployAndRegister(salt, params, agentCreated);
        ERC1155Instance(instance).initializeFreeMint(params.freeMint.allocation, params.freeMint.scope);

        emit InstanceCreated(instance, params.creator, params.name, params.vault);
    }

    function _deployAndRegister(
        bytes32 salt,
        CreateParams calldata params,
        bool agentCreated
    ) private returns (address instance) {
        instance = ICreateX(CREATEX).deployCreate3(salt, _buildInitCode(params, agentCreated));
        masterRegistry.registerInstance(
            instance,
            address(this),
            params.creator,
            params.name,
            params.metadataURI,
            params.vault
        );
    }

    /// @dev Isolated so that the large abi.encode runs in a fresh stack frame.
    function _buildInitCode(CreateParams calldata params, bool agentCreated) private view returns (bytes memory) {
        ERC1155Instance.InstanceInit memory init = ERC1155Instance.InstanceInit({
            globalMessageRegistry: globalMessageRegistry,
            protocolTreasury: protocolTreasury,
            masterRegistry: address(masterRegistry),
            gatingModule: params.gatingModule,
            dynamicPricingModule: dynamicPricingModule,
            weth: weth
        });
        return abi.encodePacked(
            type(ERC1155Instance).creationCode,
            abi.encode(params.name, params.creator, address(this), params.vault, params.styleUri, init, agentCreated)
        );
    }

    // ── Admin ─────────────────────────────────────────────────────────────────

    /// @notice Set the default dynamic pricing module for new instances.
    ///         address(0) disables dynamic pricing for new deployments.
    function setDynamicPricingModule(address module) external onlyOwner {
        if (module != address(0)) {
            if (!componentRegistry.isApprovedComponent(module)) revert UnapprovedComponent();
        }
        dynamicPricingModule = module;
    }

    function setWeth(address _weth) external onlyOwner {
        if (_weth == address(0)) revert InvalidAddress();
        weth = _weth;
    }

    function setProtocolTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert InvalidAddress();
        address old = protocolTreasury;
        protocolTreasury = _treasury;
        emit ProtocolTreasuryUpdated(old, _treasury);
    }

    // ── IFactory ─────────────────────────────────────────────────────────────

    function protocol() external view returns (address) {
        return owner();
    }

    /// @notice Returns supported component feature tags.
    ///         DYNAMIC_PRICING included lazily when a module is set.
    function features() external view returns (bytes32[] memory) {
        if (dynamicPricingModule != address(0)) {
            bytes32[] memory f = new bytes32[](_features.length + 1);
            for (uint256 i = 0; i < _features.length; i++) f[i] = _features[i];
            f[_features.length] = FeatureUtils.DYNAMIC_PRICING;
            return f;
        }
        return _features;
    }

    function requiredFeatures() external pure returns (bytes32[] memory) {
        return new bytes32[](0);
    }

    // ── Utilities ────────────────────────────────────────────────────────────

    /// @notice Preview the deterministic address for a given salt.
    function computeInstanceAddress(bytes32 salt) external view returns (address) {
        bytes32 guardedSalt = keccak256(abi.encodePacked(uint256(uint160(address(this))), salt));
        return ICreateX(CREATEX).computeCreate3Address(guardedSalt, CREATEX);
    }
}
