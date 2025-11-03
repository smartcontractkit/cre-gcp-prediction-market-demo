// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import {SimpleMarket} from "../src/SimpleMarket.sol";

interface IERC20 {
    function approve(address spender, uint256 value) external returns (bool);
}

/// @notice Complete setup flow: Deploy → Create Market → Make Prediction
contract Setup is Script {
    // TODO @dev Ensure SimpleContract Address is correct
    address constant SIMPLE_MARKET = 0x5De80647572bE8B6a9ba1350CDf3dB9f95B4F266;

    // TODO @dev Replace with your USDC token address for target chain
    address constant PAYMENT_TOKEN = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;

    // TODO @dev Update market question as needed
    string constant QUESTION = "Will the Bulls beat the Knicks on 31 October 2025";

    // TODO @dev Change outcome: 1=No, 2=Yes
    uint256 constant OUTCOME = 2;

    // TODO @dev Adjust prediction amount (raw units, 1USDC = 1000000 with 6 decimals)
    uint256 constant AMOUNT = 1000000;

    /// Main flow: Deploy market, create market, make prediction
    function run() external returns (SimpleMarket, uint256) {
        uint256 pk = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(pk);

        // Step 1: access deployed contract
        SimpleMarket market = SimpleMarket(SIMPLE_MARKET);
        console2.log("SimpleMarket accessed at:", address(market));

        // Step 2: Create market
        uint256 marketId = market.newMarket(QUESTION);
        console2.log("Market created: id=", marketId);
        console2.log("Question:", QUESTION);

        // Step 3A: Approve USDC Spend
        IERC20(PAYMENT_TOKEN).approve(address(market), AMOUNT);
        console2.log("Approved SimpleMarket to Spend USDC amounting to :", AMOUNT);

        // Step 3B: Make prediction
        market.makePrediction(marketId, SimpleMarket.Outcome(OUTCOME), AMOUNT);
        console2.log("Market:", marketId);
        console2.log("Outcome: ", OUTCOME == 2 ? "Yes" : "No");
        console2.log("Amount: ", AMOUNT);

        // Step 4: fetch Prediction
        SimpleMarket.Prediction memory prediction = market.getPrediction(marketId);
        console2.log("Prediction Amount:", prediction.amount);
        console2.log("Prediction Outcome:", uint8(prediction.pred));
        console2.log("Prediction Claimed:", prediction.claimed ? 1 : 0);

        vm.stopBroadcast();

        return (market, marketId);
    }

    /// Helper: Log prediction details for a given market
    function getPrediction(uint256 marketId) external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        SimpleMarket market = SimpleMarket(SIMPLE_MARKET);

        SimpleMarket.Prediction memory prediction = market.getPrediction(marketId);
        console2.log("Prediction Amount:", prediction.amount);
        console2.log("Prediction Outcome:", uint8(prediction.pred));
        console2.log("Prediction Claimed:", prediction.claimed ? 1 : 0);

        vm.stopBroadcast();
    }

    /// Helper: Create market only
    function createMarket() external returns (uint256) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        SimpleMarket market = SimpleMarket(SIMPLE_MARKET);

        vm.startBroadcast(pk);
        uint256 marketId = market.newMarket(QUESTION);
        vm.stopBroadcast();

        console2.log("Market created: id=", marketId);

        return marketId;
    }

    /// Helper: Make prediction only (requires MARKET_ID env var)
    function makePrediction() external {
        uint256 marketId = vm.envUint("MARKET_ID");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        SimpleMarket market = SimpleMarket(SIMPLE_MARKET);

        vm.startBroadcast(pk);
        IERC20(PAYMENT_TOKEN).approve(address(market), AMOUNT);
        market.makePrediction(marketId, SimpleMarket.Outcome(OUTCOME), AMOUNT);
        vm.stopBroadcast();

        console2.log("Prediction placed:", marketId, OUTCOME, AMOUNT);
    }
}
