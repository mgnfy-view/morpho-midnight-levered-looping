// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IRepayCallback, ISellCallback } from "morpho-midnight-1.0.0/src/interfaces/ICallbacks.sol";
import { IMidnight } from "morpho-midnight-1.0.0/src/interfaces/IMidnight.sol";
import { ISignatureTransfer } from "permit2-1.0.0/src/interfaces/ISignatureTransfer.sol";

/// @title IMidnightLeverageCallback
/// @author mgnfy-view
/// @notice Interface for borrower-directed atomic leverage opens and closes on Morpho Midnight.
interface IMidnightLeverageCallback is ISellCallback, IRepayCallback {
    /// @notice Signature-based pull authorization shared by open and close flows.
    /// @dev An empty `signature` signals the fallback path: a plain `transferFrom` against a standing ERC-20
    /// allowance instead of a Permit2 witness transfer.
    struct PullAuthorization {
        /// @notice Permit2 unordered nonce chosen off-chain by the signer. Unused when `signature` is empty.
        uint256 nonce;
        /// @notice Unix timestamp after which the permit signature is no longer valid. Unused when `signature` is empty.
        uint256 deadline;
        /// @notice EIP-712 signature over the Permit2 witness transfer. Empty bytes falls back to a plain pull.
        bytes signature;
    }

    /// @notice Parameters for opening one leveraged collateral leg through `take()`.
    struct OpenParams {
        /// @notice Loan-token amount pulled from the borrower in addition to the borrowed seller assets.
        uint256 marginAmount;
        /// @notice Index of the collateral in `market.collateralParams`.
        uint256 collateralIndex;
        /// @notice Allowed router called with `swapCalldata`.
        address swapRouter;
        /// @notice Router calldata computed off-chain for the current transaction.
        bytes swapCalldata;
        /// @notice Minimum collateral-token balance delta required from the swap.
        uint256 minCollateralAssets;
        /// @notice Authorization for pulling `marginAmount` from the borrower.
        PullAuthorization auth;
    }

    /// @notice Parameters for closing one leveraged collateral leg through `repay()`.
    struct CloseParams {
        /// @notice Index of the collateral in `market.collateralParams` to withdraw and swap.
        uint256 collateralIndex;
        /// @notice Exact collateral-token amount to withdraw from Midnight.
        uint256 collateralAmount;
        /// @notice Allowed router called with `swapCalldata`.
        address swapRouter;
        /// @notice Router calldata computed off-chain for the current transaction.
        bytes swapCalldata;
        /// @notice Minimum loan-token balance delta required from the swap.
        uint256 minLoanAssets;
        /// @notice Maximum loan-token shortfall that may be pulled from the borrower after the swap.
        uint256 maxRepayShortfall;
        /// @notice Authorization for pulling the loan-token shortfall from the borrower.
        PullAuthorization auth;
    }

    /// @notice Emitted when the owner changes a swap router's allowlist status.
    /// @param _router The swap router whose allowlist status changed.
    /// @param _allowed Whether the router is allowed for future swaps.
    event SwapRouterAllowed(address indexed _router, bool _allowed);

    /// @notice Reverts when a required address is zero.
    error MidnightLeverageCallback__AddressZero();
    /// @notice Reverts when a callback is not called by the configured Midnight instance.
    error MidnightLeverageCallback__OnlyMidnight();
    /// @notice Reverts when an open callback receives assets at an unexpected receiver.
    error MidnightLeverageCallback__ReceiverMismatch();
    /// @notice Reverts when an unwind shortfall exceeds the borrower-specified cap.
    error MidnightLeverageCallback__ShortfallExceedsCap();
    /// @notice Reverts when a swap produces less than the borrower-specified minimum output.
    error MidnightLeverageCallback__SlippageExceeded();
    /// @notice Reverts when the router call fails.
    error MidnightLeverageCallback__SwapFailed();
    /// @notice Reverts when a callback attempts to use a router that is not allowlisted.
    error MidnightLeverageCallback__SwapRouterNotAllowed();

    /// @notice Sets whether a router may be used as a swap target.
    /// @param _router The swap router address to configure.
    /// @param _allowed Whether `_router` is allowed for swaps.
    function setIsAllowedSwapRouter(address _router, bool _allowed) external;

    /// @notice Returns the Midnight instance this callback accepts calls from.
    /// @return The configured Midnight instance.
    function getMidnight() external view returns (IMidnight);

    /// @notice Returns the Permit2 instance used for signature-based token pulls.
    /// @return The configured Permit2 instance.
    function getPermit2() external view returns (ISignatureTransfer);

    /// @notice Returns whether `_router` is allowed for callback swaps.
    /// @param _router The swap router to check.
    /// @return Whether `_router` is allowlisted.
    function isAllowedSwapRouter(address _router) external view returns (bool);

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
        returns (ISignatureTransfer.PermitTransferFrom memory, bytes32, string memory);

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
        returns (ISignatureTransfer.PermitTransferFrom memory, bytes32, string memory);
}
