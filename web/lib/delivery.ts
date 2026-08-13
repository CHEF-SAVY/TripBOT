import "server-only";

import { verifyMessage, type Hex } from "viem";
import { envAddress } from "./chain";
import { getJob, JobStatus } from "./jobs";
import { getSeller, type SellerKey } from "./sellers";
import { claimDelivery } from "./storage";

type Delivery = {
  ok: boolean;
  status: number;
  payload: Record<string, string | number | string[] | null> | null;
  faults: string[];
};

export function makeDelivery(sellerKey: SellerKey): Delivery {
  if (sellerKey === "honest") {
    return {
      ok: true,
      status: 200,
      payload: {
        market: "BOT/tBOT",
        signal: "settlement-ready",
        confidence: 94,
        sources: ["escrow-state", "seller-bond", "validation-request"],
      },
      faults: [],
    };
  }
  if (sellerKey === "faulty") {
    return {
      ok: true,
      status: 200,
      payload: { market: null, signal: "guaranteed-profit", confidence: 999, sources: [] },
      faults: ["market is missing", "confidence exceeds the 0–100 schema", "unsupported guarantee"],
    };
  }
  return { ok: false, status: 504, payload: null, faults: ["seller returned no delivery before the gateway timeout"] };
}

export function adjudicateDelivery(sellerKey: SellerKey, delivery: Delivery): boolean {
  if (sellerKey === "absent") return !delivery.ok && delivery.status === 504 && delivery.payload === null;
  if (sellerKey === "faulty") return delivery.faults.length > 0;
  return !(
    delivery.ok &&
    delivery.status === 200 &&
    delivery.faults.length === 0 &&
    delivery.payload?.market === "BOT/tBOT" &&
    typeof delivery.payload.confidence === "number" &&
    delivery.payload.confidence >= 0 &&
    delivery.payload.confidence <= 100
  );
}

export async function redeemDelivery(sellerKey: SellerKey, jobId: bigint, signature: Hex): Promise<Delivery> {
  const seller = getSeller(sellerKey);
  if (!seller?.configured || seller.agentId === null) throw new Error("Seller is not configured");
  const job = await getJob(jobId);
  if (job.status !== JobStatus.Active) throw new Error("Only an active job can redeem delivery");
  if (job.sellerAgentId !== seller.agentId || job.amount < seller.priceWei) throw new Error("Job does not match this seller");
  const message = `Tripwire:chain:968:escrow:${envAddress("JOB_ESCROW_ADDRESS")}:job:${jobId}`;
  if (!(await verifyMessage({ address: job.buyer, message, signature }))) throw new Error("Buyer signature is invalid");

  const claimed = await claimDelivery({
    job_key: `${envAddress("JOB_ESCROW_ADDRESS").toLowerCase()}:${jobId}`,
    job_id: jobId.toString(),
    escrow_address: envAddress("JOB_ESCROW_ADDRESS"),
    endpoint: seller.service,
    buyer: job.buyer,
  });
  if (!claimed) throw new Error("Delivery was already redeemed or durable storage is unavailable");
  return makeDelivery(sellerKey);
}
