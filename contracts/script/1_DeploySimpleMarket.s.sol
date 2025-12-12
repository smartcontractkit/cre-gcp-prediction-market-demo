// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import {SimpleMarket} from "../src/SimpleMarket.sol";

/// @notice Deploys a new SimpleMarket with the configured ERC20 payment token and CRE forwarder address.
/// @dev The forwarder address is hardcoded to the Sepolia testnet CRE forwarder (0x15fC6ae953E024d975e77382eEeC56A9101f9F88).
///      Update this address if deploying to a different network or using a different CRE setup.
contract DeploySimpleMarket is Script {
    function run() external returns (SimpleMarket market) {
        address token = vm.envAddress("PAYMENT_TOKEN");
        address forwarder = address(0x15fC6ae953E024d975e77382eEeC56A9101f9F88); // Sepolia CRE Forwarder
        uint256 pk = vm.envUint("PRIVATE_KEY"); // deployer EOA

        vm.startBroadcast(pk);
        market = new SimpleMarket(token);
        market.setForwarderAddress(forwarder);
        vm.stopBroadcast();

        console2.log("SimpleMarket deployed at:", address(market));
        console2.log("Payment token:", token);
        console2.log("CRE Forwarder:", forwarder);
    }
}