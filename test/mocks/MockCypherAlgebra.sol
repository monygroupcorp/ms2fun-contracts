// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../src/interfaces/algebra/IAlgebra.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice Minimal mock pool for Cypher/Algebra tests
contract MockAlgebraPool {
    address public token0;
    address public token1;
    bool public initialized;
    uint160 public sqrtPriceX96;

    constructor(address _token0, address _token1) {
        token0 = _token0;
        token1 = _token1;
    }

    function initialize(uint160 _sqrtPriceX96) external {
        require(!initialized, "Already initialized");
        initialized = true;
        sqrtPriceX96 = _sqrtPriceX96;
    }

    function globalState() external view returns (
        uint160 price, int24 tick, uint16 lastFee,
        uint8 pluginConfig, uint16 communityFee, bool unlocked
    ) {
        return (sqrtPriceX96, 0, 3000, 0, 0, true);
    }
}

/// @notice Minimal mock factory
contract MockAlgebraFactory {
    mapping(address => mapping(address => address)) public poolByPair;

    event Pool(address indexed token0, address indexed token1, address pool);

    function createPool(address tokenA, address tokenB, bytes calldata) external returns (address pool) {
        require(tokenA != tokenB, "Same token");
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(poolByPair[t0][t1] == address(0), "Pool exists");
        pool = address(new MockAlgebraPool(t0, t1));
        poolByPair[t0][t1] = pool;
        poolByPair[t1][t0] = pool;
        emit Pool(t0, t1, pool);
    }
}

/// @notice Mock Algebra position manager
contract MockAlgebraPositionManager {
    struct Position {
        address token0; address token1; address deployer;
        int24 tickLower; int24 tickUpper;
        uint128 liquidity;
        uint128 tokensOwed0; uint128 tokensOwed1;
    }

    mapping(uint256 => Position) internal _positions;
    mapping(uint256 => address) public owners;
    mapping(uint256 => address) public approved;
    mapping(uint256 => uint256) public fees0;
    mapping(uint256 => uint256) public fees1;
    uint256 public nextTokenId = 1;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Collect(uint256 indexed tokenId, address recipient, uint256 amount0, uint256 amount1);

    function mint(IAlgebraNFTPositionManager.MintParams calldata p)
        external payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        if (p.amount0Desired > 0) MockERC20(p.token0).transferFrom(msg.sender, address(this), p.amount0Desired);
        if (p.amount1Desired > 0) MockERC20(p.token1).transferFrom(msg.sender, address(this), p.amount1Desired);

        amount0 = p.amount0Desired;
        amount1 = p.amount1Desired;
        liquidity = uint128(amount0 + amount1);
        tokenId = nextTokenId++;
        owners[tokenId] = p.recipient;

        _positions[tokenId] = Position({
            token0: p.token0, token1: p.token1, deployer: p.deployer,
            tickLower: p.tickLower, tickUpper: p.tickUpper,
            liquidity: liquidity, tokensOwed0: 0, tokensOwed1: 0
        });

        emit Transfer(address(0), p.recipient, tokenId);
    }

    function collect(IAlgebraNFTPositionManager.CollectParams calldata p)
        external payable
        returns (uint256 amount0, uint256 amount1)
    {
        Position storage pos = _positions[p.tokenId];
        amount0 = uint256(pos.tokensOwed0) + fees0[p.tokenId];
        amount1 = uint256(pos.tokensOwed1) + fees1[p.tokenId];
        if (amount0 > p.amount0Max) amount0 = p.amount0Max;
        if (amount1 > p.amount1Max) amount1 = p.amount1Max;

        if (amount0 > 0) {
            uint256 bal = MockERC20(pos.token0).balanceOf(address(this));
            amount0 = bal >= amount0 ? amount0 : bal;
            if (amount0 > 0) {
                MockERC20(pos.token0).transfer(p.recipient, amount0);
                pos.tokensOwed0 = 0;
                fees0[p.tokenId] = 0;
            }
        }
        if (amount1 > 0) {
            uint256 bal = MockERC20(pos.token1).balanceOf(address(this));
            amount1 = bal >= amount1 ? amount1 : bal;
            if (amount1 > 0) {
                MockERC20(pos.token1).transfer(p.recipient, amount1);
                pos.tokensOwed1 = 0;
                fees1[p.tokenId] = 0;
            }
        }
        emit Collect(p.tokenId, p.recipient, amount0, amount1);
    }

    function decreaseLiquidity(IAlgebraNFTPositionManager.DecreaseLiquidityParams calldata p)
        external payable
        returns (uint256 amount0, uint256 amount1)
    {
        Position storage pos = _positions[p.tokenId];
        require(owners[p.tokenId] == msg.sender || approved[p.tokenId] == msg.sender, "Not owner");
        uint128 liq = p.liquidity > pos.liquidity ? pos.liquidity : p.liquidity;
        amount0 = uint256(liq) / 2;
        amount1 = uint256(liq) / 2;
        pos.liquidity -= liq;
        pos.tokensOwed0 += uint128(amount0);
        pos.tokensOwed1 += uint128(amount1);
    }

    function positions(uint256 tokenId)
        external view
        returns (
            uint88 nonce, address operator,
            address token0, address token1, address deployer,
            int24 tickLower, int24 tickUpper, uint128 liquidity,
            uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0, uint128 tokensOwed1
        )
    {
        Position storage p = _positions[tokenId];
        return (0, address(0), p.token0, p.token1, p.deployer, p.tickLower, p.tickUpper,
                p.liquidity, 0, 0, p.tokensOwed0, p.tokensOwed1);
    }

    function ownerOf(uint256 tokenId) external view returns (address) { return owners[tokenId]; }

    function approve(address spender, uint256 tokenId) external {
        require(owners[tokenId] == msg.sender, "Not owner");
        approved[tokenId] = spender;
    }

    function transferFrom(address from, address to, uint256 tokenId) external {
        require(owners[tokenId] == from, "Not owner");
        owners[tokenId] = to;
        emit Transfer(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        require(owners[tokenId] == from, "Not owner");
        owners[tokenId] = to;
        emit Transfer(from, to, tokenId);
    }

    // Test helpers
    function setFees(uint256 tokenId, uint256 _f0, uint256 _f1) external {
        fees0[tokenId] = _f0;
        fees1[tokenId] = _f1;
    }

    function setPosition(uint256 tokenId, address _token0, address _token1, address _owner) external {
        _positions[tokenId] = Position({
            token0: _token0, token1: _token1, deployer: address(0),
            tickLower: -887220, tickUpper: 887220,
            liquidity: 1, tokensOwed0: 0, tokensOwed1: 0
        });
        owners[tokenId] = _owner;
    }
}

/// @notice Mock Algebra swap router
contract MockAlgebraSwapRouter {
    mapping(address => mapping(address => uint256)) public rates; // tokenIn => tokenOut => rate (1e18 = 1:1)

    function exactInputSingle(IAlgebraSwapRouter.ExactInputSingleParams calldata p)
        external payable
        returns (uint256 amountOut)
    {
        MockERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        uint256 rate = rates[p.tokenIn][p.tokenOut];
        if (rate == 0) rate = 1e18;
        amountOut = (p.amountIn * rate) / 1e18;
        require(amountOut >= p.amountOutMinimum, "Slippage");
        MockERC20(p.tokenOut).transfer(p.recipient, amountOut);
    }

    function setRate(address tokenIn, address tokenOut, uint256 rate) external {
        rates[tokenIn][tokenOut] = rate;
    }
}
