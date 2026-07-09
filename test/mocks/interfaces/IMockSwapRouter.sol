// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IMockSwapRouter {
    error MockSwapRouter__SwapFailed();

    function swap(address _tokenIn, address _tokenOut, uint256 _amountOut, uint256 _amountToPull) external;

    function revertSwap() external pure;
}
