// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin-contracts-5.3.0/token/ERC20/IERC20.sol";

import { SafeERC20 } from "@openzeppelin-contracts-5.3.0/token/ERC20/utils/SafeERC20.sol";

import { IMockSwapRouter } from "test/mocks/interfaces/IMockSwapRouter.sol";

contract MockSwapRouter is IMockSwapRouter {
    function swap(address _tokenIn, address _tokenOut, uint256 _amountOut, uint256 _amountToPull) external {
        SafeERC20.safeTransferFrom(IERC20(_tokenIn), msg.sender, address(this), _amountToPull);
        SafeERC20.safeTransfer(IERC20(_tokenOut), msg.sender, _amountOut);
    }

    function revertSwap() external pure {
        revert MockSwapRouter__SwapFailed();
    }
}
