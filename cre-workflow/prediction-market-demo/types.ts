// types.ts
// Type definitions and schemas for the prediction market settlement workflow.
// Includes configuration validation, Gemini API types, and Firestore data structures.

import { z } from "zod";

/*********************************
 * Configuration Schemas
 *********************************/

/**
 * Schema for individual EVM chain configuration.
 * Validates chain selector name, market contract address, and gas limit.
 */
const evmConfigSchema = z.object({
  chainSelectorName: z.string().min(1),
  marketAddress: z.string().regex(/^0x[a-fA-F0-9]{40}$/u, "marketAddress must be a 0x-prefixed 20-byte hex"),
  // Gas limit must be a numeric string (parsed from JSON config)
  gasLimit: z
    .string()
    .regex(/^\d+$/, "gasLimit must be a numeric string")
    .refine(val => Number(val) > 0, { message: "gasLimit must be greater than 0" }),
});

/**
 * Schema for the main workflow configuration file (config.json).
 * Validates Gemini model name and array of EVM configurations.
 */
export const configSchema = z.object({
  geminiModel: z.string(),
  evms: z.array(evmConfigSchema).min(1, "At least one EVM config is required"),
});

/** Type inferred from the validated config schema. */
export type Config = z.infer<typeof configSchema>;

/*********************************
 * Gemini API Types
 *********************************/

/**
 * Response from the Gemini API HTTP request.
 * Contains both the parsed result and raw response data.
 */
export type GeminiResponse = {
  statusCode: number;
  geminiResponse: string; // Parsed JSON string from Gemini
  responseId: string; // Unique identifier for this request
  rawJsonString: string; // Full raw response body
};

/**
 * Schema for validating Gemini's JSON response format.
 * Ensures the model returns a valid outcome and confidence score.
 */
export const GeminiResponseSchema = z.object({
  result: z.enum(["YES", "NO", "INCONCLUSIVE"]),
  confidence: z.number().int().min(0).max(10_000, "confidence must be between 0 and 10000 inclusive"),
});

/** Validated LLM result type. */
export type LLMResult = z.infer<typeof GeminiResponseSchema>;

/**
 * Request payload structure for Gemini API.
 * Includes system instructions, tools (search grounding), and user content.
 */
export interface GeminiData {
  system_instruction: {
    parts: { text: string }[];
  };
  tools: any[];
  contents: {
    parts: { text: string }[];
  }[];
}

/**
 * Response structure from Gemini API.
 * Contains the generated content and a unique response ID.
 */
export interface GeminiApiResponse {
  candidates: {
    content: {
      parts: { text: string }[];
    };
  }[];
  responseId: string;
}

/**
 * Market details extracted from the SettlementRequested event log.
 */
export interface LogDetails {
  marketId: string;
  question: string;
}

/*********************************
 * Firestore Types
 *********************************/

/**
 * Firestore document write payload structure.
 * All fields must follow Firestore's typed field format.
 */
export interface FirestoreWriteData {
  fields: {
    statusCode: {
      integerValue: number | string;
    };
    question: {
      stringValue: string;
    };
    geminiResponse: {
      stringValue: string;
    };
    responseId: {
      stringValue: string;
    };
    rawJsonString: {
      stringValue: string;
    };
    txHash: {
      stringValue: string;
    };
    createdAt: {
      integerValue: number;
    };
  };
}

/**
 * Response from Firestore document write operation.
 * Contains document metadata and echoes back the written fields.
 */
export interface FirestoreWriteResponse {
  name: string; // Full document path
  fields: {
    responseId: {
      stringValue: string;
    };
    statusCode: {
      integerValue: string; // Firestore stores numbers as strings
    };
    rawJsonString: {
      stringValue: string;
    };
    geminiResponse: {
      stringValue: string;
    };
  };
  createTime: string; // ISO 8601 timestamp
  updateTime: string; // ISO 8601 timestamp
}

/*********************************
 * Firebase Authentication Types
 *********************************/

/**
 * Response from Firebase anonymous sign-up endpoint.
 * Provides an ID token for authenticating Firestore requests.
 */
export interface SignupNewUserResponse {
  kind: string;
  idToken: string; // JWT token for Firestore authentication
  refreshToken: string;
  expiresIn: string; // Token expiration time in seconds
  localId: string; // Anonymous user ID
}
