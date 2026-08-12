import "server-only";

import { createWalletClient, http, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { botTestnet } from "./chain";

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
    transport: http(botTestnet.rpcUrls.default.http[0], { retryCount: 1, timeout: 10_000 }),
  });
}

export async function withSignerLock<T>(role: WalletRole, action: () => Promise<T>): Promise<T> {
  const previous = tails.get(role) ?? Promise.resolve();
  let release!: () => void;
  const current = new Promise<void>((resolve) => {
    release = resolve;
  });
  const tail = previous.catch(() => undefined).then(() => current);
  tails.set(role, tail);
  await previous.catch(() => undefined);
  try {
    return await action();
  } finally {
    release();
    if (tails.get(role) === tail) tails.delete(role);
  }
}
