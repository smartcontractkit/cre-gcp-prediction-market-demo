// firebase.ts
// Firebase/Firestore integration for storing settlement results.
// Uses CRE HTTP capability to interact with Firebase REST APIs.

import { cre, ok, type Runtime, type HTTPSendRequester, consensusIdenticalAggregation } from "@chainlink/cre-sdk";
import type {
  Config,
  FirestoreWriteData,
  FirestoreWriteResponse,
  SignupNewUserResponse,
  GeminiResponse,
} from "./types";

/*********************************
 * Firebase/Firestore Integration
 *********************************/

/**
 * Writes settlement data to Firestore for audit trail and frontend display.
 * Authenticates with Firebase using anonymous sign-in, then writes the document.
 *
 * @param runtime - CRE runtime instance with config and secrets
 * @param response - Gemini API response containing settlement result
 * @param txHash - Transaction hash of the on-chain settlement
 * @returns Firestore write response with document metadata
 */
export function writeToFirestore(
  runtime: Runtime<Config>,
  question: string,
  response: GeminiResponse,
  txHash: string
): FirestoreWriteResponse {
  const firestoreApiKey = runtime.getSecret({ id: "FIREBASE_API_KEY" }).result();
  const firestoreProjectId = runtime.getSecret({ id: "FIREBASE_PROJECT_ID" }).result();

  const httpClient = new cre.capabilities.HTTPClient();

  // Obtain an ID token via Firebase anonymous authentication
  const tokenResult: SignupNewUserResponse = httpClient
    .sendRequest(
      runtime,
      postFirebaseIdToken(firestoreApiKey.value),
      consensusIdenticalAggregation<SignupNewUserResponse>()
    )(runtime.config)
    .result();

  // Write settlement data to Firestore
  const writeResult: FirestoreWriteResponse = httpClient
    .sendRequest(
      runtime,
      postFirestoreWrite(tokenResult.idToken, firestoreProjectId.value, question, response, txHash),
      consensusIdenticalAggregation<FirestoreWriteResponse>()
    )(runtime.config)
    .result();

  return writeResult;
}

/**
 * Obtains a Firebase ID token using anonymous authentication.
 * This token is required for Firestore API requests.
 *
 * @param firebaseApiKey - Firebase Web API key
 * @returns Function that performs the HTTP request and returns the auth response
 */
const postFirebaseIdToken =
  (firebaseApiKey: string) =>
  (sendRequester: HTTPSendRequester, config: Config): SignupNewUserResponse => {
    const dataToSend = {
      returnSecureToken: true,
    };

    const bodyBytes = new TextEncoder().encode(JSON.stringify(dataToSend));
    const body = Buffer.from(bodyBytes).toString("base64");

    const req = {
      url: `https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=${firebaseApiKey}`,
      method: "POST" as const,
      body: body,
      headers: {
        "Content-Type": "application/json",
      },
      cacheSettings: {
        readFromCache: true,
        maxAgeMs: 60_000,
      },
    };

    const resp = sendRequester.sendRequest(req).result();
    if (!ok(resp)) throw new Error(`HTTP request failed with status: ${resp.statusCode}`);

    const bodyText = new TextDecoder().decode(resp.body);
    const externalResp = JSON.parse(bodyText) as SignupNewUserResponse;

    return externalResp;
  };

/**
 * Writes a document to Firestore with settlement data.
 * Uses the Gemini response ID as the document ID for idempotency.
 *
 * @param idToken - Firebase authentication token
 * @param projectId - Firebase project ID
 * @param response - Gemini API response to store
 * @param txHash - Settlement transaction hash
 * @returns Function that performs the HTTP request and returns the Firestore response
 */
const postFirestoreWrite =
  (idToken: string, projectId: string, question: string, response: GeminiResponse, txHash: string) =>
  (sendRequester: HTTPSendRequester, config: Config): FirestoreWriteResponse => {
    const dataToSend: FirestoreWriteData = {
      fields: {
        statusCode: { integerValue: response.statusCode },
        question: { stringValue: question },
        geminiResponse: { stringValue: response.geminiResponse },
        responseId: { stringValue: response.responseId },
        rawJsonString: { stringValue: response.rawJsonString },
        txHash: { stringValue: txHash },
        createdAt: { integerValue: Date.now() },
      },
    };

    const bodyBytes = new TextEncoder().encode(JSON.stringify(dataToSend));
    const body = Buffer.from(bodyBytes).toString("base64");

    const req = {
      url: `https://firestore.googleapis.com/v1/projects/${projectId}/databases/(default)/documents/demo/?documentId=${response.responseId}`,
      method: "POST" as const,
      body: body,
      headers: {
        Authorization: `Bearer ${idToken}`,
        "Content-Type": "application/json",
      },
      cacheSettings: {
        readFromCache: true,
        maxAgeMs: 60_000,
      },
    };

    const resp = sendRequester.sendRequest(req).result();
    if (!ok(resp)) throw new Error(`HTTP request failed with status: ${resp.statusCode}`);

    const bodyText = new TextDecoder().decode(resp.body);
    const externalResp = JSON.parse(bodyText) as FirestoreWriteResponse;

    return externalResp;
  };
