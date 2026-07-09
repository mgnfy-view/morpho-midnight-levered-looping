// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IMidnight } from "morpho-midnight-1.0.0/src/interfaces/IMidnight.sol";
import { IMidnightLeverageCallback } from "src/interfaces/IMidnightLeverageCallback.sol";

import { BaseTest } from "test/BaseTest.sol";

contract CloseLeverageTest is BaseTest {
    function testCloseFullRepayHappyPath() public {
        uint256 collateralIndex = _collateralIndex(address(s_collateralToken1));
        uint256 borrowUnits = 100e18;
        uint256 marginAmount = 50e18;
        uint256 collateralAmount = 150e18;
        uint256 repayUnits = 100e18;
        uint256 loanOut = 100e18;
        uint256 minLoanAssets = 100e18;
        uint256 maxRepayShortfall = 0;

        _open(s_lender, borrowUnits, marginAmount, collateralIndex, collateralAmount, collateralAmount);
        _close(
            repayUnits, collateralIndex, collateralAmount, loanOut, minLoanAssets, maxRepayShortfall, collateralAmount
        );

        assertEq(s_midnight.debt(s_id, s_borrower), 0);
        assertEq(s_midnight.collateral(s_id, s_borrower, collateralIndex), 0);
    }

    function testClosePartialRepayHappyPath() public {
        uint256 collateralIndex = _collateralIndex(address(s_collateralToken1));
        uint256 borrowUnits = 100e18;
        uint256 marginAmount = 50e18;
        uint256 collateralAmount = 150e18;
        uint256 repayUnits = 40e18;
        uint256 collateralToWithdraw = 50e18;
        uint256 loanOut = 40e18;
        uint256 minLoanAssets = 40e18;
        uint256 maxRepayShortfall = 0;
        uint256 expectedRemainingDebt = 60e18;
        uint256 expectedRemainingCollateral = 100e18;

        _open(s_lender, borrowUnits, marginAmount, collateralIndex, collateralAmount, collateralAmount);
        _close(
            repayUnits,
            collateralIndex,
            collateralToWithdraw,
            loanOut,
            minLoanAssets,
            maxRepayShortfall,
            collateralToWithdraw
        );

        assertEq(s_midnight.debt(s_id, s_borrower), expectedRemainingDebt);
        assertEq(s_midnight.collateral(s_id, s_borrower, collateralIndex), expectedRemainingCollateral);
        assertTrue(s_midnight.isHealthy(s_market, s_id, s_borrower));
    }

    function testCloseRevertsWhenCalledDirectly() public {
        vm.expectRevert(IMidnightLeverageCallback.MidnightLeverageCallback__OnlyMidnight.selector);
        s_callback.onRepay(bytes32(0), s_market, 0, s_borrower, hex"");
    }

    function testCloseRevertsWhenWithdrawWouldLeavePositionUnhealthy() public {
        uint256 collateralIndex = _collateralIndex(address(s_collateralToken1));
        uint256 borrowUnits = 100e18;
        uint256 marginAmount = 50e18;
        uint256 collateralAmount = 150e18;
        uint256 repayUnits = 10e18;
        uint256 collateralToWithdraw = 140e18;
        uint256 loanOut = 10e18;
        uint256 minLoanAssets = 10e18;
        uint256 maxRepayShortfall = 0;

        _open(s_lender, borrowUnits, marginAmount, collateralIndex, collateralAmount, collateralAmount);
        IMidnightLeverageCallback.CloseParams memory params = _closeParams(
            collateralIndex, collateralToWithdraw, loanOut, minLoanAssets, maxRepayShortfall, collateralToWithdraw
        );
        vm.expectRevert(IMidnight.UnhealthyBorrower.selector);
        vm.prank(s_borrower);
        s_midnight.repay(s_market, repayUnits, s_borrower, address(s_callback), abi.encode(params));
    }

    function testCloseRevertsWhenSlippageExceeded() public {
        uint256 collateralIndex = _collateralIndex(address(s_collateralToken1));
        uint256 borrowUnits = 100e18;
        uint256 marginAmount = 50e18;
        uint256 collateralAmount = 150e18;
        uint256 repayUnits = 100e18;
        uint256 loanOut = 99e18;
        uint256 minLoanAssets = 100e18;
        uint256 maxRepayShortfall = 1e18;

        _open(s_lender, borrowUnits, marginAmount, collateralIndex, collateralAmount, collateralAmount);
        IMidnightLeverageCallback.CloseParams memory params = _closeParams(
            collateralIndex, collateralAmount, loanOut, minLoanAssets, maxRepayShortfall, collateralAmount
        );
        vm.expectRevert(IMidnightLeverageCallback.MidnightLeverageCallback__SlippageExceeded.selector);
        vm.prank(s_borrower);
        s_midnight.repay(s_market, repayUnits, s_borrower, address(s_callback), abi.encode(params));
    }

    function testCloseRevertsWhenSwapRouterNotAllowed() public {
        uint256 collateralIndex = _collateralIndex(address(s_collateralToken1));
        uint256 borrowUnits = 100e18;
        uint256 marginAmount = 50e18;
        uint256 collateralAmount = 150e18;
        uint256 repayUnits = 100e18;
        uint256 loanOut = 100e18;
        uint256 minLoanAssets = 100e18;
        uint256 maxRepayShortfall = 0;

        _open(s_lender, borrowUnits, marginAmount, collateralIndex, collateralAmount, collateralAmount);
        vm.prank(s_owner);
        s_callback.setIsAllowedSwapRouter(address(s_router), false);
        IMidnightLeverageCallback.CloseParams memory params = _closeParams(
            collateralIndex, collateralAmount, loanOut, minLoanAssets, maxRepayShortfall, collateralAmount
        );
        vm.expectRevert(IMidnightLeverageCallback.MidnightLeverageCallback__SwapRouterNotAllowed.selector);
        vm.prank(s_borrower);
        s_midnight.repay(s_market, repayUnits, s_borrower, address(s_callback), abi.encode(params));
    }

    function testCloseShortfallWithinCapPullsBorrowerTopUp() public {
        uint256 collateralIndex = _collateralIndex(address(s_collateralToken1));
        uint256 borrowUnits = 100e18;
        uint256 marginAmount = 50e18;
        uint256 collateralAmount = 150e18;
        uint256 repayUnits = 100e18;
        uint256 loanOut = 95e18;
        uint256 minLoanAssets = 95e18;
        uint256 shortfallTopUp = 5e18;

        _open(s_lender, borrowUnits, marginAmount, collateralIndex, collateralAmount, collateralAmount);
        deal(address(s_loanToken), s_borrower, shortfallTopUp);
        _close(repayUnits, collateralIndex, collateralAmount, loanOut, minLoanAssets, shortfallTopUp, collateralAmount);

        assertEq(s_midnight.debt(s_id, s_borrower), 0);
        assertEq(s_loanToken.balanceOf(s_borrower), 0);
    }

    function testCloseUsesPermit2AuthorizationForShortfallPull() public {
        uint256 collateralIndex = _collateralIndex(address(s_collateralToken1));
        uint256 borrowUnits = 100e18;
        uint256 marginAmount = 50e18;
        uint256 collateralAmount = 150e18;
        uint256 repayUnits = 100e18;
        uint256 loanOut = 95e18;
        uint256 minLoanAssets = 95e18;
        uint256 maxRepayShortfall = 5e18;
        uint256 permitNonce = 2;

        _open(s_lender, borrowUnits, marginAmount, collateralIndex, collateralAmount, collateralAmount);
        deal(address(s_loanToken), s_borrower, maxRepayShortfall);
        vm.prank(s_borrower);
        s_loanToken.approve(address(s_callback), 0);
        IMidnightLeverageCallback.CloseParams memory params = _closeParams(
            collateralIndex, collateralAmount, loanOut, minLoanAssets, maxRepayShortfall, collateralAmount
        );
        params.auth = _signRepayAuthorization(params, maxRepayShortfall, permitNonce);
        vm.prank(s_borrower);
        s_midnight.repay(s_market, repayUnits, s_borrower, address(s_callback), abi.encode(params));

        assertEq(s_midnight.debt(s_id, s_borrower), 0);
        assertEq(s_loanToken.balanceOf(s_borrower), 0);
    }

    function testCloseRevertsWhenShortfallExceedsCap() public {
        uint256 collateralIndex = _collateralIndex(address(s_collateralToken1));
        uint256 borrowUnits = 100e18;
        uint256 marginAmount = 50e18;
        uint256 collateralAmount = 150e18;
        uint256 repayUnits = 100e18;
        uint256 loanOut = 95e18;
        uint256 minLoanAssets = 95e18;
        uint256 borrowerLoanBalance = 5e18;
        uint256 maxRepayShortfall = 4e18;

        _open(s_lender, borrowUnits, marginAmount, collateralIndex, collateralAmount, collateralAmount);
        deal(address(s_loanToken), s_borrower, borrowerLoanBalance);
        IMidnightLeverageCallback.CloseParams memory params = _closeParams(
            collateralIndex, collateralAmount, loanOut, minLoanAssets, maxRepayShortfall, collateralAmount
        );
        vm.expectRevert(IMidnightLeverageCallback.MidnightLeverageCallback__ShortfallExceedsCap.selector);
        vm.prank(s_borrower);
        s_midnight.repay(s_market, repayUnits, s_borrower, address(s_callback), abi.encode(params));
    }

    function testCloseRefundsExcessLoanAssets() public {
        uint256 collateralIndex = _collateralIndex(address(s_collateralToken1));
        uint256 borrowUnits = 100e18;
        uint256 marginAmount = 50e18;
        uint256 collateralAmount = 150e18;
        uint256 repayUnits = 100e18;
        uint256 loanOut = 110e18;
        uint256 minLoanAssets = 100e18;
        uint256 maxRepayShortfall = 0;
        uint256 expectedExcessLoanAssets = 10e18;

        _open(s_lender, borrowUnits, marginAmount, collateralIndex, collateralAmount, collateralAmount);
        deal(address(s_loanToken), s_borrower, 0);
        _close(
            repayUnits, collateralIndex, collateralAmount, loanOut, minLoanAssets, maxRepayShortfall, collateralAmount
        );

        assertEq(s_midnight.debt(s_id, s_borrower), 0);
        assertEq(s_loanToken.balanceOf(s_borrower), expectedExcessLoanAssets);
    }
}
