import "server-only";

import { isAddress, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { BOT_TESTNET_DEPLOYMENT } from "../deployments";

type Readiness = { ready: boolean; reason: string | null };

function keyAccount(name: string): Address {
  const value = process.env[name];
  if (!value || !/^0x[a-fA-F0-9]{64}$/.test(value)) throw new Error(`${name} is not configured`);
  return privateKeyToAccount(value as Hex).address;
}

function assertAddressMatches(addressName: string, keyName: string): void {
  const configured = process.env[addressName];
  if (!configured || !isAddress(configured)) throw new Error(`${addressName} is not configured`);
  if (configured.toLowerCase() !== keyAccount(keyName).toLowerCase()) {
    throw new Error(`${addressName} does not match ${keyName}`);
  }
}

export function assertDemoWriteReady(): void {
  if (process.env.DEMO_WRITE_ENABLED !== "true") throw new Error("Demo writes are disabled");
  const escrow = process.env.JOB_ESCROW_ADDRESS;
  if (!escrow || !isAddress(escrow)) throw new Error("JOB_ESCROW_ADDRESS is not configured");
  if (escrow.toLowerCase() === BOT_TESTNET_DEPLOYMENT.jobEscrow.toLowerCase()) {
    throw new Error("The legacy deployment is read-only; deploy the hardened contracts first");
  }
  if (!process.env.SESSION_SECRET || Buffer.byteLength(process.env.SESSION_SECRET) < 32) {
    throw new Error("SESSION_SECRET must contain at least 32 bytes");
  }
  if (!process.env.DEMO_ACCESS_CODE || Buffer.byteLength(process.env.DEMO_ACCESS_CODE) < 16) {
    throw new Error("DEMO_ACCESS_CODE must contain at least 16 bytes");
  }
  if (!process.env.SUPABASE_URL || !process.env.SUPABASE_SERVICE_ROLE_KEY) {
    throw new Error("Durable demo storage is not configured");
  }
  assertAddressMatches("BUYER_ADDRESS", "BUYER_PRIVATE_KEY");
  assertAddressMatches("SELLER_ADDRESS", "SELLER_PRIVATE_KEY");
  assertAddressMatches("ARBITER_ADDRESS", "ARBITER_PRIVATE_KEY");
}

export function demoWriteReadiness(): Readiness {
  try {
    assertDemoWriteReady();
    return { ready: true, reason: null };
  } catch {
    return {
      ready: false,
      reason: process.env.DEMO_WRITE_ENABLED === "true"
        ? "The hardened buyer demo is awaiting its complete wallet and durable-storage configuration."
        : "Transaction mode is intentionally locked while the hardened deployment is prepared.",
    };
  }
}
