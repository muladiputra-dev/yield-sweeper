// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import { Script, console2 } from "forge-std/Script.sol";
import { YieldSweeperVault } from "../src/Vault.sol";
import { YieldSweeperReactive } from "../src/YieldSweeperReactive.sol";
import { IPayable } from "reactive-lib/interfaces/IPayable.sol";

// ---------------------------------------------------------------------------
// Two-step deployment for the Yield Sweeper stack.
//
//   Step 1 (origin chain, e.g. Base Sepolia):
//       forge script script/Deploy.s.sol:DeployVault \
//         --rpc-url $BASE_SEPOLIA_RPC --private-key $PK --broadcast
//   Step 2 (Lasna):
//       forge script script/Deploy.s.sol:DeployReactive \
//         --rpc-url $LASNA_RPC --private-key $PK --broadcast
//   Step 3 (origin chain again — patch the callback sender):
//       cast send $VAULT "setCallbackSender(address)" $REACTIVE \
//         --rpc-url $BASE_SEPOLIA_RPC --private-key $PK
// ---------------------------------------------------------------------------

// --- addresses --------------------------------------------------------------
// Callback proxy address for the origin chain (unique per chain). For Base
// Sepolia the canonical proxy is 0x476F44b11F5C942c58f4c8E3d0300E5710743585.
address constant CALLBACK_PROXY_BASE_SEPOLIA = 0x476F44b11F5C942c58f4c8E3d0300E5710743585;
uint256 constant BASE_SEPOLIA_CHAIN_ID = 84532;
uint256 constant LASNA_CHAIN_ID = 5318007;

contract DeployVault is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address coldWallet = vm.envAddress("COLD_WALLET");
        vm.startBroadcast(deployerKey);

        YieldSweeperVault vault = new YieldSweeperVault(
            IPayable(payable(CALLBACK_PROXY_BASE_SEPOLIA)),
            address(0), // placeholder; patched after reactive deploy
            coldWallet
        );

        vm.stopBroadcast();
        console2.log("Vault deployed at:", address(vault));
    }
}

contract DeployReactive is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address vault = vm.envAddress("VAULT");
        address coldWallet = vm.envAddress("COLD_WALLET");
        vm.startBroadcast(deployerKey);

        YieldSweeperReactive reactive = new YieldSweeperReactive(
            BASE_SEPOLIA_CHAIN_ID,
            vault,
            coldWallet
        );

        vm.stopBroadcast();
        console2.log("Reactive deployed at:", address(reactive));
    }
}
