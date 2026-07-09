// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { BaseTest } from "test/BaseTest.sol";

import { IMidnightLeverageCallback } from "src/interfaces/IMidnightLeverageCallback.sol";

import { Ownable } from "@openzeppelin-contracts-5.3.0/access/Ownable.sol";

contract AdminConfigTest is BaseTest {
    function testSetIsAllowedSwapRouterAllowsRouter() public {
        address router = makeAddr("router");

        vm.prank(s_owner);
        s_callback.setIsAllowedSwapRouter(router, true);

        assertTrue(s_callback.isAllowedSwapRouter(router));
    }

    function testSetIsAllowedSwapRouterDisallowsRouter() public {
        assertTrue(s_callback.isAllowedSwapRouter(address(s_router)));

        vm.prank(s_owner);
        s_callback.setIsAllowedSwapRouter(address(s_router), false);

        assertFalse(s_callback.isAllowedSwapRouter(address(s_router)));
    }

    function testSetIsAllowedSwapRouterRevertsWhenCallerNotOwner() public {
        address router = makeAddr("router");

        vm.prank(s_borrower);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, s_borrower));
        s_callback.setIsAllowedSwapRouter(router, true);
    }

    function testSetIsAllowedSwapRouterRevertsWhenRouterIsZeroAddress() public {
        vm.prank(s_owner);
        vm.expectRevert(IMidnightLeverageCallback.MidnightLeverageCallback__AddressZero.selector);
        s_callback.setIsAllowedSwapRouter(address(0), true);
    }
}
