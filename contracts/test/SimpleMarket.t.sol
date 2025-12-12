// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {SimpleMarket} from "../src/SimpleMarket.sol";
import {MockUSDC} from "../src/mock/usdc.sol";

/**
 * @title SimpleMarketTest
 * @notice Foundry tests for the SimpleMarket contract, which implements a binary
 *         prediction market using an ERC20-compatible token such as USDC.
 *
 * @dev
 *  This test suite verifies:
 *   - Market creation and field initialization
 *   - Prediction placement and validation
 *   - Settlement requests (including timing & status gating)
 *   - CRE-based and manual settlement flows
 *   - Claim logic for payouts and revert paths
 *
 *  The tests are designed to be modular and independent, with clear state setup and
 *  cleanup per test via Foundry’s `setUp()` hook.
 */
contract SimpleMarketTest is Test {
    MockUSDC internal token;
    SimpleMarket internal market;

    // Test participants
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal forwarderAddress = address(0x15fC6ae953E024d975e77382eEeC56A9101f9F88);

    // Mock USDC uses 6 decimals to match the real token
    uint256 internal constant ONE_USDC = 1e6;

    // Events from SimpleMarket used for validation with `vm.expectEmit`
    event SettlementRequested(uint256 indexed marketId, string question);
    event SettlementResponse(
        uint256 indexed marketId, SimpleMarket.Status indexed status, SimpleMarket.Outcome indexed outcome
    );

    /**
     * @notice Deploys contracts and configures token balances and approvals before each test.
     */
    function setUp() public {
        // Deploy a mock ERC20 and the SimpleMarket contract
        token = new MockUSDC(1_000_000 * 1e6);
        market = new SimpleMarket(address(token));
        market.setForwarderAddress(forwarderAddress);

        // Fund each participant with 1,000 tokens
        token.transfer(alice, 1_000 * ONE_USDC);
        token.transfer(bob, 1_000 * ONE_USDC);
        token.transfer(carol, 1_000 * ONE_USDC);

        // Grant unlimited allowances to the SimpleMarket contract for testing convenience
        vm.startPrank(alice);
        token.approve(address(market), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        token.approve(address(market), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(carol);
        token.approve(address(market), type(uint256).max);
        vm.stopPrank();
    }

    // ================================================================
    //                         MARKET CREATION
    // ================================================================

    /**
     * @notice Verifies a new market is initialized correctly:
     *         - ID starts at 0
     *         - Status is Open
     *         - Outcome is None
     *         - Close time is open time + 1 hour
     */
    function test_newMarket_initializesFields() public {
        uint256 id = market.newMarket("Will ETH close above $2000?");
        assertEq(id, 0);

        (string memory q, uint256 open, uint256 close, uint8 status, uint8 outcome,,,,,) = _readMarket(id);
        assertEq(q, "Will ETH close above $2000?");
        assertEq(status, uint8(SimpleMarket.Status.Open));
        assertEq(outcome, uint8(SimpleMarket.Outcome.None));
        assertEq(close, open + 3 minutes);
    }

    // ================================================================
    //                           PREDICTIONS
    // ================================================================

    /**
     * @notice Happy-path test confirming that making predictions updates
     *         per-side counts and totals.
     */
    function test_makePrediction_updatesTotalsAndCounts() public {
        uint256 id = market.newMarket("Q");

        // Alice bets YES with 10 tokens
        vm.prank(alice);
        market.makePrediction(id, SimpleMarket.Outcome.Yes, 10 * ONE_USDC);

        // Bob bets NO with 5 tokens
        vm.prank(bob);
        market.makePrediction(id, SimpleMarket.Outcome.No, 5 * ONE_USDC);

        // Verify internal accounting
        SimpleMarket.Market memory m = market.getMarket(id);
        assertEq(m.predCounts[0], 1);
        assertEq(m.predCounts[1], 1);
        assertEq(m.predTotals[0], 5 * ONE_USDC);
        assertEq(m.predTotals[1], 10 * ONE_USDC);
    }

    /**
     * @notice Ensures invalid outcomes (Inconclusive) revert correctly
     *         via custom error `InvalidOutcome`.
     */
    function test_makePrediction_reverts_invalidOutcome() public {
        uint256 id = market.newMarket("Q");
        vm.prank(alice);
        vm.expectRevert(SimpleMarket.InvalidOutcome.selector);
        market.makePrediction(id, SimpleMarket.Outcome.Inconclusive, 1);
    }

    /**
     * @notice Prevents a user from predicting more than once per market.
     *         Validates the `AlreadyPredicted` custom error.
     */
    function test_makePrediction_reverts_twice() public {
        uint256 id = market.newMarket("Q");
        vm.startPrank(alice);
        market.makePrediction(id, SimpleMarket.Outcome.Yes, 1);
        vm.expectRevert(SimpleMarket.AlreadyPredicted.selector);
        market.makePrediction(id, SimpleMarket.Outcome.Yes, 1);
        vm.stopPrank();
    }

    /**
     * @notice Ensures predictions cannot be made after market close.
     *         Verifies `MarketNotOpen` custom error with timestamp args.
     */
    function test_makePrediction_reverts_afterClose() public {
        uint256 id = market.newMarket("Q");
        vm.warp(block.timestamp + 3 minutes + 1); // move past close time

        SimpleMarket.Market memory m = market.getMarket(id);
        uint256 nowTs = block.timestamp;
        uint256 closeTs = m.marketClose;

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SimpleMarket.MarketNotOpen.selector, nowTs, closeTs));
        market.makePrediction(id, SimpleMarket.Outcome.Yes, 1);
    }

    // ================================================================
    //                        SETTLEMENT REQUEST
    // ================================================================

    /**
     * @notice Verifies successful settlement request:
     *         - Emits `SettlementRequested`
     *         - Status updates to SettlementRequested
     */
    function test_requestSettlement_emits_and_setsStatus() public {
        uint256 id = market.newMarket("Q");
        vm.warp(block.timestamp + 3 minutes + 1);

        vm.expectEmit();
        emit SettlementRequested(id, "Q");
        market.requestSettlement(id);

        SimpleMarket.Market memory m = market.getMarket(id);
        assertEq(uint8(m.status), uint8(SimpleMarket.Status.SettlementRequested));
    }

    /**
     * @notice Reverts when requesting settlement before close time.
     *         Validates `MarketNotClosed` custom error and timestamp args.
     */
    function test_requestSettlement_reverts_ifOpenWindow() public {
        uint256 id = market.newMarket("Q");
        SimpleMarket.Market memory m = market.getMarket(id);
        vm.expectRevert(abi.encodeWithSelector(SimpleMarket.MarketNotClosed.selector, block.timestamp, m.marketClose));
        market.requestSettlement(id);
    }

    /**
     * @notice Reverts when attempting to request settlement while
     *         the market is not Open (e.g. already requested).
     */
    function test_requestSettlement_reverts_ifNotOpenStatus() public {
        uint256 id = market.newMarket("Q");
        vm.warp(block.timestamp + 3 minutes + 1);
        market.requestSettlement(id); // First time works

        vm.expectRevert(
            abi.encodeWithSelector(SimpleMarket.StatusNotOpen.selector, SimpleMarket.Status.SettlementRequested)
        );
        market.requestSettlement(id);
    }

    // ================================================================
    //                       SETTLEMENT EXECUTION
    // ================================================================

    /**
     * @notice Verifies that direct settlement sets fields correctly
     *         and emits the expected `SettlementResponse` event.
     */
    function test_settleMarket_setsFields_andEmits() public {
        uint256 id = _prepareAndRequestSettlement("Q");

        vm.expectEmit();
        emit SettlementResponse(id, SimpleMarket.Status.Settled, SimpleMarket.Outcome.Yes);

        vm.prank(forwarderAddress);
        market.onReport("", abi.encode(id, SimpleMarket.Outcome.Yes, 9_500, "evidence-123"));

        SimpleMarket.Market memory m = market.getMarket(id);
        assertEq(uint8(m.status), uint8(SimpleMarket.Status.Settled));
        assertEq(uint8(m.outcome), uint8(SimpleMarket.Outcome.Yes));
        assertGt(m.settledAt, 0);
        assertEq(m.evidenceURI, "evidence-123");
        assertEq(m.confidenceBps, 9_500);

        // The URI helper adds a static prefix
        string memory full = market.getUri(id);
        assertEq(full, string.concat("http://localhost:3000/", "evidence-123"));
    }

    /**
     * @notice Simulates an oracle callback through `onReport()`,
     *         verifying decoding and settlement flow.
     */
    function test_onReport_decodes_and_settles() public {
        uint256 id = _prepareAndRequestSettlement("Report path");
        bytes memory ignored = "";
        bytes memory report = abi.encode(id, uint8(SimpleMarket.Outcome.No), uint16(8_000), "resp-42");

        vm.expectEmit();
        emit SettlementResponse(id, SimpleMarket.Status.Settled, SimpleMarket.Outcome.No);

        vm.prank(forwarderAddress);
        market.onReport(ignored, report);

        SimpleMarket.Market memory m = market.getMarket(id);
        assertEq(uint8(m.status), uint8(SimpleMarket.Status.Settled));
        assertEq(uint8(m.outcome), uint8(SimpleMarket.Outcome.No));
        assertEq(m.evidenceURI, "resp-42");
        assertEq(m.confidenceBps, 8_000);
    }

    // ================================================================
    //                     MANUAL SETTLEMENT FLOW
    // ================================================================

    /**
     * @notice If automated settlement is Inconclusive, the market moves to NeedsManual.
     *         A manual follow-up now FINALIZES the market (status = Settled) and emits
     *         SettlementResponse with status Settled.
     */
    function test_inconclusive_then_manual_settlement() public {
        uint256 id = _prepareAndRequestSettlement("Manual path");

        // Step 1: Inconclusive → status becomes NeedsManual
        vm.expectEmit();
        emit SettlementResponse(id, SimpleMarket.Status.NeedsManual, SimpleMarket.Outcome.Inconclusive);

        vm.prank(forwarderAddress);
        market.onReport("", abi.encode(id, SimpleMarket.Outcome.Inconclusive, 1_000, "resp-0"));

        SimpleMarket.Market memory m1 = market.getMarket(id);
        assertEq(uint8(m1.status), uint8(SimpleMarket.Status.NeedsManual));
        assertEq(uint8(m1.outcome), uint8(SimpleMarket.Outcome.Inconclusive));

        // Step 2: Manual settlement NOW finalizes the market (status = Settled)
        vm.expectEmit();
        emit SettlementResponse(id, SimpleMarket.Status.Settled, SimpleMarket.Outcome.Yes);
        market.settleMarketManually(id, SimpleMarket.Outcome.Yes);

        SimpleMarket.Market memory m2 = market.getMarket(id);
        assertEq(uint8(m2.status), uint8(SimpleMarket.Status.Settled)); // updated expectation
        assertEq(uint8(m2.outcome), uint8(SimpleMarket.Outcome.Yes));

        // Step 3: Claim attempt by a non-participant now fails for a different reason:
        //         user didn't predict the winning side → IncorrectPrediction
        vm.prank(alice);
        vm.expectRevert(SimpleMarket.IncorrectPrediction.selector);
        market.claimPrediction(id);
    }

    /**
     * @notice Ensures manual settlement only allows Yes/No outcomes.
     */
    function test_settleMarketManually_reverts_when_invalidOutcome() public {
        uint256 id = _prepareAndRequestSettlement("Manual invalid");
        vm.prank(forwarderAddress);
        market.onReport("", abi.encode(id, SimpleMarket.Outcome.Inconclusive, 1, "x"));
        vm.expectRevert(SimpleMarket.InvalidOutcome.selector);
        market.settleMarketManually(id, SimpleMarket.Outcome.Inconclusive);
    }

    /**
     * @notice Ensures manual settlement cannot occur if status != NeedsManual.
     */
    function test_settleMarketManually_reverts_when_wrongStatus() public {
        uint256 id = _prepareAndRequestSettlement("Manual wrong");
        vm.expectRevert(
            abi.encodeWithSelector(
                SimpleMarket.ManualSettlementNotAllowed.selector, SimpleMarket.Status.SettlementRequested
            )
        );
        market.settleMarketManually(id, SimpleMarket.Outcome.No);
    }

    // ================================================================
    //                         CLAIMS & PAYOUTS
    // ================================================================

    /**
     * @notice Tests a simple case where only one side wins.
     *         YES=100, NO=50 → Alice wins full 150.
     */
    function test_claim_fullPayout_singleWinner() public {
        uint256 id = market.newMarket("Q");
        vm.prank(alice);
        market.makePrediction(id, SimpleMarket.Outcome.Yes, 100 * ONE_USDC);
        vm.prank(bob);
        market.makePrediction(id, SimpleMarket.Outcome.No, 50 * ONE_USDC);

        vm.warp(block.timestamp + 3 minutes + 1);
        market.requestSettlement(id);
        vm.prank(forwarderAddress);
        market.onReport("", abi.encode(id, SimpleMarket.Outcome.Yes, 9_000, "ev"));

        uint256 aliceBefore = token.balanceOf(alice);
        uint256 bobBefore = token.balanceOf(bob);

        vm.prank(alice);
        market.claimPrediction(id);

        // Alice gets full pool, Bob gets nothing
        assertEq(token.balanceOf(alice), aliceBefore + 150 * ONE_USDC);
        assertEq(token.balanceOf(bob), bobBefore);
    }

    /**
     * @notice Tests proportional payout for multiple winners.
     *         YES side (100 total): Alice 60, Carol 40 → pool 200
     *         Payouts: Alice 120, Carol 80
     */
    function test_claim_proportionalSplit_multipleWinners() public {
        uint256 id = market.newMarket("Q");
        vm.prank(alice);
        market.makePrediction(id, SimpleMarket.Outcome.Yes, 60 * ONE_USDC);
        vm.prank(carol);
        market.makePrediction(id, SimpleMarket.Outcome.Yes, 40 * ONE_USDC);
        vm.prank(bob);
        market.makePrediction(id, SimpleMarket.Outcome.No, 100 * ONE_USDC);

        vm.warp(block.timestamp + 3 minutes + 1);
        market.requestSettlement(id);
        vm.prank(forwarderAddress);
        market.onReport("", abi.encode(id, SimpleMarket.Outcome.Yes, 9_000, "ev"));

        uint256 aliceBefore = token.balanceOf(alice);
        uint256 carolBefore = token.balanceOf(carol);

        vm.prank(alice);
        market.claimPrediction(id);
        vm.prank(carol);
        market.claimPrediction(id);

        assertEq(token.balanceOf(alice), aliceBefore + 120 * ONE_USDC);
        assertEq(token.balanceOf(carol), carolBefore + 80 * ONE_USDC);
    }

    /**
     * @notice Ensures losers cannot claim rewards.
     *         Verifies `IncorrectPrediction` custom error.
     */
    function test_claim_reverts_incorrectPrediction() public {
        uint256 id = market.newMarket("Q");
        vm.prank(bob);
        market.makePrediction(id, SimpleMarket.Outcome.No, 10 * ONE_USDC);

        vm.warp(block.timestamp + 3 minutes + 1);
        market.requestSettlement(id);
        vm.prank(forwarderAddress);
        market.onReport("", abi.encode(id, SimpleMarket.Outcome.Yes, 9_000, "ev"));

        vm.prank(bob);
        vm.expectRevert(SimpleMarket.IncorrectPrediction.selector);
        market.claimPrediction(id);
    }

    /**
     * @notice Ensures users can only claim once per winning prediction.
     *         Validates `AlreadyClaimed` custom error.
     */
    function test_claim_reverts_twice() public {
        uint256 id = market.newMarket("Q");
        vm.prank(alice);
        market.makePrediction(id, SimpleMarket.Outcome.Yes, 10 * ONE_USDC);

        vm.warp(block.timestamp + 3 minutes + 1);
        market.requestSettlement(id);
        vm.prank(forwarderAddress);
        market.onReport("", abi.encode(id, SimpleMarket.Outcome.Yes, 9_000, "ev"));

        vm.startPrank(alice);
        market.claimPrediction(id);
        vm.expectRevert(SimpleMarket.AlreadyClaimed.selector);
        market.claimPrediction(id);
        vm.stopPrank();
    }

    /**
     * @notice Ensures that when no participants predicted the winning side,
     *         the contract reverts appropriately.
     */
    function test_claim_reverts_noWinners() public {
        uint256 id = market.newMarket("Q");
        vm.prank(bob);
        market.makePrediction(id, SimpleMarket.Outcome.No, 10 * ONE_USDC);

        vm.warp(block.timestamp + 3 minutes + 1);
        market.requestSettlement(id);
        vm.prank(forwarderAddress);
        market.onReport("", abi.encode(id, SimpleMarket.Outcome.Yes, 9_000, "ev"));

        vm.prank(alice);
        vm.expectRevert(SimpleMarket.IncorrectPrediction.selector);
        market.claimPrediction(id);
    }

    /**
     * @notice Ensures claiming before a market is settled reverts.
     *         Validates `NotSettledYet` custom error with status Open.
     */
    function test_claim_reverts_beforeSettlement() public {
        uint256 id = market.newMarket("Q");
        vm.prank(alice);
        market.makePrediction(id, SimpleMarket.Outcome.Yes, 10 * ONE_USDC);

        vm.expectRevert(abi.encodeWithSelector(SimpleMarket.NotSettledYet.selector, SimpleMarket.Status.Open));
        vm.prank(alice);
        market.claimPrediction(id);
    }

    // ================================================================
    //                           HELPERS
    // ================================================================

    /// @dev Opens a new market, advances time beyond close, and requests settlement.
    function _prepareAndRequestSettlement(string memory question) internal returns (uint256 id) {
        id = market.newMarket(question);
        vm.warp(block.timestamp + 3 minutes + 1);
        market.requestSettlement(id);
    }

    /// @dev Utility to unpack all fields of a market struct for assertion convenience.
    function _readMarket(uint256 id)
        internal
        view
        returns (
            string memory question,
            uint256 open,
            uint256 close,
            uint8 status,
            uint8 outcome,
            uint256 settledAt,
            string memory evidence,
            uint16 conf,
            uint256[2] memory counts,
            uint256[2] memory totals
        )
    {
        SimpleMarket.Market memory m = market.getMarket(id);
        return (
            m.question,
            m.marketOpen,
            m.marketClose,
            uint8(m.status),
            uint8(m.outcome),
            m.settledAt,
            m.evidenceURI,
            m.confidenceBps,
            m.predCounts,
            m.predTotals
        );
    }
}
