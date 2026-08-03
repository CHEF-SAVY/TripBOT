import { createPublicClient, http, type WalletClient } from "viem";
import { arcTestnet } from "viem/chains";

const ARC_TESTNET_RPC = "https://rpc.testnet.arc.network";

// Minimal ABI fragment — just the calls either side of Tripwire actually makes (seller
// reads `jobs`; buyer writes `createJob`/`release`/`dispute`). Copied from the real
// compiled artifact (contracts/out/JobEscrow.sol/JobEscrow.json, gitignored so it can't
// be imported directly), not hand-written from memory — same discipline the Solidity
// side uses for its own minimal interfaces (ISellerBond, IIdentityRegistry).
const JOB_ESCROW_ABI = [
  {
    type: "function",
    name: "jobs",
    inputs: [{ name: "", type: "uint256" }],
    outputs: [
      { name: "buyer", type: "address" },
      { name: "sellerAgentId", type: "uint256" },
      { name: "sellerPayoutAddress", type: "address" },
      { name: "amount", type: "uint256" },
      { name: "reservedBond", type: "uint256" },
      { name: "completionDeadline", type: "uint64" },
      { name: "responseDeadline", type: "uint64" },
      { name: "status", type: "uint8" },
      { name: "validationRequestHash", type: "bytes32" },
      { name: "evidenceHash", type: "bytes32" },
    ],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "createJob",
    inputs: [
      { name: "sellerAgentId", type: "uint256" },
      { name: "amount", type: "uint256" },
      { name: "completionDeadline", type: "uint64" },
      { name: "validationRequestHash", type: "bytes32" },
    ],
    outputs: [{ name: "jobId", type: "uint256" }],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "release",
    inputs: [{ name: "jobId", type: "uint256" }],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "dispute",
    inputs: [
      { name: "jobId", type: "uint256" },
      { name: "evidenceHash", type: "bytes32" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },
] as const;

// Mirrors the JobEscrow.JobStatus enum exactly (contracts/src/JobEscrow.sol) — index
// order matters, this must stay in sync with the Solidity declaration.
export const JobStatus = {
  None: 0,
  Active: 1,
  Released: 2,
  Disputed: 3,
  Resolved: 4,
  TimedOut: 5,
} as const;

export interface Job {
  buyer: `0x${string}`;
  sellerAgentId: bigint;
  sellerPayoutAddress: `0x${string}`;
  amount: bigint;
  reservedBond: bigint;
  completionDeadline: bigint;
  responseDeadline: bigint;
  status: number;
  validationRequestHash: `0x${string}`;
  evidenceHash: `0x${string}`;
}

const publicClient = createPublicClient({
  chain: arcTestnet,
  transport: http(ARC_TESTNET_RPC),
});

/**
 * Reads a job's full on-chain state. Read-only, no gas, no signature — anyone can call
 * this, which is exactly what lets the seller verify a buyer's jobId claim without
 * trusting the buyer's word for any of it.
 */
export async function getJob(jobEscrowAddress: `0x${string}`, jobId: bigint): Promise<Job> {
  const [
    buyer,
    sellerAgentId,
    sellerPayoutAddress,
    amount,
    reservedBond,
    completionDeadline,
    responseDeadline,
    status,
    validationRequestHash,
    evidenceHash,
  ] = await publicClient.readContract({
    address: jobEscrowAddress,
    abi: JOB_ESCROW_ABI,
    functionName: "jobs",
    args: [jobId],
  });

  return {
    buyer,
    sellerAgentId,
    sellerPayoutAddress,
    amount,
    reservedBond,
    completionDeadline,
    responseDeadline,
    status,
    validationRequestHash,
    evidenceHash,
  };
}

/**
 * Opens a job: pulls `amount` USDC from the caller into escrow (the caller must have
 * already `approve`d JobEscrow for at least `amount`) and reserves the seller's bond.
 * Uses simulate-then-write (viem's standard pattern for a state-changing call whose
 * return value you need) since a real transaction only ever gives back a hash, not
 * `createJob`'s `returns (uint256 jobId)` — simulating first predicts that value against
 * current chain state before the same call is actually sent.
 */
export async function createJob(
  walletClient: WalletClient,
  jobEscrowAddress: `0x${string}`,
  args: {
    sellerAgentId: bigint;
    amount: bigint;
    completionDeadline: bigint;
    validationRequestHash: `0x${string}`;
  },
): Promise<{ jobId: bigint; txHash: `0x${string}` }> {
  const { request, result: jobId } = await publicClient.simulateContract({
    address: jobEscrowAddress,
    abi: JOB_ESCROW_ABI,
    functionName: "createJob",
    args: [args.sellerAgentId, args.amount, args.completionDeadline, args.validationRequestHash],
    account: walletClient.account,
  });
  const txHash = await walletClient.writeContract(request);
  await publicClient.waitForTransactionReceipt({ hash: txHash });
  return { jobId, txHash };
}

/** Buyer accepts delivery: pays the seller and releases the bond reservation. */
export async function releaseJob(
  walletClient: WalletClient,
  jobEscrowAddress: `0x${string}`,
  jobId: bigint,
): Promise<`0x${string}`> {
  const { request } = await publicClient.simulateContract({
    address: jobEscrowAddress,
    abi: JOB_ESCROW_ABI,
    functionName: "release",
    args: [jobId],
    account: walletClient.account,
  });
  const txHash = await walletClient.writeContract(request);
  await publicClient.waitForTransactionReceipt({ hash: txHash });
  return txHash;
}

/** Buyer disputes instead of releasing: records evidenceHash and flips status to Disputed. */
export async function disputeJob(
  walletClient: WalletClient,
  jobEscrowAddress: `0x${string}`,
  jobId: bigint,
  evidenceHash: `0x${string}`,
): Promise<`0x${string}`> {
  const { request } = await publicClient.simulateContract({
    address: jobEscrowAddress,
    abi: JOB_ESCROW_ABI,
    functionName: "dispute",
    args: [jobId, evidenceHash],
    account: walletClient.account,
  });
  const txHash = await walletClient.writeContract(request);
  await publicClient.waitForTransactionReceipt({ hash: txHash });
  return txHash;
}
