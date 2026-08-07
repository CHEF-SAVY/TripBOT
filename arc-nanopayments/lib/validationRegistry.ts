import { createPublicClient, createWalletClient, http } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { arcTestnet } from "viem/chains";
import { nonceManager } from "viem/nonce";

const ARC_TESTNET_RPC = "https://rpc.testnet.arc.network";

// Fixed, already-deployed dependency (like the RPC URL above) — not one of Tripwire's own
// contracts, so unlike JOB_ESCROW_ADDRESS/SELLER_BOND_ADDRESS this isn't an env var.
// Verified live against Arcscan 2026-08-06: proxy 0x8004Cb1B..., impl
// ValidationRegistryUpgradeable at 0xDB31f5d9...
const VALIDATION_REGISTRY_ADDRESS = "0x8004Cb1BF31DAf7788923b405b754f57acEB4272" as const;

// Minimal ABI fragment — the one call this module makes. validationRequest() is the
// seller's own registration step; JobEscrow.sol never calls it (only reads the result via
// getValidationStatus), so it doesn't belong in the contract-side IValidationRegistry.sol
// either — same "just the calls actually made" discipline on both sides.
const VALIDATION_REGISTRY_ABI = [
  {
    type: "function",
    name: "validationRequest",
    inputs: [
      { name: "validatorAddress", type: "address" },
      { name: "agentId", type: "uint256" },
      { name: "requestURI", type: "string" },
      { name: "requestHash", type: "bytes32" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },
] as const;

// validationRequest() only ever has one caller in this codebase — the seller — unlike
// jobEscrow.ts's functions, which take a walletClient parameter because their real
// callers vary (the buyer, from agent.mts). So this module reads SELLER_PRIVATE_KEY and
// builds its own wallet client, rather than threading a parameter that would only ever
// have one real value.
if (!process.env.SELLER_PRIVATE_KEY) {
  throw new Error("SELLER_PRIVATE_KEY not configured");
}
// nonceManager serializes nonce assignment across concurrent calls from this one
// account. Without it, two overlapping requests to a protected route (this is a
// Next.js API route, so concurrent requests are real, not hypothetical) could both
// read the same pending nonce and race: the loser either gets rejected outright or
// silently replaces the winner's transaction in the mempool, leaving
// waitForTransactionReceipt below waiting on a hash that will never mine.
const sellerAccount = privateKeyToAccount(process.env.SELLER_PRIVATE_KEY as `0x${string}`, { nonceManager });

const publicClient = createPublicClient({
  chain: arcTestnet,
  transport: http(ARC_TESTNET_RPC),
});
const sellerWalletClient = createWalletClient({
  account: sellerAccount,
  chain: arcTestnet,
  transport: http(ARC_TESTNET_RPC),
});

/**
 * Registers a validation request naming `validatorAddress` (JobEscrow) for `agentId`
 * (the seller's own ERC-8004 identity) — the real registry requires the caller to be
 * `agentId`'s owner or an approved operator, which `sellerAccount` already is (it's the
 * same wallet that registered the agent). Waits for the transaction to mine before
 * returning, so the hash it hands back is immediately usable by a buyer's createJob()
 * call — no race between "hash returned" and "hash actually registered on-chain."
 */
export async function registerValidationRequest(args: {
  validatorAddress: `0x${string}`;
  agentId: bigint;
  requestURI: string;
  requestHash: `0x${string}`;
}): Promise<`0x${string}`> {
  const { request } = await publicClient.simulateContract({
    address: VALIDATION_REGISTRY_ADDRESS,
    abi: VALIDATION_REGISTRY_ABI,
    functionName: "validationRequest",
    args: [args.validatorAddress, args.agentId, args.requestURI, args.requestHash],
    account: sellerWalletClient.account,
  });
  const txHash = await sellerWalletClient.writeContract(request);
  await publicClient.waitForTransactionReceipt({ hash: txHash });
  return txHash;
}
