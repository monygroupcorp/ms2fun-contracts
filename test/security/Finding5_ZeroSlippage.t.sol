// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ZAMMLiquidityDeployerModule} from "../../src/factories/erc404zamm/ZAMMLiquidityDeployerModule.sol";
import {ILiquidityDeployerModule} from "../../src/interfaces/ILiquidityDeployerModule.sol";
import {MockEXECToken} from "../mocks/MockEXECToken.sol";
/// @notice Minimal vault stub that accepts ETH contributions (used in Finding 5)
contract AcceptingVaultStub {
    receive() external payable {}
    fallback() external payable {}
}

/// @notice Standalone ZAMM that validates non-zero slippage (Finding 5)
contract StrictSlippageZAMM {
    error ZeroSlippage();

    struct PoolKey {
        uint256 id0; uint256 id1;
        address token0; address token1;
        uint256 feeOrHook;
    }

    struct Pool {
        uint112 reserve0; uint112 reserve1; uint32 blockTimestampLast;
        uint256 price0CumulativeLast; uint256 price1CumulativeLast;
        uint256 kLast; uint256 feeGrowthGlobal;
    }

    receive() external payable {}

    function addLiquidity(
        PoolKey calldata,
        uint256 a0,
        uint256 /*a1*/,
        uint256 a0Min,
        uint256 a1Min,
        address /*to*/,
        uint256 /*deadline*/
    ) external payable returns (uint256, uint256, uint256) {
        if (a0Min == 0 || a1Min == 0) revert ZeroSlippage();
        return (a0, a0, 1000 ether);
    }

    function pools(uint256) external pure returns (Pool memory) {
        return Pool(0, 0, 0, 0, 0, 0, 0);
    }
}

contract Finding5_ZeroSlippageGraduationTest is Test {
    ZAMMLiquidityDeployerModule public deployer;
    StrictSlippageZAMM public strictZamm;
    MockEXECToken public token;

    address public treasury = address(0xFEE);
    address public vaultAddr;

    function setUp() public {
        vaultAddr = address(new AcceptingVaultStub());
        token = new MockEXECToken(1_000_000e18);
        strictZamm = new StrictSlippageZAMM();
        vm.deal(address(strictZamm), 100 ether);

        deployer = new ZAMMLiquidityDeployerModule(address(strictZamm), 30);
        vm.deal(treasury, 10 ether);
    }

    /// @notice deployLiquidity must pass non-zero slippage (StrictSlippageZAMM reverts on 0,0)
    function test_deployLiquidity_passesNonZeroSlippage() public {
        uint256 ethReserve   = 1 ether;
        uint256 tokenReserve = 1000e18;

        token.transfer(address(deployer), tokenReserve);

        ILiquidityDeployerModule.DeployParams memory p = ILiquidityDeployerModule.DeployParams({
            token: address(token),
            vault: vaultAddr,
            instance: address(this),
            ethReserve: ethReserve,
            tokenReserve: tokenReserve,
            protocolTreasury: treasury
        });

        deployer.deployLiquidity{value: ethReserve}(p);
    }
}
