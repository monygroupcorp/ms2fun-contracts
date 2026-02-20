// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {ERC404BondingInstance} from "../../../src/factories/erc404/ERC404BondingInstance.sol";
import {ERC404StakingModule} from "../../../src/factories/erc404/ERC404StakingModule.sol";
import {CurveParamsComputer} from "../../../src/factories/erc404/CurveParamsComputer.sol";
import {BondingCurveMath} from "../../../src/factories/erc404/libraries/BondingCurveMath.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IAlignmentVault} from "../../../src/interfaces/IAlignmentVault.sol";
import {LibClone} from "solady/utils/LibClone.sol";

// ── Mock: MasterRegistry ──────────────────────────────────────────────────────

contract MockMasterRegistryIntegration {
    mapping(address => bool) public registeredInstances;

    function setInstance(address a, bool v) external {
        registeredInstances[a] = v;
    }

    function isRegisteredInstance(address a) external view returns (bool) {
        return registeredInstances[a];
    }
}

// ── Mock: AlignmentVault ──────────────────────────────────────────────────────

/// @notice Minimal mock vault that satisfies IAlignmentVault.
///         claimFees() sends ETH from its own balance to msg.sender and returns the amount.
///         validateCompliance() always returns true.
contract MockAlignmentVault is IAlignmentVault {
    uint256 public feesToReturn;

    /// @notice Fund the mock with ETH it will return on next claimFees()
    function setFeesToReturn(uint256 amount) external {
        feesToReturn = amount;
    }

    receive() external payable {}

    // ── IAlignmentVault ──

    function receiveInstance(Currency, uint256, address) external payable override {}

    function claimFees() external override returns (uint256 ethClaimed) {
        ethClaimed = feesToReturn;
        feesToReturn = 0;
        if (ethClaimed > 0) {
            (bool ok,) = payable(msg.sender).call{value: ethClaimed}("");
            require(ok, "ETH transfer failed");
        }
    }

    function validateCompliance(address) external pure override returns (bool) {
        return true;
    }

    function calculateClaimableAmount(address) external pure override returns (uint256) {
        return 0;
    }

    function getBenefactorContribution(address) external pure override returns (uint256) {
        return 0;
    }

    function getBenefactorShares(address) external pure override returns (uint256) {
        return 0;
    }

    function vaultType() external pure override returns (string memory) {
        return "MOCK";
    }

    function description() external pure override returns (string memory) {
        return "Mock vault for integration tests";
    }

    function accumulatedFees() external pure override returns (uint256) {
        return 0;
    }

    function totalShares() external pure override returns (uint256) {
        return 0;
    }

    function supportsCapability(bytes32) external pure override returns (bool) {
        return false;
    }

    function currentPolicy() external pure override returns (bytes memory) {
        return "";
    }

    function delegateBenefactor(address) external pure override {}

    function getBenefactorDelegate(address) external pure override returns (address) {
        return address(0);
    }

    function claimFeesAsDelegate(address[] calldata) external pure override returns (uint256) {
        return 0;
    }
}

// ── Integration Test ──────────────────────────────────────────────────────────

/**
 * @title ERC404StakingIntegrationTest
 * @notice End-to-end test: instance ↔ module ↔ vault staking flow.
 *
 * Scenario (mirrors test_recordStake_lateJoiner_doesNotDilutePriorStaker at instance level):
 *   1. user1 stakes 1 unit of tokens
 *   2. vault returns 1 ether in fees on first claimStakerRewards() call
 *   3. user2 stakes 1 unit of tokens (late joiner)
 *   4. vault returns 1 ether more fees on second epoch
 *   5. user1 claims → 1.5 ether (1 sole epoch + 0.5 shared epoch)
 *   6. user2 claims → 0.5 ether (0 sole epoch + 0.5 shared epoch)
 */
contract ERC404StakingIntegrationTest is Test {
    ERC404BondingInstance public instance;
    ERC404StakingModule public stakingModule;
    MockMasterRegistryIntegration public mockRegistry;
    MockAlignmentVault public mockVault;
    CurveParamsComputer public curveComputer;

    address public owner = address(0x1);
    address public user1 = address(0x2);
    address public user2 = address(0x3);

    // Convenience constant: 1 token-unit (matches unit param in constructor)
    uint256 constant TOKEN_UNIT = 1_000_000 ether;

    uint256 constant MAX_SUPPLY = 10_000_000 * 1e18;
    uint256 constant LIQUIDITY_RESERVE_PERCENT = 10;

    function setUp() public {
        // 1. Deploy mock infrastructure
        mockRegistry = new MockMasterRegistryIntegration();
        stakingModule = new ERC404StakingModule(address(mockRegistry));
        mockVault = new MockAlignmentVault();
        curveComputer = new CurveParamsComputer(address(this));

        // Fund the vault so it can pay out fees
        vm.deal(address(mockVault), 100 ether);

        vm.startPrank(owner);

        // 2. Build curve / tier config
        BondingCurveMath.Params memory curveParams = BondingCurveMath.Params({
            initialPrice: 0.025 ether,
            quarticCoeff: 3 gwei,
            cubicCoeff: 1333333333,
            quadraticCoeff: 2 gwei,
            normalizationFactor: 1e7
        });

        bytes32[] memory passwordHashes = new bytes32[](2);
        passwordHashes[0] = keccak256("password1");
        passwordHashes[1] = keccak256("password2");

        uint256[] memory volumeCaps = new uint256[](2);
        volumeCaps[0] = 1000 * 1e18;
        volumeCaps[1] = 10000 * 1e18;

        ERC404BondingInstance.TierConfig memory tierConfig = ERC404BondingInstance.TierConfig({
            tierType: ERC404BondingInstance.TierType.VOLUME_CAP,
            passwordHashes: passwordHashes,
            volumeCaps: volumeCaps,
            tierUnlockTimes: new uint256[](0)
        });

        // 3. Deploy instance — factory address must equal msg.sender (owner) for DN404 mirror
        ERC404BondingInstance implIntg = new ERC404BondingInstance();
        instance = ERC404BondingInstance(payable(LibClone.clone(address(implIntg))));
        instance.initialize(
            "Integration Token",
            "INTG",
            MAX_SUPPLY,
            LIQUIDITY_RESERVE_PERCENT,
            curveParams,
            tierConfig,
            address(0x100), // mockV4PoolManager (not used in staking tests)
            address(0),     // hook not set
            address(0x300), // mockWETH
            owner,          // factory = msg.sender
            address(mockRegistry),
            address(mockVault),
            owner,
            "",             // styleUri
            address(0xFEE), // protocolTreasury
            100,            // bondingFeeBps (1%)
            200,            // graduationFeeBps (2%)
            100,            // polBps (1%)
            address(0xC1EA),// factoryCreator
            40,             // creatorGraduationFeeBps (0.4%)
            3000,           // poolFee
            60,             // tickSpacing
            TOKEN_UNIT,     // unit (1 NFT = TOKEN_UNIT tokens)
            address(stakingModule),
            address(0x600), // mockLiquidityDeployer
            address(curveComputer) // curve computer
        );

        vm.stopPrank();

        // 4. Register instance with mock registry so module accepts its calls
        mockRegistry.setInstance(address(instance), true);

        // 5. Give users tokens by minting directly to them via vm.store isn't viable;
        //    instead deal ETH and buy via bonding curve, or mint by pranking as instance.
        //    Simplest: prank as instance and call _mintERC20 via deal + direct transfer of
        //    minted tokens. Since DN404 exposes no external mint we'll use the buyTokens path.
        //
        //    Actually the easiest route: give users a pre-minted ERC20 balance by
        //    dealing to the instance (it holds bonding supply) and pranking as instance to
        //    transfer. The instance inherits DN404 which has an internal _mint. We can call
        //    the public bonding buy function with enough ETH.
        //
        //    We open bonding first, then users buy.
        // Activate bonding: set open time, hook, and active flag
        vm.startPrank(owner);
        uint256 openTime = block.timestamp + 1 days;
        instance.setBondingOpenTime(openTime);
        instance.setV4Hook(address(0x200)); // mock hook address
        instance.setBondingActive(true);
        vm.stopPrank();

        vm.warp(openTime);

        // Give users ETH to buy tokens via bonding curve
        vm.deal(user1, 10 ether);
        vm.deal(user2, 10 ether);

        // Buy exactly TOKEN_UNIT (1 NFT unit worth) for each user
        uint256 buyAmount = TOKEN_UNIT;
        uint256 cost1 = _getCost(instance, buyAmount);
        uint256 fee1 = (cost1 * instance.bondingFeeBps()) / 10000;

        vm.prank(user1);
        instance.buyBonding{value: cost1 + fee1}(buyAmount, cost1 + fee1, false, bytes32(0), bytes(""), 0);

        uint256 cost2 = _getCost(instance, buyAmount);
        uint256 fee2 = (cost2 * instance.bondingFeeBps()) / 10000;

        vm.prank(user2);
        instance.buyBonding{value: cost2 + fee2}(buyAmount, cost2 + fee2, false, bytes32(0), bytes(""), 0);
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    function _getCost(ERC404BondingInstance inst, uint256 amount) internal view returns (uint256) {
        (uint256 ip, uint256 qc, uint256 cc, uint256 qdc, uint256 nf) = inst.curveParams();
        BondingCurveMath.Params memory p = BondingCurveMath.Params({
            initialPrice: ip,
            quarticCoeff: qc,
            cubicCoeff: cc,
            quadraticCoeff: qdc,
            normalizationFactor: nf
        });
        return curveComputer.calculateCost(p, inst.totalBondingSupply(), amount);
    }

    function _enableStaking() internal {
        vm.prank(owner);
        instance.enableStaking();
    }

    // ── Tests ─────────────────────────────────────────────────────────────────

    function test_stakingEnabled_afterOwnerCall() public {
        _enableStaking();
        assertTrue(stakingModule.stakingEnabled(address(instance)));
    }

    function test_stake_recordsBalanceInModule() public {
        _enableStaking();

        uint256 user1Balance = instance.balanceOf(user1);
        require(user1Balance > 0, "user1 has no balance");

        vm.prank(user1);
        instance.stake(user1Balance);

        assertEq(stakingModule.stakedBalance(address(instance), user1), user1Balance);
        assertEq(stakingModule.totalStaked(address(instance)), user1Balance);
    }

    function test_claimStakerRewards_soleStaker_getsAll() public {
        _enableStaking();

        uint256 user1Balance = instance.balanceOf(user1);
        vm.prank(user1);
        instance.stake(user1Balance);

        // Vault has 1 ether to return on claimFees()
        mockVault.setFeesToReturn(1 ether);

        uint256 ethBefore = user1.balance;

        vm.prank(user1);
        uint256 reward = instance.claimStakerRewards();

        uint256 ethAfter = user1.balance;

        assertEq(reward, 1 ether, "sole staker should receive all fees");
        assertEq(ethAfter - ethBefore, 1 ether, "ETH should be transferred to user1");
    }

    function test_lateJoiner_doesNotDilutePriorStaker() public {
        _enableStaking();

        // --- Epoch 1: user1 is sole staker ---
        uint256 user1Balance = instance.balanceOf(user1);
        vm.prank(user1);
        instance.stake(user1Balance);

        // Vault returns 1 ether on user1's first claim
        mockVault.setFeesToReturn(1 ether);

        uint256 user1EthBefore = user1.balance;
        vm.prank(user1);
        uint256 reward1 = instance.claimStakerRewards();
        // user1 earned 1 ether (sole staker for this epoch)
        assertEq(reward1, 1 ether, "user1 epoch1: should get all 1 ether");

        // --- user2 joins after epoch 1 fees have been distributed ---
        uint256 user2Balance = instance.balanceOf(user2);
        vm.prank(user2);
        instance.stake(user2Balance);

        // --- Epoch 2: both stakers are equal (assuming equal token purchases) ---
        mockVault.setFeesToReturn(1 ether);

        // user2 claims first (no previous claim watermark)
        uint256 user2EthBefore = user2.balance;
        vm.prank(user2);
        uint256 reward2 = instance.claimStakerRewards();

        // user2's claimStakerRewards already called claimFees, so vault is drained.
        // user1 claims the remainder
        vm.prank(user1);
        uint256 reward3 = instance.claimStakerRewards();

        uint256 user1Total = reward1 + reward3;
        uint256 user2Total = reward2;

        console.log("user1 total rewards:", user1Total);
        console.log("user2 total rewards:", user2Total);
        console.log("user1 epoch2 rewards:", reward3);
        console.log("user2 epoch2 rewards:", reward2);

        // user1 staked equally to user2, and user1Balance == user2Balance in typical case.
        // The share-based accounting should ensure:
        //   user1: 1 ether (sole) + 0.5 ether (shared) = 1.5 ether
        //   user2: 0 + 0.5 ether (shared) = 0.5 ether
        // Total distributed: 2 ether
        assertEq(user1Total + user2Total, 2 ether, "total distributed should equal 2 ether");
        assertGt(user1Total, user2Total, "user1 should earn more than late-joiner user2");
    }

    function test_lateJoiner_exactAmounts_whenEqualStakes() public {
        _enableStaking();

        // Verify users bought equal amounts (both called buyTokens with same ETH)
        uint256 user1Balance = instance.balanceOf(user1);
        uint256 user2Balance = instance.balanceOf(user2);
        // Both users spent 1 ether so balances should be equal
        assertEq(user1Balance, user2Balance, "test setup: users should have equal token balances");

        // --- Epoch 1: user1 stakes alone, vault returns 1 ether ---
        vm.prank(user1);
        instance.stake(user1Balance);

        mockVault.setFeesToReturn(1 ether);
        vm.prank(user1);
        uint256 reward1Epoch1 = instance.claimStakerRewards();
        assertEq(reward1Epoch1, 1 ether, "user1 sole epoch: full 1 ether");

        // --- user2 stakes now ---
        vm.prank(user2);
        instance.stake(user2Balance);

        // --- Epoch 2: vault returns 1 ether, shared 50/50 ---
        mockVault.setFeesToReturn(1 ether);

        // user1 claims first — triggers claimFees, drains vault
        vm.prank(user1);
        uint256 reward1Epoch2 = instance.claimStakerRewards();

        // user2 claims — vault is drained but module still has the recordFeesReceived amount
        vm.prank(user2);
        uint256 reward2Epoch2 = instance.claimStakerRewards();

        assertEq(reward1Epoch2, 0.5 ether, "user1 shared epoch: 0.5 ether");
        assertEq(reward2Epoch2, 0.5 ether, "user2 late joiner: 0.5 ether");
        assertEq(reward1Epoch1 + reward1Epoch2, 1.5 ether, "user1 total: 1.5 ether");
        assertEq(reward2Epoch2, 0.5 ether, "user2 total: 0.5 ether");
    }

    function test_unstake_returnsTokensAndRewards() public {
        _enableStaking();

        uint256 user1Balance = instance.balanceOf(user1);
        vm.prank(user1);
        instance.stake(user1Balance);

        mockVault.setFeesToReturn(1 ether);

        uint256 ethBefore = user1.balance;
        uint256 tokensBefore = instance.balanceOf(user1);

        vm.prank(user1);
        instance.unstake(user1Balance);

        uint256 ethAfter = user1.balance;
        uint256 tokensAfter = instance.balanceOf(user1);

        assertEq(tokensAfter, user1Balance, "tokens should be returned after unstake");
        assertEq(ethAfter - ethBefore, 1 ether, "pending rewards should be paid on unstake");
    }
}
