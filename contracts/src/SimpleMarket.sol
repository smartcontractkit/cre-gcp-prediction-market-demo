// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ReceiverTemplate } from "./interfaces/ReceiverTemplate.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title SimpleMarket
/// @notice A basic binary prediction market allowing users to stake ERC-20 tokens on Yes/No outcomes.
/// @dev Integrates with Chainlink Runtime Environment (CRE) through ReceiverTemplate. Used in pair with demo workflow to settle markets with Gemini.
contract SimpleMarket is ReceiverTemplate {
    using SafeERC20 for IERC20;

    // ===========================
    // ======== EVENTS ===========
    // ===========================

    /// @notice Emitted when a settlement is requested for a market.
    /// @param marketId The ID of the market to settle.
    /// @param question The market's question string.
    event SettlementRequested(
        uint256 indexed marketId,
        string question
    );

    /// @notice Emitted when a settlement response is received and processed.
    /// @param marketId The ID of the settled market.
    /// @param status The new status of the market after settlement.
    /// @param outcome The resolved outcome of the market.
    event SettlementResponse(
        uint256 indexed marketId,
        Status indexed status,
        Outcome indexed outcome
    );

    // ===========================
    // ======== ENUMS ============
    // ===========================

    /// @notice Possible outcomes for a market. Also serves as a user's chosen prediction.
    /// @dev `None` indicates no outcome yet or no prediction made, `Inconclusive` is used when AI response/confidence is insufficient. Users may only pass No or Yes.
    enum Outcome { None, No, Yes, Inconclusive }

    /// @notice Lifecycle status of a market.
    /// @dev Transitions: Open → SettlementRequested → Settled/NeedsManual
    enum Status { Open, SettlementRequested, Settled, NeedsManual }

    // ===========================
    // ======== ERRORS ===========
    // ===========================

    error MarketNotClosed(uint256 nowTs, uint256 closeTs);
    error StatusNotOpen(Status current);
    error SettlementNotRequested(Status current);
    error InvalidOutcome();
    error ManualSettlementNotAllowed(Status current);

    error MarketNotOpen(uint256 nowTs, uint256 closeTs);
    error AlreadyPredicted();
    error AmountZero();

    error NotSettledYet(Status current);
    error AlreadyClaimed();
    error IncorrectPrediction();
    error NoWinners();

    // ===========================
    // ======== STRUCTS ==========
    // ===========================

    /// @notice Represents a single prediction market instance.
    struct Market {
        string question;            // Market question (e.g. "The New York Yankees will win the 2009 world series.")
        uint256 marketOpen;         // Timestamp when the market opened
        uint256 marketClose;        // Timestamp when the market closes for predictions
        Status status;              // Current market status (Open, Settled, etc.)
        Outcome outcome;            // Final outcome of the market
        uint256 settledAt;          // Timestamp when settlement occurred
        string evidenceURI;         // Response ID of the Gemini request
        uint16 confidenceBps;       // Confidence level from Gemini (in basis points: 0–10000)
        uint256[2] predCounts;      // Count of predictions per side: [0]=NO, [1]=YES
        uint256[2] predTotals;      // Total token amount staked per side: [0]=NO, [1]=YES
    }

    /// @notice Represents a user's prediction in a given market.
    struct Prediction {
        uint256 amount;             // Amount of tokens staked
        Outcome pred;               // Chosen outcome (No/Yes)
        bool claimed;               // Whether the user has claimed their winnings
    }

    // ===========================
    // ======= STATE VARS ========
    // ===========================

    /// @notice Counter tracking the next market ID to assign.
    uint256 public nextMarketId;

    /// @notice Mapping from market ID to its Market data.
    mapping (uint256 => Market) public markets;

    /// @notice Mapping of predictions: marketId → user → Prediction struct.
    mapping (uint256 => mapping (address => Prediction)) predictions;

    /// @notice ERC-20 token used for staking and payouts.
    /// @dev Set at deployment and immutable thereafter.
    IERC20 public immutable paymentToken;

    // ===========================
    // ======== CONSTRUCTOR ======
    // ===========================

    /// @param token The address of the ERC-20 token used for market participation.
    constructor(address token) ReceiverTemplate() {
        paymentToken = IERC20(token);
    }

    // ===========================
    // ======== FUNCTIONS ========
    // ===========================

    /// @notice Create a new market with a 1 minute prediction window.
    /// @param question The question describing the market.
    /// @return The ID of the newly created market.
    function newMarket(string calldata question) public returns (uint256) {
        Market storage m = markets[nextMarketId++];
        m.question = question;
        m.marketOpen = block.timestamp;
        m.marketClose = block.timestamp + 3 minutes;
        return nextMarketId - 1;
    }

    /// @notice View details of a market.
    /// @param marketId The ID of the market to view.
    /// @return The full Market struct for the given ID.
    function getMarket(uint256 marketId) public view returns (Market memory) {
        return markets[marketId];
    }

    /// @notice Request (CRE) to settle a market.
    /// @dev Emits a SettlementRequested event for monitoring.
    /// @param marketId The ID of the market to settle.
    function requestSettlement(uint256 marketId) public {
        Market storage m = markets[marketId];
        if (m.marketClose > block.timestamp) revert MarketNotClosed(block.timestamp, m.marketClose);
        if (m.status != Status.Open) revert StatusNotOpen(m.status);

        m.status = Status.SettlementRequested;
        emit SettlementRequested(marketId, m.question);
    }

    /// @notice Helper function invoked by _processReport.
    /// @param marketId The ID of the market being settled.
    /// @param outcome The resolved market outcome.
    /// @param confidenceBps Gemini confidence score in basis points (0–10000).
    /// @param evidenceURI responseId from Gemini request
    function settleMarket(
        uint256 marketId,
        Outcome outcome,
        uint16 confidenceBps,
        string memory evidenceURI
    ) private {
        Market storage m = markets[marketId];
        if (m.status != Status.SettlementRequested) revert SettlementNotRequested(m.status);

        m.outcome = outcome;
        m.settledAt = block.timestamp;
        m.confidenceBps = confidenceBps;
        m.evidenceURI = evidenceURI;

        if (outcome == Outcome.Inconclusive) {
            m.status = Status.NeedsManual;
        } else {
            m.status = Status.Settled;
        }

        emit SettlementResponse(marketId, m.status, m.outcome);
    }

    /// @notice Used to manually settle markets that were set to NeedsManual due to inconclusive Gemini response.
    /// @param marketId The ID of the market being settled.
    /// @param outcome The resolved market outcome.
    function settleMarketManually(
        uint256 marketId,
        Outcome outcome
    ) public {
        Market storage m = markets[marketId];
        if (outcome != Outcome.No && outcome != Outcome.Yes) revert InvalidOutcome();
        if (m.status != Status.NeedsManual) revert ManualSettlementNotAllowed(m.status);

        m.outcome = outcome;
        m.settledAt = block.timestamp;
        m.status = Status.Settled;

        emit SettlementResponse(marketId, m.status, m.outcome);
    }

    /// @notice Internal hook to process settlement reports from the receiver template.
    /// @dev Decodes ABI-encoded data and calls settleMarket().
    /// @param report ABI-encoded (marketId, outcome(uint8), confidenceBps, responseId).
    function _processReport(bytes calldata report) internal override {
        (uint256 marketId, uint8 outcome, uint16 confidenceBps, string memory responseId) =
            abi.decode(report, (uint256, uint8, uint16, string));
        settleMarket(marketId, Outcome(outcome), confidenceBps, responseId);
    }

    /// @notice Returns the evidence URI for a given market.
    /// @param marketId The ID of the market.
    /// @return The constructed URI string.
    function getUri(uint256 marketId) public view returns (string memory) {
        return string.concat("http://localhost:3000/", markets[marketId].evidenceURI);
    }

    /// @notice Place a prediction on an open market.
    /// @param marketId The ID of the market.
    /// @param outcome The prediction (Yes or No).
    /// @param amount The amount of tokens to wager.
    function makePrediction(uint256 marketId, Outcome outcome, uint256 amount) public {
        Market storage m = markets[marketId];

        if (m.marketClose < block.timestamp) revert MarketNotOpen(block.timestamp, m.marketClose);
        if (m.status != Status.Open) revert StatusNotOpen(m.status);
        if (predictions[marketId][msg.sender].pred != Outcome.None) revert AlreadyPredicted();
        if (outcome != Outcome.No && outcome != Outcome.Yes) revert InvalidOutcome();
        if (amount == 0) revert AmountZero();

        // Pull tokens from the user (must be approved beforehand)
        paymentToken.safeTransferFrom(msg.sender, address(this), amount);

        predictions[marketId][msg.sender] = Prediction({
            amount: amount,
            pred: outcome,
            claimed: false
        });

        markets[marketId].predTotals[uint8(outcome) - 1] += amount;
        markets[marketId].predCounts[uint8(outcome) - 1]++;
    }

    /// @notice View the caller’s prediction for a given market.
    /// @param marketId The ID of the market.
    /// @return The Prediction struct belonging to the caller.
    function getPrediction(uint256 marketId) public view returns (Prediction memory) {
        return predictions[marketId][msg.sender];
    }

    /// @notice Claim winnings after a market is settled.
    /// @dev Distributes the total pool proportionally among correct predictors.
    /// @param marketId The ID of the settled market.
    function claimPrediction(uint256 marketId) public {
        Market storage m = markets[marketId];
        Prediction storage p = predictions[marketId][msg.sender];

        if (m.status != Status.Settled) revert NotSettledYet(m.status);
        if (p.claimed) revert AlreadyClaimed();
        if (m.outcome != p.pred) revert IncorrectPrediction();

        uint8 outcomeIndex = uint8(m.outcome);
        uint256 userStake = p.amount;
        uint256 totalPool = m.predTotals[0] + m.predTotals[1];
        uint256 winningTotal = m.predTotals[outcomeIndex - 1];
        if (winningTotal == 0) revert NoWinners();

        uint256 payoutAmount = (userStake * totalPool) / winningTotal;

        p.claimed = true;
        paymentToken.safeTransfer(msg.sender, payoutAmount);
    }
}
