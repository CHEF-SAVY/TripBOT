import "server-only";

import { Agent, request as undiciRequest } from "undici";
import {
  createPublicClient,
  custom,
  defineChain,
  formatEther,
  isAddress,
  type Address,
} from "viem";
import { BOT_TESTNET_DEPLOYMENT } from "./deployments";

export const botTestnet = defineChain({
  id: 968,
  name: "BOT Chain Testnet (Bohr)",
  nativeCurrency: { name: "BOT", symbol: "BOT", decimals: 18 },
  rpcUrls: {
    default: { http: [process.env.BOT_TESTNET_RPC || "https://rpc.bohr.life"] },
  },
  blockExplorers: {
    default: { name: "Bohr Scan", url: "https://scan.bohr.life" },
  },
  testnet: true,
});

const RPC_URL = botTestnet.rpcUrls.default.http[0];

/// One pooled, keep-alive connection for every chain read this process makes.
///
/// Opening a connection to BOT Chain's public RPC costs seconds; answering on an open one
/// costs milliseconds. Measured from a plain Node script: first call 3s, every call after it
/// 0.3s. Measured through Next's route handlers: every call paid the handshake again and a
/// page load timed out past thirty seconds.
///
/// The difference is that Next patches global `fetch`, and the patched version does not reuse
/// undici's connection pool the way a bare one does — a known and widely reported problem.
/// Going to undici directly sidesteps the patch entirely and keeps the socket open, which is
/// the whole difference between a page that renders and a page that times out.
const rpcAgent = new Agent({
  connect: { timeout: 30_000 },
  keepAliveTimeout: 60_000,
  keepAliveMaxTimeout: 300_000,
  connections: 6,
});

export const botTransport = custom(
  {
    async request({ method, params }) {
      const response = await undiciRequest(RPC_URL, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          jsonrpc: "2.0",
          id: Date.now(),
          method,
          params,
        }),
        dispatcher: rpcAgent,
        headersTimeout: 30_000,
        bodyTimeout: 30_000,
      });
      const payload = (await response.body.json()) as {
        result?: unknown;
        error?: { message?: string };
      };
      if (payload.error) throw new Error(payload.error.message ?? "RPC error");
      return payload.result;
    },
  },
  { retryCount: 2 },
);

export const publicClient = createPublicClient({
  chain: botTestnet,
  transport: botTransport,
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
