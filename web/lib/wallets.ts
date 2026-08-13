import "server-only";

import { randomUUID } from "node:crypto";
import { createWalletClient, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { botTestnet, botTransport } from "./chain";
import { claimSignerLease, releaseSignerLease } from "./storage";

export type WalletRole = "buyer" | "seller" | "arbiter";

const environment: Record<WalletRole, { key: string; address: string }> = {
  buyer: { key: "BUYER_PRIVATE_KEY", address: "BUYER_ADDRESS" },
  seller: { key: "SELLER_PRIVATE_KEY", address: "SELLER_ADDRESS" },
  arbiter: { key: "ARBITER_PRIVATE_KEY", address: "ARBITER_ADDRESS" },
};

const tails = new Map<WalletRole, Promise<void>>();

export function accountFor(role: WalletRole) {
  const names = environment[role];
  const value = process.env[names.key];
  if (!value || !/^0x[a-fA-F0-9]{64}$/.test(value)) throw new Error(`${names.key} is not configured`);
  const account = privateKeyToAccount(value as Hex);
  const expected = process.env[names.address] as Address | undefined;
  if (!expected || expected.toLowerCase() !== account.address.toLowerCase()) {
    throw new Error(`${names.address} does not match ${names.key}`);
  }
  return account;
}

export function walletFor(role: WalletRole) {
  return createWalletClient({
    account: accountFor(role),
    chain: botTestnet,
    // Same pooled, keep-alive connection the reads use; a write should not pay a fresh
    // handshake at the exact moment a visitor is waiting on a transaction.
    transport: botTransport,
  });
}

// Longer than the routes' maxDuration, so a lease always outlives the request that took
// it, and shorter than any human retry, so a crashed instance frees the role quickly.
const LEASE_TTL_SECONDS = 90;
const LEASE_WAIT_MS = 20_000;
const LEASE_POLL_MS = 500;

/// Serializes every transaction sent by one role.
///
/// Nonce ordering has to hold across instances, not just within one: a serverless
/// deployment can route two concurrent sessions to separate instances, where both read the
/// same pending nonce and one transaction is then dropped or replaced. The durable lease is
/// therefore the real lock. The in-process chain below it is only an optimization — it stops
/// one instance from racing itself into the database for a lease it already holds.
export async function withSignerLock<T>(role: WalletRole, action: () => Promise<T>): Promise<T> {
  const previous = tails.get(role) ?? Promise.resolve();
  let release!: () => void;
  const current = new Promise<void>((resolve) => {
    release = resolve;
  });
  const tail = previous.catch(() => undefined).then(() => current);
  tails.set(role, tail);
  await previous.catch(() => undefined);

  const holder = randomUUID();
  try {
    const deadline = Date.now() + LEASE_WAIT_MS;
    let held = false;
    while (!held) {
      held = await claimSignerLease(role, holder, LEASE_TTL_SECONDS);
      if (held) break;
      if (Date.now() >= deadline) {
        throw new Error("Another live session is using this signer. Try again in a moment.");
      }
      await new Promise((resolve) => setTimeout(resolve, LEASE_POLL_MS));
    }
    try {
      return await action();
    } finally {
      // A failed release is survivable: the lease expires on its own. Never let it mask
      // the outcome of the action itself.
      await releaseSignerLease(role, holder).catch(() => undefined);
    }
  } finally {
    release();
    if (tails.get(role) === tail) tails.delete(role);
  }
}
