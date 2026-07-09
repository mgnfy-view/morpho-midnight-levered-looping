// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { CALLBACK_SUCCESS, ORACLE_PRICE_SCALE } from "morpho-midnight-1.0.0/src/libraries/ConstantsLib.sol";
import { IdLib } from "morpho-midnight-1.0.0/src/libraries/IdLib.sol";

import { BaseTest } from "test/BaseTest.sol";

contract InitializationTest is BaseTest {
    function testCallbackInitializedCorrectly() public view {
        assertEq(address(s_callback.getMidnight()), address(s_midnight));
        assertEq(address(s_callback.getPermit2()), address(s_permit2));
        assertEq(s_callback.owner(), s_owner);
        assertTrue(s_callback.isAllowedSwapRouter(address(s_router)));
    }
}
