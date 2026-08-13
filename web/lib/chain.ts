import "server-only";

import { createPublicClient, defineChain, formatEther, http, isAddress, type Address } from "viem";
import { BOT_TESTNET_DEPLOYMENT } from "./deployments";

export const botTestnet = defineChain({
  id: 968,
  name: "BOT Chain Testnet (Bohr)",
  nativeCurrency: { name: "BOT", symbol: "BOT", decimals: 18 },
  rpcUrls: { default: { http: [process.env.BOT_TESTNET_RPC || "https://rpc.bohr.life"] } },
  blockExplorers: { default: { name: "Bohr Scan", url: "https://scan.bohr.life" } },
  testnet: true,
});

export const publicClient = createPublicClient({
  chain: botTestnet,
  // BOT Chain testnet is young and its public RPC has been observed taking well over ten
  // seconds to answer a single call. Timing out below that turns a slow chain into a failed
  // read, which the interface then has to explain as an error rather than as latency.
  transport: http(botTestnet.rpcUrls.default.http[0], { retryCount: 2, timeout: 30_000 }),
});

/// Opens one connection before anything fans out.
///
/// Measured against BOT Chain's public RPC: six parallel reads from cold take about nineteen
/// seconds, because each one opens its own connection and they contend on the handshake,
/// while the same read against a warm pool takes 0.4s. Awaiting a single cheap call first
/// pays the handshake once and lets everything after it reuse the connection. Memoised, and
/// deliberately never rejects — a failed warm-up must not become the reason a read fails,
/// since the read is about to try again anyway.
let warming: Promise<void> | undefined;
export function warmRpc(): Promise<void> {
  warming ??= publicClient
    .getChainId()
    .then(() => undefined)
    .catch(() => {
      warming = undefined;
    });
  return warming;
}

const defaults: Record<string, Address> = {
  JOB_ESCROW_ADDRESS: BOT_TESTNET_DEPLOYMENT.jobEscrow,
  SELLER_BOND_ADDRESS: BOT_TESTNET_DEPLOYMENT.sellerBond,
  IDENTITY_REGISTRY_ADDRESS: BOT_TESTNET_DEPLOYMENT.identityRegistry,
  VALIDATION_REGISTRY_ADDRESS: BOT_TESTNET_DEPLOYMENT.validationRegistry,
};

export function envAddress(name: keyof typeof defaults): Address {
  const value = process.env[name] || defaults[name];
  if (!isAddress(value)) throw new Error(`${name} is not a valid EVM address`);
  return value;
}

export function bot(value: bigint, decimals = 6): string {
  const [whole, fraction = ""] = formatEther(value).split(".");
  return `${whole}.${fraction.padEnd(decimals, "0").slice(0, decimals)}`;
}

export function explorerTx(hash: string): string {
  return `${botTestnet.blockExplorers.default.url}/tx/${hash}`;
}

export function explorerAddress(address: string): string {
  return `${botTestnet.blockExplorers.default.url}/address/${address}`;
}
