import "server-only";

import type { Address, Hex } from "viem";
import { jobEscrowAbi } from "./abi/job-escrow";
import { sellerBondAbi } from "./abi/seller-bond";
import { bot, envAddress, publicClient } from "./chain";
import { BOT_TESTNET_DEPLOYMENT } from "./deployments";

export const JobStatus = {
  None: 0,
  Active: 1,
  Released: 2,
  Disputed: 3,
  Resolved: 4,
  TimedOut: 5,
} as const;

export const JOB_STATUS_LABELS = ["NONE", "ACTIVE", "RELEASED", "DISPUTED", "RESOLVED", "TIMED OUT"] as const;

export type Job = {
  id: bigint;
  buyer: Address;
  sellerAgentId: bigint;
  sellerPayoutAddress: Address;
  amount: bigint;
  reservedBond: bigint;
  completionDeadline: bigint;
  responseDeadline: bigint;
  status: number;
  validationRequestHash: Hex;
  evidenceHash: Hex;
};

export type JobProofs = Partial<Record<"create" | "release" | "dispute" | "resolve" | "timeout", Hex>>;

export async function getJob(jobId: bigint): Promise<Job> {
  const row = await publicClient.readContract({
    address: envAddress("JOB_ESCROW_ADDRESS"),
    abi: jobEscrowAbi,
    functionName: "jobs",
    args: [jobId],
  });
  return {
    id: jobId,
    buyer: row[0],
    sellerAgentId: row[1],
    sellerPayoutAddress: row[2],
    amount: row[3],
    reservedBond: row[4],
    completionDeadline: row[5],
    responseDeadline: row[6],
    status: row[7],
    validationRequestHash: row[8],
    evidenceHash: row[9],
  };
}

export async function readJobPage(page: number, limit: number) {
  const nextJobId = await publicClient.readContract({
    address: envAddress("JOB_ESCROW_ADDRESS"),
    abi: jobEscrowAbi,
    functionName: "nextJobId",
  });
  const offset = BigInt((page - 1) * limit);
  if (offset >= nextJobId) return { jobs: [] as Job[], total: nextJobId };
  const exclusiveEnd = nextJobId - offset;
  const count = Number(exclusiveEnd < BigInt(limit) ? exclusiveEnd : BigInt(limit));
  const ids = Array.from({ length: count }, (_, index) => exclusiveEnd - 1n - BigInt(index));
  const jobs: Job[] = [];
  for (let start = 0; start < ids.length; start += 8) {
    jobs.push(...(await Promise.all(ids.slice(start, start + 8).map(getJob))));
  }
  return { jobs, total: nextJobId };
}

export async function readProofs(): Promise<{ proofs: Map<string, JobProofs>; resolutions: Map<string, boolean> }> {
  const address = envAddress("JOB_ESCROW_ADDRESS");
  const proofs = new Map<string, JobProofs>();
  const resolutions = new Map<string, boolean>();
  const events = [
    ["JobCreated", "create"],
    ["JobReleased", "release"],
    ["JobDisputed", "dispute"],
    ["JobResolved", "resolve"],
    ["JobResolvedNeutral", "resolve"],
    ["JobTimedOut", "timeout"],
    ["JobDisputeTimedOut", "timeout"],
  ] as const;
  // Fanned out rather than awaited in sequence: these are seven independent range scans
  // over the same block window, and run serially they dominate the latency of the job
  // ledger — the slowest read surface in the app.
  const scans = await Promise.all(
    events.map(([eventName]) =>
      publicClient.getContractEvents({
        address,
        abi: jobEscrowAbi,
        eventName,
        fromBlock: BOT_TESTNET_DEPLOYMENT.deploymentBlock,
        toBlock: "latest",
      }),
    ),
  );
  for (const [index, [eventName, proofKey]] of events.entries()) {
    for (const log of scans[index]) {
      const args = log.args as { jobId?: bigint; sellerAtFault?: boolean };
      if (args.jobId === undefined) continue;
      const id = args.jobId.toString();
      proofs.set(id, { ...proofs.get(id), [proofKey]: log.transactionHash });
      if (eventName === "JobResolved" && args.sellerAtFault !== undefined) resolutions.set(id, args.sellerAtFault);
    }
  }
  return { proofs, resolutions };
}

export async function readBond(agentId: bigint) {
  const address = envAddress("SELLER_BOND_ADDRESS");
  const [gross, reserved, free] = await Promise.all([
    publicClient.readContract({ address, abi: sellerBondAbi, functionName: "bondBalance", args: [agentId] }),
    publicClient.readContract({ address, abi: sellerBondAbi, functionName: "reserved", args: [agentId] }),
    publicClient.readContract({ address, abi: sellerBondAbi, functionName: "bondOf", args: [agentId] }),
  ]);
  return { gross, reserved, free, display: { gross: bot(gross), reserved: bot(reserved), free: bot(free) } };
}

export function serializeJob(job: Job, proofs: JobProofs = {}, sellerAtFault?: boolean) {
  return {
    id: job.id.toString(),
    buyer: job.buyer,
    sellerAgentId: job.sellerAgentId.toString(),
    sellerPayoutAddress: job.sellerPayoutAddress,
    amountWei: job.amount.toString(),
    amountBot: bot(job.amount),
    reservedBondWei: job.reservedBond.toString(),
    reservedBondBot: bot(job.reservedBond),
    completionDeadline: Number(job.completionDeadline),
    responseDeadline: Number(job.responseDeadline),
    status: job.status,
    statusLabel: JOB_STATUS_LABELS[job.status] || "UNKNOWN",
    validationRequestHash: job.validationRequestHash,
    evidenceHash: job.evidenceHash,
    sellerAtFault: sellerAtFault ?? null,
    proofs,
  };
}
