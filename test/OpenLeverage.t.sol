// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IMidnight } from "morpho-midnight-1.0.0/src/interfaces/IMidnight.sol";
import { IMidnightLeverageCallback } from "src/interfaces/IMidnightLeverageCallback.sol";

import { Offer } from "morpho-midnight-1.0.0/src/interfaces/IMidnight.sol";
import { BaseTest } from "test/BaseTest.sol";

import { MockSwapRouter } from "test/mocks/MockSwapRouter.sol";

contract OpenLeverageTest is BaseTest {
    function testOpenSingleCollateralHappyPath() public {
        uint256 collateralIndex = _collateralIndex(address(s_collateralToken1));
        uint256 borrowUnits = 100e18;
        uint256 marginAmount = 50e18;
        uint256 collateralAmount = 150e18;

        _open(s_lender, borrowUnits, marginAmount, collateralIndex, collateralAmount, collateralAmount);

        assertEq(s_midnight.debt(s_id, s_borrower), borrowUnits);
        assertEq(s_midnight.collateral(s_id, s_borrower, collateralIndex), collateralAmount);
        assertTrue(s_midnight.isHealthy(s_market, s_id, s_borrower));
    }

    function testOpenCanPartiallyFillLargerOffer() public {
        uint256 collateralIndex = _collateralIndex(address(s_collateralToken1));
        uint256 offerMaxUnits = 200e18;
        uint256 borrowUnits = 100e18;
        uint256 marginAmount = 50e18;
        uint256 collateralAmount = 150e18;
        Offer memory offer = _lenderOffer(s_lender, offerMaxUnits);

        deal(address(s_loanToken), s_lender, offerMaxUnits);
        deal(address(s_loanToken), s_borrower, marginAmount);
        IMidnightLeverageCallback.OpenParams memory params =
            _openParams(marginAmount, collateralIndex, collateralAmount, collateralAmount, collateralAmount);
        vm.prank(s_borrower);
        s_midnight.take(
            offer, hex"", borrowUnits, s_borrower, address(s_callback), address(s_callback), abi.encode(params)
        );

        assertEq(s_midnight.debt(s_id, s_borrower), borrowUnits);
        assertEq(s_midnight.collateral(s_id, s_borrower, collateralIndex), collateralAmount);
        assertEq(s_midnight.consumed(s_lender, offer.group), borrowUnits);
        assertTrue(s_midnight.isHealthy(s_market, s_id, s_borrower));
    }

    function testOpenSequentialTakesForDifferentCollaterals() public {
        uint256 collateralIndex1 = _collateralIndex(address(s_collateralToken1));
        uint256 collateralIndex2 = _collateralIndex(address(s_collateralToken2));
        uint256 borrowUnits = 100e18;
        uint256 marginAmount = 50e18;
        uint256 collateralAmount = 150e18;
        uint256 expectedTotalBorrowUnits = 200e18;

        _open(s_lender, borrowUnits, marginAmount, collateralIndex1, collateralAmount, collateralAmount);
        _open(s_otherLender, borrowUnits, marginAmount, collateralIndex2, collateralAmount, collateralAmount);

        assertEq(s_midnight.debt(s_id, s_borrower), expectedTotalBorrowUnits);
        assertEq(s_midnight.collateral(s_id, s_borrower, collateralIndex1), collateralAmount);
        assertEq(s_midnight.collateral(s_id, s_borrower, collateralIndex2), collateralAmount);
        assertTrue(s_midnight.isHealthy(s_market, s_id, s_borrower));
    }

    function testOpenSequentialTakesAcrossOffersForSameCollateral() public {
        uint256 collateralIndex = _collateralIndex(address(s_collateralToken1));
        uint256 firstBorrowUnits = 60e18;
        uint256 firstMarginAmount = 30e18;
        uint256 firstCollateralAmount = 90e18;
        uint256 secondBorrowUnits = 40e18;
        uint256 secondMarginAmount = 20e18;
        uint256 secondCollateralAmount = 60e18;
        uint256 expectedBorrowUnits = 100e18;
        uint256 expectedCollateralAmount = 150e18;

        _open(
            s_lender, firstBorrowUnits, firstMarginAmount, collateralIndex, firstCollateralAmount, firstCollateralAmount
        );
        _open(
            s_otherLender,
            secondBorrowUnits,
            secondMarginAmount,
            collateralIndex,
            secondCollateralAmount,
            secondCollateralAmount
        );

        assertEq(s_midnight.debt(s_id, s_borrower), expectedBorrowUnits);
        assertEq(s_midnight.collateral(s_id, s_borrower, collateralIndex), expectedCollateralAmount);
        assertTrue(s_midnight.isHealthy(s_market, s_id, s_borrower));
    }

    function testOpenRevertsWhenCalledDirectly() public {
        vm.expectRevert(IMidnightLeverageCallback.MidnightLeverageCallback__OnlyMidnight.selector);
        s_callback.onSell(bytes32(0), s_market, 0, 0, 0, s_borrower, address(s_callback), hex"");
    }

    function testOpenRevertsWhenReceiverMismatch() public {
        uint256 collateralIndex = _collateralIndex(address(s_collateralToken1));
        uint256 borrowUnits = 100e18;
        uint256 marginAmount = 50e18;
        uint256 collateralAmount = 150e18;
        Offer memory offer = _lenderOffer(s_lender, borrowUnits);

        deal(address(s_loanToken), s_lender, borrowUnits);
        IMidnightLeverageCallback.OpenParams memory params =
            _openParams(marginAmount, collateralIndex, collateralAmount, collateralAmount, collateralAmount);
        vm.expectRevert(IMidnightLeverageCallback.MidnightLeverageCallback__ReceiverMismatch.selector);
        vm.prank(s_borrower);
        s_midnight.take(offer, hex"", borrowUnits, s_borrower, s_borrower, address(s_callback), abi.encode(params));
    }

    function testOpenRevertsWhenSwapFails() public {
        uint256 collateralIndex = _collateralIndex(address(s_collateralToken1));
        uint256 borrowUnits = 100e18;
        uint256 marginAmount = 50e18;
        uint256 collateralAmount = 150e18;

        Offer memory offer = _lenderOffer(s_lender, borrowUnits);
        deal(address(s_loanToken), s_lender, borrowUnits);
        deal(address(s_loanToken), s_borrower, marginAmount);
        IMidnightLeverageCallback.OpenParams memory params =
            _openParams(marginAmount, collateralIndex, collateralAmount, collateralAmount, collateralAmount);
        params.swapCalldata = abi.encodeCall(MockSwapRouter.revertSwap, ());
        vm.expectRevert(IMidnightLeverageCallback.MidnightLeverageCallback__SwapFailed.selector);
        vm.prank(s_borrower);
        s_midnight.take(
            offer, hex"", borrowUnits, s_borrower, address(s_callback), address(s_callback), abi.encode(params)
        );
    }

    function testOpenRevertsWhenSwapRouterNotAllowed() public {
        uint256 collateralIndex = _collateralIndex(address(s_collateralToken1));
        uint256 borrowUnits = 100e18;
        uint256 marginAmount = 50e18;
        uint256 collateralAmount = 150e18;

        vm.prank(s_owner);
        s_callback.setIsAllowedSwapRouter(address(s_router), false);
        Offer memory offer = _lenderOffer(s_lender, borrowUnits);
        deal(address(s_loanToken), s_lender, borrowUnits);
        IMidnightLeverageCallback.OpenParams memory params =
            _openParams(marginAmount, collateralIndex, collateralAmount, collateralAmount, collateralAmount);
        vm.expectRevert(IMidnightLeverageCallback.MidnightLeverageCallback__SwapRouterNotAllowed.selector);
        vm.prank(s_borrower);
        s_midnight.take(
            offer, hex"", borrowUnits, s_borrower, address(s_callback), address(s_callback), abi.encode(params)
        );
    }

    function testOpenUsesPermit2AuthorizationForMarginPull() public {
        uint256 collateralIndex = _collateralIndex(address(s_collateralToken1));
        uint256 borrowUnits = 100e18;
        uint256 marginAmount = 50e18;
        uint256 collateralAmount = 150e18;
        uint256 permitNonce = 1;
        Offer memory offer = _lenderOffer(s_lender, borrowUnits);
        deal(address(s_loanToken), s_lender, borrowUnits);
        deal(address(s_loanToken), s_borrower, marginAmount);

        vm.prank(s_borrower);
        s_loanToken.approve(address(s_callback), 0);
        IMidnightLeverageCallback.OpenParams memory params =
            _openParams(marginAmount, collateralIndex, collateralAmount, collateralAmount, collateralAmount);
        params.auth = _signMarginAuthorization(params, marginAmount, permitNonce);
        vm.prank(s_borrower);
        s_midnight.take(
            offer, hex"", borrowUnits, s_borrower, address(s_callback), address(s_callback), abi.encode(params)
        );

        assertEq(s_midnight.debt(s_id, s_borrower), borrowUnits);
        assertEq(s_midnight.collateral(s_id, s_borrower, collateralIndex), collateralAmount);
    }

    function testOpenRevertsWhenSlippageExceeded() public {
        uint256 collateralIndex = _collateralIndex(address(s_collateralToken1));
        uint256 borrowUnits = 100e18;
        uint256 marginAmount = 50e18;
        uint256 collateralOut = 149e18;
        uint256 minCollateralAssets = 150e18;

        Offer memory offer = _lenderOffer(s_lender, borrowUnits);
        deal(address(s_loanToken), s_lender, borrowUnits);
        deal(address(s_loanToken), s_borrower, marginAmount);
        IMidnightLeverageCallback.OpenParams memory params =
            _openParams(marginAmount, collateralIndex, collateralOut, minCollateralAssets, minCollateralAssets);
        vm.expectRevert(IMidnightLeverageCallback.MidnightLeverageCallback__SlippageExceeded.selector);
        vm.prank(s_borrower);
        s_midnight.take(
            offer, hex"", borrowUnits, s_borrower, address(s_callback), address(s_callback), abi.encode(params)
        );
    }

    function testOpenRevertsWithoutMarginApproval() public {
        uint256 collateralIndex = _collateralIndex(address(s_collateralToken1));
        uint256 borrowUnits = 100e18;
        uint256 marginAmount = 50e18;
        uint256 collateralAmount = 150e18;

        vm.prank(s_borrower);
        s_loanToken.approve(address(s_callback), 0);
        Offer memory offer = _lenderOffer(s_lender, borrowUnits);
        deal(address(s_loanToken), s_lender, borrowUnits);
        deal(address(s_loanToken), s_borrower, marginAmount);
        IMidnightLeverageCallback.OpenParams memory params =
            _openParams(marginAmount, collateralIndex, collateralAmount, collateralAmount, collateralAmount);
        vm.expectRevert();
        vm.prank(s_borrower);
        s_midnight.take(
            offer, hex"", borrowUnits, s_borrower, address(s_callback), address(s_callback), abi.encode(params)
        );
    }

    function testOpenRevertsWithoutMidnightAuthorization() public {
        uint256 collateralIndex = _collateralIndex(address(s_collateralToken1));
        uint256 borrowUnits = 100e18;
        uint256 marginAmount = 50e18;
        uint256 collateralAmount = 150e18;

        vm.prank(s_borrower);
        s_midnight.setIsAuthorized(address(s_callback), false, s_borrower);
        Offer memory offer = _lenderOffer(s_lender, borrowUnits);
        deal(address(s_loanToken), s_lender, borrowUnits);
        deal(address(s_loanToken), s_borrower, marginAmount);
        IMidnightLeverageCallback.OpenParams memory params =
            _openParams(marginAmount, collateralIndex, collateralAmount, collateralAmount, collateralAmount);
        vm.expectRevert(IMidnight.Unauthorized.selector);
        vm.prank(s_borrower);
        s_midnight.take(
            offer, hex"", borrowUnits, s_borrower, address(s_callback), address(s_callback), abi.encode(params)
        );
    }

    function testOpenRevertsWhenFinalPositionUnhealthy() public {
        uint256 collateralIndex = _collateralIndex(address(s_collateralToken1));
        uint256 borrowUnits = 100e18;
        uint256 marginAmount = 0;
        uint256 dustCollateralAmount = 1e18;

        Offer memory offer = _lenderOffer(s_lender, borrowUnits);
        deal(address(s_loanToken), s_lender, borrowUnits);
        IMidnightLeverageCallback.OpenParams memory params =
            _openParams(marginAmount, collateralIndex, dustCollateralAmount, dustCollateralAmount, borrowUnits);
        vm.expectRevert(IMidnight.SellerIsLiquidatable.selector);
        vm.prank(s_borrower);
        s_midnight.take(
            offer, hex"", borrowUnits, s_borrower, address(s_callback), address(s_callback), abi.encode(params)
        );

        assertEq(s_midnight.debt(s_id, s_borrower), 0);
        assertEq(s_midnight.collateral(s_id, s_borrower, collateralIndex), 0);
    }

    function testOpenRefundsAllRemainingLoanTokenBalance() public {
        uint256 collateralIndex = _collateralIndex(address(s_collateralToken1));
        uint256 borrowUnits = 100e18;
        uint256 marginAmount = 50e18;
        uint256 collateralAmount = 150e18;
        uint256 amountUsedBySwap = 149e18;
        uint256 callbackPrefundedLoanBalance = 7e18;
        uint256 expectedBorrowerLoanRefund = 8e18;
        deal(address(s_loanToken), address(s_callback), callbackPrefundedLoanBalance);

        _open(
            s_lender, borrowUnits, marginAmount, collateralIndex, collateralAmount, amountUsedBySwap, amountUsedBySwap
        );

        assertEq(s_loanToken.balanceOf(address(s_callback)), 0);
        assertEq(s_loanToken.balanceOf(s_borrower), expectedBorrowerLoanRefund);
    }
}
