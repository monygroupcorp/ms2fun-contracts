// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IERC404
 * @notice Interface for ERC404 token standard
 */
interface IERC404 {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    
    // ERC404 specific
    function erc721TransferFrom(address from, address to, uint256 id) external;
    function erc721Approve(address spender, uint256 id) external;
    function erc721BalanceOf(address owner) external view returns (uint256);
    function erc721OwnerOf(uint256 id) external view returns (address);
}

