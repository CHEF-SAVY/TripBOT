import { randomUUID } from "node:crypto";
import { NextRequest, NextResponse } from "next/server";
import { isHex, type Hex } from "viem";
import { z } from "zod";
import { bot } from "@/lib/chain";
import { makeDelivery, redeemDelivery } from "@/lib/delivery";
import { getSeller } from "@/lib/sellers";
import { requireJudgeAccess, requireSameOrigin } from "@/lib/security/request";
import { assertDemoWriteReady } from "@/lib/security/readiness";
import {
  hashBinding,
  issueQuoteToken,
  issueSessionToken,
  verifyQuoteToken,
  verifySessionToken,
} from "@/lib/security/tokens";
import {
  claimTour,
  claimVerdict,
  consumeQuote,
  getSession,
  storeQuote,
  storeSession,
  updateSession,
} from "@/lib/storage";
import {
  createEscrowJob,
  evidenceCommitment,
  preflightDemo,
  registerValidationRequest,
  signDeliveryProof,
  submitVerdict,
} from "@/lib/transactions";

export const maxDuration = 60;

const sellerKey = z.enum(["honest", "faulty", "absent"]);
const requestSchema = z.discriminatedUnion("action", [
  z.object({ action: z.literal("start"), sellerKey }).strict(),
  z.object({ action: z.literal("fund"), quoteToken: z.string().min(32).max(4_096) }).strict(),
  z.object({
    action: z.literal("verdict"),
    sessionToken: z.string().min(32).max(4_096),
    verdict: z.enum(["accept", "dispute"]),
  }).strict(),
]);

type Event = Record<string, string | number | boolean | null | object> & { type: string; message: string };

class DemoError extends Error {
  constructor(message: string, readonly status = 400) {
    super(message);
  }
}

function stream(run: (emit: (event: Event) => void) => Promise<void>) {
  const encoder = new TextEncoder();
  return new Response(
    new ReadableStream({
      async start(controller) {
        const emit = (event: Event) => controller.enqueue(encoder.encode(`${JSON.stringify(event)}\n`));
        try {
          await run(emit);
        } catch (error) {
          console.error("Buyer session stream failed", error);
          emit({ type: "error", message: error instanceof DemoError ? error.message : "The live run stopped safely. No further transaction was sent." });
        } finally {
          controller.close();
        }
      },
    }),
    {
      headers: {
        "content-type": "application/x-ndjson; charset=utf-8",
        "cache-control": "no-store",
        "x-content-type-options": "nosniff",
      },
    },
  );
}

function bindings(access: { visitorId: string; ipHash: string }) {
  return { visitorHash: hashBinding(access.visitorId), ipHash: access.ipHash };
}

export async function POST(request: NextRequest) {
  try {
    requireSameOrigin(request);
    assertDemoWriteReady();
    const contentLength = Number(request.headers.get("content-length") || "0");
    if (contentLength > 8_192) return NextResponse.json({ error: "Request is too large." }, { status: 413 });
    const access = requireJudgeAccess(request);
    const body = requestSchema.parse(await request.json());
    const { visitorHash, ipHash } = bindings(access);

    if (body.action === "start") {
      return stream(async (emit) => {
        const seller = getSeller(body.sellerKey);
        if (!seller?.configured || seller.agentId === null) throw new DemoError("That seller is not registered for the live demo.");
        emit({ type: "quote-request", message: `Requesting signed terms from ${seller.name}.`, sellerKey: seller.key });
        const tour = await claimTour(visitorHash, ipHash, seller.key);
        if (tour === "already_ran") throw new DemoError("You already ran this seller recently. Choose another archetype.", 409);
        if (tour !== "claimed") throw new DemoError("The funded demo is at hourly capacity. Verified history remains available.", 429);

        const before = await preflightDemo(seller.agentId, seller.priceWei);
        const nonce = randomUUID();
        const validation = await registerValidationRequest(seller.agentId, `urn:tripbot:quote:${nonce}`);
        emit({
          type: "validation",
          message: "The seller registered a one-job validation request on-chain.",
          txHash: validation.txHash,
          requestHash: validation.requestHash,
        });
        const expiresAt = new Date(Date.now() + 15 * 60 * 1_000).toISOString();
        await storeQuote({
          nonce,
          visitor_hash: visitorHash,
          ip_hash: ipHash,
          seller_key: seller.key,
          request_hash: validation.requestHash,
          validation_tx_hash: validation.txHash,
          price_wei: seller.priceWei.toString(),
          seller_agent_id: seller.agentId.toString(),
          expires_at: expiresAt,
        });
        const quoteToken = issueQuoteToken({ nonce, visitorId: access.visitorId, ipHash, sellerKey: seller.key });
        emit({
          type: "awaiting-funding",
          message: "Terms verified. Nothing moves until you approve this exact amount.",
          quoteToken,
          priceBot: seller.priceBot,
          sellerAgentId: seller.agentId.toString(),
          requiredBondBot: bot(before.requiredBond),
          expiresAt,
        });
      });
    }

    if (body.action === "fund") {
      return stream(async (emit) => {
        const claims = verifyQuoteToken(body.quoteToken);
        if (claims.visitorId !== access.visitorId || claims.ipHash !== ipHash) throw new DemoError("This quote belongs to a different judge session.", 403);
        const seller = getSeller(claims.sellerKey);
        if (!seller?.configured || seller.agentId === null) throw new DemoError("The quoted seller is no longer configured.");
        await preflightDemo(seller.agentId, seller.priceWei);
        const quote = await consumeQuote(claims.nonce, visitorHash, ipHash);
        if (!quote) throw new DemoError("This quote expired or was already funded. Request fresh terms.", 409);
        if (
          quote.seller_key !== seller.key ||
          quote.price_wei !== seller.priceWei.toString() ||
          quote.seller_agent_id !== seller.agentId.toString() ||
          !isHex(quote.request_hash, { strict: true })
        ) throw new DemoError("Stored quote terms failed trusted-value verification.");

        const sessionId = randomUUID();
        await storeSession({
          id: sessionId,
          quote_nonce: quote.nonce,
          visitor_hash: visitorHash,
          ip_hash: ipHash,
          seller_key: seller.key,
          job_id: null,
          evidence_hash: null,
          evidence: null,
          create_tx_hash: null,
          expires_at: new Date(Date.now() + 6 * 60 * 60 * 1_000).toISOString(),
          state: "funding",
        });

        emit({ type: "funding", message: `Sending exactly ${seller.priceBot} BOT into escrow.` });
        const created = await createEscrowJob(seller.agentId, seller.priceWei, quote.request_hash as Hex);
        await updateSession(sessionId, {
          job_id: created.jobId.toString(),
          create_tx_hash: created.txHash,
          updated_at: new Date().toISOString(),
        });
        emit({
          type: "funded",
          message: `Job #${created.jobId} is funded. The seller has not been paid.`,
          jobId: created.jobId.toString(),
          txHash: created.txHash,
          amountBot: seller.priceBot,
        });

        let delivery = makeDelivery("absent");
        let infrastructureFailure = false;
        try {
          const proof = await signDeliveryProof(created.jobId);
          delivery = await redeemDelivery(seller.key, created.jobId, proof.signature);
        } catch (error) {
          infrastructureFailure = true;
          console.error("Delivery failed closed after funding", { sessionId, jobId: created.jobId.toString(), error });
        }
        const evidence = {
          version: 1,
          chainId: 968,
          jobId: created.jobId.toString(),
          sellerKey: seller.key,
          // The service being bought, not a URL. These archetypes are served in-process
          // rather than over HTTP, and naming a path here would put a claim in the on-chain
          // commitment that no request was ever made against.
          service: seller.service,
          infrastructureFailure,
          delivery,
        };
        const evidenceHash = evidenceCommitment(evidence);
        await updateSession(sessionId, {
          evidence,
          evidence_hash: evidenceHash,
          state: "delivered",
          updated_at: new Date().toISOString(),
        });
        const sessionToken = issueSessionToken({
          sessionId,
          visitorId: access.visitorId,
          ipHash,
          sellerKey: seller.key,
          jobId: created.jobId.toString(),
        });
        emit({
          type: "delivery",
          message: infrastructureFailure
            ? "Delivery failed closed. You can dispute the infrastructure-bound evidence without blindly slashing the seller."
            : delivery.ok ? "Delivery received. Inspect it before choosing a verdict." : "The seller did not deliver a usable response.",
          sessionToken,
          evidenceHash,
          evidenceMode: "hash-only",
          delivery,
          infrastructureFailure,
        });
      });
    }

    return stream(async (emit) => {
      const claims = verifySessionToken(body.sessionToken);
      if (claims.visitorId !== access.visitorId || claims.ipHash !== ipHash) throw new DemoError("This job belongs to a different judge session.", 403);
      const session = await getSession(claims.sessionId);
      if (!session || session.visitor_hash !== visitorHash || session.ip_hash !== ipHash || session.job_id !== claims.jobId) {
        throw new DemoError("The durable session record does not match this token.", 403);
      }
      if (!session.evidence_hash || !isHex(session.evidence_hash, { strict: true })) throw new DemoError("Bound evidence is unavailable; settlement is blocked safely.");
      if (!(await claimVerdict(session.id, visitorHash, ipHash, body.verdict))) throw new DemoError("A verdict is already being processed for this job.", 409);
      const settled = await submitVerdict(BigInt(claims.jobId), body.verdict, session.evidence_hash as Hex);
      await updateSession(session.id, {
        state: "settled",
        verdict_tx_hash: settled.txHash,
        updated_at: new Date().toISOString(),
      });
      emit({
        type: body.verdict === "accept" ? "released" : "disputed",
        message: body.verdict === "accept" ? "Buyer accepted. Escrow paid the seller." : "Buyer disputed. Escrow and bond remain locked for a ruling.",
        txHash: settled.txHash,
        evidenceHash: session.evidence_hash,
        sessionToken: body.sessionToken,
      });
    });
  } catch (error) {
    console.error("Buyer session request rejected", error);
    const status = error instanceof z.ZodError ? 400 : error instanceof DemoError ? error.status : 403;
    return NextResponse.json({ error: "The buyer-session request was rejected safely." }, { status });
  }
}
