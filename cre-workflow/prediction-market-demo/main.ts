// main.ts
// Entry point for the CRE prediction market settlement workflow.
// Registers an EVM log trigger and orchestrates the full settlement flow.

import { cre, type Runtime, Runner, getNetwork, bytesToHex, EVMLog } from "@chainlink/cre-sdk";
import { keccak256, toHex, decodeEventLog, parseAbi } from "viem";
import { configSchema, type Config, type FirestoreWriteResponse, type GeminiResponse } from "./types";
// Import Gemini, Firestore, and EVM settlement helpers
import { askGemini } from "./gemini";
import { writeToFirestore } from "./firebase";
import { settleMarket } from "./evm";

/** ABI for the SettlementRequested event CRE listens for. */
const eventAbi = parseAbi(["event SettlementRequested(uint256 indexed marketId, string question)"]);
const eventSignature = "SettlementRequested(uint256,string)";

/*********************************
 * Log Trigger Handler
 *********************************/

/**
 * Handles SettlementRequested events from the SimpleMarket contract.
 * Orchestrates the full settlement flow: Gemini AI query → on-chain settlement → Firestore audit.
 *
 * @param runtime - CRE runtime instance with config and secrets
 * @param log - EVM log containing the SettlementRequested event
 * @returns Success message string
 */
const onLogTrigger = (runtime: Runtime<Config>, log: EVMLog): string => {
  try {
    // ========================================
    // Step 1: Decode Event Log
    // ========================================

    // Convert topics/data to hex for viem decoding
    const topics = log.topics.map(t => bytesToHex(t)) as [`0x${string}`, ...`0x${string}`[]];
    const data = bytesToHex(log.data);

    // Decode event fields using the ABI above
    const decodedLog = decodeEventLog({ abi: eventAbi, data, topics });
    runtime.log(`Event name: ${decodedLog.eventName}`);

    const marketId: bigint = decodedLog.args.marketId as bigint;
    const question: string = decodedLog.args.question as string;

    runtime.log(`Settlement request detected for Market Id: ${marketId.toString()}`);
    runtime.log(`"${question}"`);

    // ========================================
    // Step 2: Query Gemini AI for Outcome
    // ========================================
    // Calls Gemini API with Google search grounding to determine market outcome.
    // See gemini.ts for implementation details.

    const result: GeminiResponse = askGemini(runtime, marketId.toString(), question);
    runtime.log(`Successfully sent data to API. Status: ${result.statusCode}`);
    runtime.log(`Gemini Response for market: ${result.geminiResponse}`);

    // ========================================
    // Step 3: Submit On-Chain Settlement
    // ========================================
    // Encodes, signs, and submits the settlement report to the SimpleMarket contract.
    // See evm.ts for implementation details.

    const txHash: string = settleMarket(runtime, marketId, result.geminiResponse, result.responseId);
    runtime.log(`Settlement tx hash: ${txHash}`);

    // ========================================
    // Step 4: Record to Firestore
    // ========================================
    // Writes settlement data to Firestore for audit trail and frontend display.
    // See firebase.ts for implementation details.

    const firestoreResult: FirestoreWriteResponse = writeToFirestore(runtime, question, result, txHash);
    runtime.log(`Firestore Document: ${firestoreResult.name}`);

    return "Settlement Request Processed";
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    runtime.log(`onLogTrigger error: ${msg}`);
    throw err;
  }
};

/*********************************
 * Workflow Initialization
 *********************************/

/**
 * Initializes the CRE workflow by setting up the EVM log trigger.
 * Configures the workflow to listen for SettlementRequested events from the specified market contract.
 *
 * @param config - Validated workflow configuration
 * @returns Array of CRE handlers
 */
const initWorkflow = (config: Config) => {
  // Fetch the chain network to listen for logs on
  const network = getNetwork({
    chainFamily: "evm",
    chainSelectorName: config.evms[0].chainSelectorName,
    isTestnet: true,
  });

  if (!network) {
    throw new Error(`Network not found for chain selector name: ${config.evms[0].chainSelectorName}`);
  }

  const evmClient = new cre.capabilities.EVMClient(network.chainSelector.selector);

  // Compute the event topic hash for the event that we wish to monitor.
  const requestSettlementHash = keccak256(toHex(eventSignature));

  // Trigger CRE only on emit of SettlementRequested logs from the market contract
  return [
    cre.handler(
      evmClient.logTrigger({
        addresses: [config.evms[0].marketAddress],
        topics: [{ values: [requestSettlementHash] }],
        confidence: "CONFIDENCE_LEVEL_FINALIZED",
      }),
      onLogTrigger
    ),
  ];
};

/*********************************
 * Entry Point
 *********************************/

/**
 * Main entry point for the CRE workflow.
 * Initializes the CRE runner and starts the workflow.
 */
export async function main() {
  const runner = await Runner.newRunner<Config>({ configSchema });
  await runner.run(initWorkflow);
}

main();
