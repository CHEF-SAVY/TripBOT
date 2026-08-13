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
