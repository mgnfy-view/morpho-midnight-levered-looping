// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin-contracts-5.3.0/token/ERC20/IERC20.sol";
import { IMidnight } from "morpho-midnight-1.0.0/src/interfaces/IMidnight.sol";
import { ISignatureTransfer } from "permit2-1.0.0/src/interfaces/ISignatureTransfer.sol";
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
    /// @dev EIP-712 typehash for the Permit2 witness used by open-side margin pulls.
    bytes32 internal constant MARGIN_WITNESS_TYPEHASH = keccak256(
        "MarginWitness(bytes32 marketId,address collateralToken,uint256 minCollateralAssets,address swapRouter,bytes32 swapCalldataHash)"
    );

    /// @dev Permit2 witness type string for open-side margin-pull signatures.
    string internal constant MARGIN_WITNESS_TYPE_STRING =
        "MarginWitness witness)MarginWitness(bytes32 marketId,address collateralToken,uint256 minCollateralAssets,address swapRouter,bytes32 swapCalldataHash)TokenPermissions(address token,uint256 amount)";

    /// @dev EIP-712 typehash for the Permit2 witness used by close-side shortfall pulls.
    bytes32 internal constant REPAY_WITNESS_TYPEHASH = keccak256(
        "RepayWitness(bytes32 marketId,uint256 collateralIndex,address collateralToken,uint256 collateralAmount,uint256 minLoanAssets,address swapRouter,bytes32 swapCalldataHash)"
    );

    /// @dev Permit2 witness type string for close-side shortfall-pull signatures.
    string internal constant REPAY_WITNESS_TYPE_STRING =
        "RepayWitness witness)RepayWitness(bytes32 marketId,uint256 collateralIndex,address collateralToken,uint256 collateralAmount,uint256 minLoanAssets,address swapRouter,bytes32 swapCalldataHash)TokenPermissions(address token,uint256 amount)";

    /// @dev The Midnight instance this callback accepts calls from.
    IMidnight internal immutable i_midnight;

    /// @dev The canonical Permit2 instance used for signature-based token pulls.
    ISignatureTransfer internal immutable i_permit2;

    /// @dev Whether a swap router is allowed for callback swaps.
    mapping(address router => bool allowed) internal s_isAllowedSwapRouter;

    /// @notice Constructs the leverage callback.
    /// @param _midnight The Midnight instance allowed to call callback entry points.
    /// @param _permit2 The canonical Permit2 instance used for signature-based token pulls.
    /// @param _initialOwner The owner that can manage the swap router allowlist.
    constructor(IMidnight _midnight, ISignatureTransfer _permit2, address _initialOwner) Ownable(_initialOwner) {
        if (address(_midnight) == address(0) || address(_permit2) == address(0)) {
            revert MidnightLeverageCallback__AddressZero();
        }

        i_midnight = _midnight;
        i_permit2 = _permit2;
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
    /// @param _id Midnight market id bound into the Permit2 witness.
    /// @param _market Midnight market where the borrower is opening leverage.
    /// @param _sellerAssets Loan-token amount borrowed by the seller and sent to this callback.
    /// @param _seller Borrower whose debt is increased and whose collateral will be supplied.
    /// @param _receiver Address that received `_sellerAssets`; must be this callback.
    /// @param _data ABI-encoded `OpenParams`.
    /// @return The Midnight callback success selector.
    function onSell(
        bytes32 _id,
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
        bytes32 marginWitness = _hashMarginWitness(_id, collateralToken, params);
        _pullWithAuthorization(
            loanToken,
            _seller,
            params.marginAmount,
            params.marginAmount,
            params.auth,
            marginWitness,
            MARGIN_WITNESS_TYPE_STRING
        );
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
    /// @param _id Midnight market id bound into the Permit2 witness.
    /// @param _market Midnight market where the borrower is repaying debt.
    /// @param _units Debt units being repaid by Midnight after this callback returns.
    /// @param _onBehalf Borrower whose debt was reduced before the callback and whose collateral is withdrawn.
    /// @param _data ABI-encoded `CloseParams`.
    /// @return The Midnight callback success selector.
    function onRepay(
        bytes32 _id,
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
            bytes32 repayWitness = _hashRepayWitness(_id, collateralToken, params);
            _pullWithAuthorization(
                loanToken,
                _onBehalf,
                params.maxRepayShortfall,
                shortfall,
                params.auth,
                repayWitness,
                REPAY_WITNESS_TYPE_STRING
            );
        } else if (loanBalance > _units) {
            SafeERC20.safeTransfer(loanToken, _onBehalf, loanBalance - _units);
        }
        _refundBalance(IERC20(collateralToken), _onBehalf);
        SafeERC20.forceApprove(loanToken, address(i_midnight), _units);

        return CALLBACK_SUCCESS;
    }

    /// @dev Pulls tokens through Permit2 witness transfer or, with an empty signature, `transferFrom`.
    /// @param _token The ERC-20 token to pull.
    /// @param _from The token owner authorizing the pull.
    /// @param _permittedAmount The maximum amount authorized by Permit2.
    /// @param _requestedAmount The amount requested for this pull.
    /// @param _auth Permit2 authorization data or empty-signature fallback marker.
    /// @param _witness The Permit2 witness hash bound to the callback parameters.
    /// @param _witnessTypeString The Permit2 witness type string matching `_witness`.
    function _pullWithAuthorization(
        IERC20 _token,
        address _from,
        uint256 _permittedAmount,
        uint256 _requestedAmount,
        PullAuthorization memory _auth,
        bytes32 _witness,
        string memory _witnessTypeString
    )
        internal
    {
        if (_requestedAmount == 0) return;
        if (_auth.signature.length == 0) {
            SafeERC20.safeTransferFrom(_token, _from, address(this), _requestedAmount);
            return;
        }

        ISignatureTransfer.PermitTransferFrom memory permit =
            _buildPermit(address(_token), _permittedAmount, _auth.nonce, _auth.deadline);
        ISignatureTransfer.SignatureTransferDetails memory details =
            ISignatureTransfer.SignatureTransferDetails({ to: address(this), requestedAmount: _requestedAmount });
        i_permit2.permitWitnessTransferFrom(permit, details, _from, _witness, _witnessTypeString, _auth.signature);
    }

    /// @dev Builds the Permit2 permit for a signature-transfer pull.
    /// @param _token The token address permitted for transfer.
    /// @param _amount The maximum amount permitted for transfer.
    /// @param _nonce The Permit2 unordered nonce.
    /// @param _deadline The timestamp after which the permit expires.
    /// @return The Permit2 transfer permit.
    function _buildPermit(
        address _token,
        uint256 _amount,
        uint256 _nonce,
        uint256 _deadline
    )
        internal
        pure
        returns (ISignatureTransfer.PermitTransferFrom memory)
    {
        return ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({ token: _token, amount: _amount }),
            nonce: _nonce,
            deadline: _deadline
        });
    }

    /// @dev Hashes open-side fields bound to a Permit2 margin-pull signature.
    /// @param _marketId The Midnight market id to bind into the witness.
    /// @param _collateralToken The collateral token to bind into the witness.
    /// @param _params Open callback parameters to bind into the witness.
    /// @return The hashed Permit2 witness.
    function _hashMarginWitness(
        bytes32 _marketId,
        address _collateralToken,
        OpenParams memory _params
    )
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                MARGIN_WITNESS_TYPEHASH,
                _marketId,
                _collateralToken,
                _params.minCollateralAssets,
                _params.swapRouter,
                keccak256(_params.swapCalldata)
            )
        );
    }

    /// @dev Hashes close-side fields bound to a Permit2 shortfall-pull signature.
    /// @param _marketId The Midnight market id to bind into the witness.
    /// @param _collateralToken The collateral token to bind into the witness.
    /// @param _params Close callback parameters to bind into the witness.
    /// @return The hashed Permit2 witness.
    function _hashRepayWitness(
        bytes32 _marketId,
        address _collateralToken,
        CloseParams memory _params
    )
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                REPAY_WITNESS_TYPEHASH,
                _marketId,
                _params.collateralIndex,
                _collateralToken,
                _params.collateralAmount,
                _params.minLoanAssets,
                _params.swapRouter,
                keccak256(_params.swapCalldata)
            )
        );
    }

    /// @dev Executes an allowlisted router call and returns the measured `_tokenOut` balance delta.
    /// @param _tokenIn The token approved to and spent by `_router`.
    /// @param _tokenOut The token expected from the swap.
    /// @param _amountIn The exact input amount approved to `_router`.
    /// @param _minAmountOut The minimum acceptable `_tokenOut` balance delta.
    /// @param _router The swap router to call.
    /// @param _swapCalldata The calldata passed to `_router`.
    /// @return The measured `_tokenOut` balance delta.
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
    /// @param _token The token to refund.
    /// @param _borrower The refund recipient.
    function _refundBalance(IERC20 _token, address _borrower) internal {
        uint256 balance = _token.balanceOf(address(this));
        if (balance > 0) SafeERC20.safeTransfer(_token, _borrower, balance);
    }

    /// @notice Returns the Midnight instance this callback accepts calls from.
    /// @return The configured Midnight instance.
    function getMidnight() external view returns (IMidnight) {
        return i_midnight;
    }

    /// @notice Returns the Permit2 instance used for signature-based token pulls.
    /// @return The configured Permit2 instance.
    function getPermit2() external view returns (ISignatureTransfer) {
        return i_permit2;
    }

    /// @notice Returns whether `_router` is allowed for callback swaps.
    /// @param _router The swap router to check.
    /// @return Whether `_router` is allowlisted.
    function isAllowedSwapRouter(address _router) external view returns (bool) {
        return s_isAllowedSwapRouter[_router];
    }

    /// @notice Builds the Permit2 margin-pull permit and witness data for an open callback.
    /// @param _loanToken The loan token pulled from the borrower.
    /// @param _marketId The Midnight market id to bind into the witness.
    /// @param _collateralToken The collateral token to bind into the witness.
    /// @param _params Open callback parameters to bind into the witness.
    /// @return Permit2 transfer permit that should be signed by the borrower.
    /// @return Witness hash bound to `_params`.
    /// @return Permit2 witness type string.
    function buildMarginPermitData(
        address _loanToken,
        bytes32 _marketId,
        address _collateralToken,
        OpenParams calldata _params
    )
        external
        pure
        returns (ISignatureTransfer.PermitTransferFrom memory, bytes32, string memory)
    {
        return (
            _buildPermit(_loanToken, _params.marginAmount, _params.auth.nonce, _params.auth.deadline),
            _hashMarginWitness(_marketId, _collateralToken, _params),
            MARGIN_WITNESS_TYPE_STRING
        );
    }

    /// @notice Builds the Permit2 shortfall-pull permit and witness data for a close callback.
    /// @param _loanToken The loan token pulled from the borrower if swaps produce a shortfall.
    /// @param _marketId The Midnight market id to bind into the witness.
    /// @param _collateralToken The collateral token to bind into the witness.
    /// @param _params Close callback parameters to bind into the witness.
    /// @return Permit2 transfer permit that should be signed by the borrower.
    /// @return Witness hash bound to `_params`.
    /// @return Permit2 witness type string.
    function buildRepayPermitData(
        address _loanToken,
        bytes32 _marketId,
        address _collateralToken,
        CloseParams calldata _params
    )
        external
        pure
        returns (ISignatureTransfer.PermitTransferFrom memory, bytes32, string memory)
    {
        return (
            _buildPermit(_loanToken, _params.maxRepayShortfall, _params.auth.nonce, _params.auth.deadline),
            _hashRepayWitness(_marketId, _collateralToken, _params),
            REPAY_WITNESS_TYPE_STRING
        );
    }
}
