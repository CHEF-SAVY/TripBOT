import { NextRequest, NextResponse } from "next/server";
import { isHex, type Hex } from "viem";
import { z } from "zod";
import { adjudicateDelivery } from "@/lib/delivery";
import { requireJudgeAccess, requireSameOrigin } from "@/lib/security/request";
import { assertDemoWriteReady } from "@/lib/security/readiness";
import { hashBinding, verifySessionToken } from "@/lib/security/tokens";
import { claimResolution, getSession, updateSession } from "@/lib/storage";
import { evidenceCommitment, resolveNeutralDispute, resolveStoredDispute } from "@/lib/transactions";

export const maxDuration = 60;

const bodySchema = z.object({ sessionToken: z.string().min(32).max(4_096) }).strict();
const deliverySchema = z.object({
  ok: z.boolean(),
  status: z.number().int(),
  payload: z.record(z.string(), z.union([z.string(), z.number(), z.array(z.string()), z.null()])).nullable(),
  faults: z.array(z.string()),
});
const evidenceSchema = z.object({
  version: z.literal(1),
  chainId: z.literal(968),
  jobId: z.string().regex(/^\d+$/),
  sellerKey: z.enum(["honest", "faulty", "absent"]),
  endpoint: z.string(),
  infrastructureFailure: z.boolean(),
  delivery: deliverySchema,
}).strict();

export async function POST(request: NextRequest) {
  try {
    requireSameOrigin(request);
    assertDemoWriteReady();
    const access = requireJudgeAccess(request);
    const body = bodySchema.parse(await request.json());
    const claims = verifySessionToken(body.sessionToken);
    const visitorHash = hashBinding(access.visitorId);
    if (claims.visitorId !== access.visitorId || claims.ipHash !== access.ipHash) {
      return NextResponse.json({ error: "This dispute belongs to another judge session." }, { status: 403 });
    }
    const session = await getSession(claims.sessionId);
    if (
      !session ||
      session.visitor_hash !== visitorHash ||
      session.ip_hash !== access.ipHash ||
      session.job_id !== claims.jobId ||
      session.verdict !== "dispute" ||
      !session.evidence_hash ||
      !isHex(session.evidence_hash, { strict: true })
    ) return NextResponse.json({ error: "The durable dispute record is incomplete." }, { status: 409 });

    const evidence = evidenceSchema.parse(session.evidence);
    if (evidence.jobId !== claims.jobId || evidence.sellerKey !== claims.sellerKey) {
      return NextResponse.json({ error: "Stored evidence does not match this job." }, { status: 409 });
    }
    if (evidenceCommitment(evidence).toLowerCase() !== session.evidence_hash.toLowerCase()) {
      return NextResponse.json({ error: "Stored evidence failed its cryptographic commitment." }, { status: 409 });
    }
    if (!(await claimResolution(session.id, visitorHash, access.ipHash))) {
      return NextResponse.json({ error: "A ruling is already being processed." }, { status: 409 });
    }

    const neutral = evidence.infrastructureFailure;
    const sellerAtFault = neutral ? null : adjudicateDelivery(evidence.sellerKey, evidence.delivery);
    const resolution = neutral
      ? await resolveNeutralDispute(BigInt(claims.jobId), session.evidence_hash as Hex)
      : await resolveStoredDispute(BigInt(claims.jobId), sellerAtFault as boolean, session.evidence_hash as Hex);
    await updateSession(session.id, {
      state: "resolved",
      resolved_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    });
    return NextResponse.json({
      type: "resolved",
      message: neutral
        ? "Infrastructure failure: buyer refunded, seller bond released without a slash."
        : sellerAtFault
          ? "Evidence proved seller fault: buyer refunded and reserved bond slashed."
          : "Evidence did not prove seller fault: escrow paid the seller and released the bond.",
      txHash: resolution.txHash,
      outcome: neutral ? "neutral" : sellerAtFault ? "seller-at-fault" : "seller-prevails",
    });
  } catch (error) {
    console.error("Dispute resolution rejected", error);
    return NextResponse.json({ error: "The resolution request was rejected safely." }, { status: 400 });
  }
}
