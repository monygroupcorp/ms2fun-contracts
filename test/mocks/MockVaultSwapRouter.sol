// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IVaultSwapRouter} from "../../src/interfaces/IVaultSwapRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Mock swap router for unit tests. Simulates swap with 0.3% slippage.
contract MockVaultSwapRouter is IVaultSwapRouter {
    function swapETHForToken(
        address token,
        uint256 minOut,
        address recipient
    ) external payable override returns (uint256 tokenReceived) {
        tokenReceived = (msg.value * 997) / 1000;
        require(tokenReceived >= minOut, "Slippage too high");
        // Simulate token transfer to recipient (test must pre-fund this mock)
        IERC20(token).transfer(recipient, tokenReceived);
    }

    function swapTokenForETH(
        address token,
        uint256 amount,
        uint256 minOut,
        address recipient
    ) external override returns (uint256 ethReceived) {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        ethReceived = (amount * 997) / 1000;
        require(ethReceived >= minOut, "Slippage too high");
        (bool ok,) = payable(recipient).call{value: ethReceived}("");
        require(ok, "ETH transfer failed");
    }

    receive() external payable {}
}
