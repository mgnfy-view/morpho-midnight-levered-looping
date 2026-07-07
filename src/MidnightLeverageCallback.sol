// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin-contracts-5.3.0/token/ERC20/IERC20.sol";
import { IMidnight } from "morpho-midnight-1.0.0/src/interfaces/IMidnight.sol";
import { IMidnightLeverageCallback } from "src/interfaces/IMidnightLeverageCallback.sol";

import { Ownable } from "@openzeppelin-contracts-5.3.0/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin-contracts-5.3.0/access/Ownable2Step.sol";
import { SafeERC20 } from "@openzeppelin-contracts-5.3.0/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin-contracts-5.3.0/utils/ReentrancyGuard.sol";

import { Market } from "morpho-midnight-1.0.0/src/interfaces/IMidnight.sol";
import { CALLBACK_SUCCESS } from "morpho-midnight-1.0.0/src/libraries/ConstantsLib.sol";

/// @title MidnightLeverageCallback.
/// @author mgnfy-view.
/// @notice Callback contract for borrower-directed atomic leverage opens and closes on Morpho Midnight.
/// @dev Each callback handles exactly one collateral index. Multi-collateral positions use multiple calls.
contract MidnightLeverageCallback is IMidnightLeverageCallback, Ownable2Step, ReentrancyGuard {
    /// @dev The Midnight instance this callback accepts calls from.
    IMidnight internal immutable i_midnight;

    /// @dev Whether a swap router is allowed for callback swaps.
    mapping(address router => bool allowed) internal s_isAllowedSwapRouter;

    /// @notice Constructs the leverage callback.
    /// @param _midnight The Midnight instance allowed to call callback entry points.
    /// @param _initialOwner The owner that can manage the swap router allowlist.
    constructor(IMidnight _midnight, address _initialOwner) Ownable(_initialOwner) {
        if (address(_midnight) == address(0)) revert MidnightLeverageCallback__AddressZero();
        i_midnight = _midnight;
    }

    /// @notice Sets whether an address may be used as a swap target.
    /// @param _router The swap router address to configure.
    /// @param _allowed Whether `_router` is allowed for swaps.
    function setIsAllowedSwapRouter(address _router, bool _allowed) external {
        _checkOwner();
        if (_router == address(0)) revert MidnightLeverageCallback__AddressZero();
        s_isAllowedSwapRouter[_router] = _allowed;
        emit SwapRouterAllowed(_router, _allowed);
    }

    /// @notice Opens one leveraged collateral leg after Midnight transfers borrowed loan assets to this callback.
    /// @dev Callable only by the configured Midnight instance.
    /// @param _market Midnight market where the borrower is opening leverage.
    /// @param _sellerAssets Loan-token amount borrowed by the seller and sent to this callback.
    /// @param _seller Borrower whose debt is increased and whose collateral will be supplied.
    /// @param _receiver Address that received `_sellerAssets`; must be this callback.
    /// @param _data ABI-encoded `OpenParams`.
    /// @return The Midnight callback success selector.
    function onSell(
        bytes32,
        Market memory _market,
        uint256 _sellerAssets,
        uint256,
        uint256,
        address _seller,
        address _receiver,
        bytes memory _data
    )
        external
        nonReentrant
        returns (bytes32)
    {
        if (msg.sender != address(i_midnight)) revert MidnightLeverageCallback__OnlyMidnight();
        if (_receiver != address(this)) revert MidnightLeverageCallback__ReceiverMismatch();
        OpenParams memory params = abi.decode(_data, (OpenParams));
        if (!s_isAllowedSwapRouter[params.swapRouter]) revert MidnightLeverageCallback__SwapRouterNotAllowed();

        IERC20 loanToken = IERC20(_market.loanToken);
        address collateralToken = _market.collateralParams[params.collateralIndex].token;
        if (params.marginAmount > 0) {
            SafeERC20.safeTransferFrom(loanToken, _seller, address(this), params.marginAmount);
        }
        uint256 amountIn = _sellerAssets + params.marginAmount;
        uint256 collateralAssets = _swap(
            _market.loanToken,
            collateralToken,
            amountIn,
            params.minCollateralAssets,
            params.swapRouter,
            params.swapCalldata
        );
        SafeERC20.forceApprove(IERC20(collateralToken), address(i_midnight), collateralAssets);
        i_midnight.supplyCollateral(_market, params.collateralIndex, collateralAssets, _seller);
        _refundBalance(loanToken, _seller);

        return CALLBACK_SUCCESS;
    }

    /// @notice Closes or reduces one leveraged collateral leg during a Midnight repayment callback.
    /// @dev Callable only by the configured Midnight instance.
    /// @param _market Midnight market where the borrower is repaying debt.
    /// @param _units Debt units being repaid by Midnight after this callback returns.
    /// @param _onBehalf Borrower whose debt was reduced before the callback and whose collateral is withdrawn.
    /// @param _data ABI-encoded `CloseParams`.
    /// @return The Midnight callback success selector.
    function onRepay(
        bytes32,
        Market memory _market,
        uint256 _units,
        address _onBehalf,
        bytes memory _data
    )
        external
        nonReentrant
        returns (bytes32)
    {
        if (msg.sender != address(i_midnight)) revert MidnightLeverageCallback__OnlyMidnight();
        CloseParams memory params = abi.decode(_data, (CloseParams));
        if (!s_isAllowedSwapRouter[params.swapRouter]) revert MidnightLeverageCallback__SwapRouterNotAllowed();

        IERC20 loanToken = IERC20(_market.loanToken);
        address collateralToken = _market.collateralParams[params.collateralIndex].token;
        i_midnight.withdrawCollateral(
            _market, params.collateralIndex, params.collateralAmount, _onBehalf, address(this)
        );
        _swap(
            collateralToken,
            _market.loanToken,
            params.collateralAmount,
            params.minLoanAssets,
            params.swapRouter,
            params.swapCalldata
        );
        uint256 loanBalance = loanToken.balanceOf(address(this));
        if (loanBalance < _units) {
            uint256 shortfall = _units - loanBalance;
            if (shortfall > params.maxRepayShortfall) revert MidnightLeverageCallback__ShortfallExceedsCap();
            SafeERC20.safeTransferFrom(loanToken, _onBehalf, address(this), shortfall);
        } else if (loanBalance > _units) {
            SafeERC20.safeTransfer(loanToken, _onBehalf, loanBalance - _units);
        }
        _refundBalance(IERC20(collateralToken), _onBehalf);
        SafeERC20.forceApprove(loanToken, address(i_midnight), _units);

        return CALLBACK_SUCCESS;
    }

    /// @dev Executes an allowlisted router call and returns the measured `_tokenOut` balance delta.
    function _swap(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint256 _minAmountOut,
        address _router,
        bytes memory _swapCalldata
    )
        internal
        returns (uint256)
    {
        uint256 balanceBefore = IERC20(_tokenOut).balanceOf(address(this));
        SafeERC20.forceApprove(IERC20(_tokenIn), _router, _amountIn);
        (bool success,) = _router.call(_swapCalldata);
        if (!success) revert MidnightLeverageCallback__SwapFailed();
        SafeERC20.forceApprove(IERC20(_tokenIn), _router, 0);
        uint256 amountOut = IERC20(_tokenOut).balanceOf(address(this)) - balanceBefore;
        if (amountOut < _minAmountOut) revert MidnightLeverageCallback__SlippageExceeded();

        return amountOut;
    }

    /// @dev Sends the entire token balance held by this contract to `_borrower`.
    function _refundBalance(IERC20 _token, address _borrower) internal {
        uint256 balance = _token.balanceOf(address(this));
        if (balance > 0) SafeERC20.safeTransfer(_token, _borrower, balance);
    }

    /// @notice Returns the Midnight instance this callback accepts calls from.
    /// @return The configured Midnight instance.
    function getMidnight() external view returns (IMidnight) {
        return i_midnight;
    }

    /// @notice Returns whether `_router` is allowed for callback swaps.
    /// @param _router The swap router to check.
    /// @return Whether `_router` is allowlisted.
    function isAllowedSwapRouter(address _router) external view returns (bool) {
        return s_isAllowedSwapRouter[_router];
    }
}
