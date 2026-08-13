import "server-only";

import { keccak256, parseEventLogs, toBytes, type Hex } from "viem";
import { identityRegistryAbi } from "./abi/identity-registry";
import { jobEscrowAbi } from "./abi/job-escrow";
import { sellerBondAbi } from "./abi/seller-bond";
import { validationRegistryAbi } from "./abi/validation-registry";
import { envAddress, publicClient, warmRpc } from "./chain";
import { getJob, JobStatus } from "./jobs";
import { assertDemoWriteReady } from "./security/readiness";
import { accountFor, walletFor, withSignerLock } from "./wallets";

async function confirmed(hash: Hex) {
  const receipt = await publicClient.waitForTransactionReceipt({ hash, confirmations: 1, timeout: 30_000 });
  if (receipt.status !== "success") throw new Error("BOT Chain transaction reverted");
  return receipt;
}

export async function registerValidationRequest(agentId: bigint, requestUri: string) {
  assertDemoWriteReady();
  if (requestUri.length > 256) throw new Error("Validation request URI is too long");
  return withSignerLock("seller", async () => {
    const wallet = walletFor("seller");
    const address = envAddress("VALIDATION_REGISTRY_ADDRESS");
    const { request } = await publicClient.simulateContract({
      account: wallet.account,
      address,
      abi: validationRegistryAbi,
      functionName: "validationRequest",
      args: [envAddress("JOB_ESCROW_ADDRESS"), agentId, requestUri],
    });
    const txHash = await wallet.writeContract(request);
    const receipt = await confirmed(txHash);
    const event = parseEventLogs({ abi: validationRegistryAbi, eventName: "ValidationRequested", logs: receipt.logs })[0];
    if (!event) throw new Error("Validation request receipt did not contain its request hash");
    if (event.args.agentId !== agentId || event.args.validatorAddress.toLowerCase() !== envAddress("JOB_ESCROW_ADDRESS").toLowerCase()) {
      throw new Error("Validation request receipt did not match the quoted seller");
    }
    return { requestHash: event.args.requestHash, txHash };
  });
}

export async function createEscrowJob(agentId: bigint, price: bigint, requestHash: Hex) {
  assertDemoWriteReady();
  return withSignerLock("buyer", async () => {
    const wallet = walletFor("buyer");
    const deadline = BigInt(Math.floor(Date.now() / 1_000) + 15 * 60);
    const address = envAddress("JOB_ESCROW_ADDRESS");
    const { request } = await publicClient.simulateContract({
      account: wallet.account,
      address,
      abi: jobEscrowAbi,
      functionName: "createJob",
      args: [agentId, deadline, requestHash],
      value: price,
    });
    const txHash = await wallet.writeContract(request);
    const receipt = await confirmed(txHash);
    const event = parseEventLogs({ abi: jobEscrowAbi, eventName: "JobCreated", logs: receipt.logs })[0];
    if (!event) throw new Error("Escrow receipt did not contain a JobCreated event");
    if (event.args.sellerAgentId !== agentId || event.args.amount !== price) {
      throw new Error("Escrow receipt did not match the approved quote");
    }
    return { jobId: event.args.jobId, txHash, deadline };
  });
}

export async function submitVerdict(jobId: bigint, verdict: "accept" | "dispute", evidenceHash: Hex) {
  assertDemoWriteReady();
  return withSignerLock("buyer", async () => {
    const job = await getJob(jobId);
    const buyer = accountFor("buyer").address;
    if (job.status !== JobStatus.Active || job.buyer.toLowerCase() !== buyer.toLowerCase()) {
      throw new Error("The buyer can no longer settle this job");
    }
    const wallet = walletFor("buyer");
    const address = envAddress("JOB_ESCROW_ADDRESS");
    const txHash = verdict === "accept"
      ? await (async () => {
          const { request } = await publicClient.simulateContract({
            account: wallet.account,
            address,
            abi: jobEscrowAbi,
            functionName: "release",
            args: [jobId],
          });
          return wallet.writeContract(request);
        })()
      : await (async () => {
          const { request } = await publicClient.simulateContract({
            account: wallet.account,
            address,
            abi: jobEscrowAbi,
            functionName: "dispute",
            args: [jobId, evidenceHash],
          });
          return wallet.writeContract(request);
        })();
    await confirmed(txHash);
    return { txHash };
  });
}

export async function resolveStoredDispute(jobId: bigint, sellerAtFault: boolean, evidenceHash: Hex) {
  assertDemoWriteReady();
  return withSignerLock("arbiter", async () => {
    const job = await getJob(jobId);
    if (job.status !== JobStatus.Disputed || job.evidenceHash.toLowerCase() !== evidenceHash.toLowerCase()) {
      throw new Error("On-chain dispute state does not match the stored evidence");
    }
    const wallet = walletFor("arbiter");
    const address = envAddress("JOB_ESCROW_ADDRESS");
    const { request } = await publicClient.simulateContract({
      account: wallet.account,
      address,
      abi: jobEscrowAbi,
      functionName: "resolveDispute",
      args: [jobId, sellerAtFault],
    });
    const txHash = await wallet.writeContract(request);
    await confirmed(txHash);
    return { txHash };
  });
}

export async function resolveNeutralDispute(jobId: bigint, evidenceHash: Hex) {
  assertDemoWriteReady();
  return withSignerLock("arbiter", async () => {
    const job = await getJob(jobId);
    if (job.status !== JobStatus.Disputed || job.evidenceHash.toLowerCase() !== evidenceHash.toLowerCase()) {
      throw new Error("On-chain dispute state does not match the stored evidence");
    }
    const wallet = walletFor("arbiter");
    const address = envAddress("JOB_ESCROW_ADDRESS");
    const { request } = await publicClient.simulateContract({
      account: wallet.account,
      address,
      abi: jobEscrowAbi,
      functionName: "resolveDisputeNeutral",
      args: [jobId],
    });
    const txHash = await wallet.writeContract(request);
    await confirmed(txHash);
    return { txHash };
  });
}

export async function preflightDemo(agentId: bigint, price: bigint) {
  assertDemoWriteReady();
  await warmRpc();
  const escrow = envAddress("JOB_ESCROW_ADDRESS");
  const sellerBond = envAddress("SELLER_BOND_ADDRESS");
  const buyer = accountFor("buyer").address;
  const seller = accountFor("seller").address;
  const [buyerBalance, sellerBalance, ratio, freeBond, validationEnabled, paused, registeredOwner, wiredBond] =
    await Promise.all([
      publicClient.getBalance({ address: buyer }),
      publicClient.getBalance({ address: seller }),
      publicClient.readContract({ address: escrow, abi: jobEscrowAbi, functionName: "minBondRatioBps" }),
      publicClient.readContract({ address: sellerBond, abi: sellerBondAbi, functionName: "bondOf", args: [agentId] }),
      publicClient.readContract({ address: escrow, abi: jobEscrowAbi, functionName: "validationRegistryEnabled" }),
      publicClient.readContract({ address: escrow, abi: jobEscrowAbi, functionName: "jobCreationPaused" }),
      publicClient.readContract({
        address: envAddress("IDENTITY_REGISTRY_ADDRESS"),
        abi: identityRegistryAbi,
        functionName: "ownerOf",
        args: [agentId],
      }),
      publicClient.readContract({ address: escrow, abi: jobEscrowAbi, functionName: "sellerBond" }),
    ]);
  const requiredBond = (price * ratio + 9_999n) / 10_000n;
  const buyerFloor = 200_000_000_000_000_000n;
  const sellerFloor = 20_000_000_000_000_000n;
  if (buyerBalance < buyerFloor || buyerBalance < price) throw new Error("The demo buyer needs a faucet refill");
  if (sellerBalance < sellerFloor) throw new Error("The demo seller needs gas for quote attestations");
  if (freeBond < requiredBond) throw new Error("The seller does not have enough free collateral");
  if (!validationEnabled) throw new Error("Validation proof is disabled on the configured escrow");
  if (paused) throw new Error("New escrow jobs are paused");
  if (registeredOwner.toLowerCase() !== seller.toLowerCase()) throw new Error("The seller key does not own this agent");
  if (wiredBond.toLowerCase() !== sellerBond.toLowerCase()) throw new Error("Escrow and bond contracts are miswired");
  return { buyerBalance, sellerBalance, ratio, freeBond, requiredBond };
}

export function evidenceCommitment(value: unknown): Hex {
  return keccak256(toBytes(JSON.stringify(canonicalize(value))));
}

function canonicalize(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>)
        .sort(([left], [right]) => left.localeCompare(right))
        .map(([key, entry]) => [key, canonicalize(entry)]),
    );
  }
  return value;
}

export async function signDeliveryProof(jobId: bigint) {
  const account = accountFor("buyer");
  const message = `Tripwire:chain:968:escrow:${envAddress("JOB_ESCROW_ADDRESS")}:job:${jobId}`;
  return { message, signature: await account.signMessage({ message }) };
}
