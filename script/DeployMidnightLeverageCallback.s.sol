// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Script } from "forge-std/Script.sol";

import { IMidnight } from "morpho-midnight-1.0.0/src/interfaces/IMidnight.sol";
import { ISignatureTransfer } from "permit2-1.0.0/src/interfaces/ISignatureTransfer.sol";

import { MidnightLeverageCallback } from "src/MidnightLeverageCallback.sol";

/// @title DeployMidnightLeverageCallback
/// @author mgnfy-view
/// @notice Deploys the Midnight leverage callback contract.
contract DeployMidnightLeverageCallback is Script {
    struct Config {
        address midnight;
        address permit2;
        address initialOwner;
        uint256 privateKey;
    }

    /// @notice Deploys `MidnightLeverageCallback` using environment configuration.
    /// @return The deployed callback contract.
    function run() external returns (MidnightLeverageCallback) {
        Config memory config = _loadConfig();

        vm.startBroadcast(config.privateKey);
        MidnightLeverageCallback callback = new MidnightLeverageCallback(
            IMidnight(config.midnight), ISignatureTransfer(config.permit2), config.initialOwner
        );
        vm.stopBroadcast();

        return callback;
    }

    /// @dev Loads deployment configuration from environment variables.
    /// @return The deployment configuration.
    function _loadConfig() internal view returns (Config memory) {
        Config memory config = Config({
            midnight: vm.envAddress("MIDNIGHT"),
            permit2: vm.envAddress("PERMIT2"),
            initialOwner: vm.envAddress("INITIAL_OWNER"),
            privateKey: vm.envUint("PRIVATE_KEY")
        });

        return config;
    }
}
