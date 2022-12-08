// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.16;

import {Script} from 'forge-std/Script.sol';

import {BotThis} from "../src/tokens/BotThis.sol";

/// @notice A very simple deployment script
contract Deploy is Script {
  /// @notice The main script entrypoint
  /// @return erc721 The deployed contract
  function run() external returns (BotThis erc721) {
    vm.startBroadcast();
    erc721 = new BotThis("BotThis", "BT", 10);
    vm.stopBroadcast();
  }
}
