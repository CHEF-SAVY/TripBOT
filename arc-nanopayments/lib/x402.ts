/**
 * Copyright 2026 Circle Internet Group, Inc.  All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

import { createClient } from "@supabase/supabase-js";
import { NextRequest, NextResponse } from "next/server";
import { zeroHash } from "viem";
import { getJob, JobStatus, recoverJobIdSigner } from "./jobEscrow";

const supabase = createClient(
  process.env.NEXT_PUBLIC_SUPABASE_URL!,
  process.env.SUPABASE_SERVICE_ROLE_KEY!,
);

// Fails loudly at module load rather than silently defaulting to 0n — a misconfigured
// SELLER_AGENT_ID should be an obvious startup error, not a confusing "wrong seller"
// rejection on every request once real jobs start hitting it.
if (!process.env.SELLER_AGENT_ID) {
  throw new Error("SELLER_AGENT_ID not configured");
}
const SELLER_AGENT_ID = BigInt(process.env.SELLER_AGENT_ID);

const HEX_ADDRESS_RE = /^0x[a-fA-F0-9]{40}$/;
const rawJobEscrowAddress = process.env.JOB_ESCROW_ADDRESS;
if (rawJobEscrowAddress && !HEX_ADDRESS_RE.test(rawJobEscrowAddress)) {
  throw new Error(`JOB_ESCROW_ADDRESS is not a valid address: ${rawJobEscrowAddress}`);
}
const JOB_ESCROW_ADDRESS = rawJobEscrowAddress as `0x${string}` | undefined;

/** Parses a "$0.001"-style price string into USDC atomic units (6 decimals). */
function priceToAtomicUnits(price: string): bigint {
  return BigInt(Math.round(parseFloat(price.replace("$", "")) * 1_000_000));
}

/**
 * Wraps a Next.js route handler with JobEscrow settlement verification.
 *
 * Two-step flow, same shape x402 always had, but "payment" is now an on-chain
 * escrowed job instead of a signed Circle Gateway authorization:
 *
 *  1. No jobId presented -> 402 with what's needed to call JobEscrow.createJob()
 *     (price, sellerAgentId, requestHash, jobEscrowAddress). Plain JSON body, not the
 *     old base64 PAYMENT-REQUIRED header — that encoding existed to satisfy x402's
 *     signed-payload convention, which doesn't apply to a read-only job lookup.
 *  2. jobId presented (`x-job-id` header) -> read-only view call to JobEscrow.jobs(jobId)
 *     confirms status is Active and the seller/amount actually match this resource, and
 *     an `x-job-signature` proves the caller actually controls job.buyer — status/
 *     seller/amount alone only prove *some* valid job exists, not that this caller is
 *     the one who paid for it (jobIds are sequential and freely readable, so without
 *     this a job's content could be redeemed by anyone who saw or guessed its id, not
 *     just its buyer). Only then does the real handler run.
 */
export function withGateway(
  handler: (req: NextRequest) => Promise<NextResponse>,
  price: string,
  endpoint: string,
) {
  const expectedAmount = priceToAtomicUnits(price);

  return async (req: NextRequest) => {
    if (!JOB_ESCROW_ADDRESS) {
      return NextResponse.json({ error: "JOB_ESCROW_ADDRESS not configured" }, { status: 500 });
    }

    const jobIdHeader = req.headers.get("x-job-id");

    // No jobId yet — buyer hasn't created a job. Tell them what to create one against.
    if (!jobIdHeader) {
      console.log(`[escrow] 402 Job Required: ${endpoint}`);
      return NextResponse.json(
        {
          price,
          sellerAgentId: SELLER_AGENT_ID.toString(),
          // TODO(Phase 3): real ERC-8004 validationRequest() hash, once the Validation
          // Registry is wired in on both sides. JobEscrow.createJob() doesn't check
          // this field yet either, so a fake-but-real-looking hash here would just be
          // misleading — a zero placeholder is the honest thing to send.
          requestHash: zeroHash,
          jobEscrowAddress: JOB_ESCROW_ADDRESS,
        },
        { status: 402 },
      );
    }

    let jobId: bigint;
    try {
      jobId = BigInt(jobIdHeader);
    } catch {
      return NextResponse.json({ error: "x-job-id must be a valid integer" }, { status: 400 });
    }
    // BigInt("-1") parses without throwing, but a negative value can't be ABI-encoded
    // as the uint256 `jobs()` expects — catch it here with a clear 400 instead of
    // letting it fail deep inside the RPC call below.
    if (jobId < BigInt(0)) {
      return NextResponse.json({ error: "x-job-id must not be negative" }, { status: 400 });
    }

    const jobSignature = req.headers.get("x-job-signature");
    if (!jobSignature) {
      return NextResponse.json(
        { error: "x-job-signature is required — sign the jobId to prove you're its buyer" },
        { status: 401 },
      );
    }

    let job;
    try {
      job = await getJob(JOB_ESCROW_ADDRESS, jobId);
    } catch (err) {
      console.error(`Failed to read job ${jobId}:`, err instanceof Error ? err.message : err);
      return NextResponse.json({ error: "Failed to look up job" }, { status: 500 });
    }

    if (job.status === JobStatus.None) {
      return NextResponse.json({ error: `Job ${jobId} does not exist` }, { status: 400 });
    }
    if (job.status !== JobStatus.Active) {
      return NextResponse.json({ error: `Job ${jobId} is not Active (status: ${job.status})` }, { status: 400 });
    }

    let signer: `0x${string}`;
    try {
      signer = await recoverJobIdSigner(jobId, jobSignature as `0x${string}`);
    } catch {
      return NextResponse.json({ error: "x-job-signature is not a valid signature" }, { status: 400 });
    }
    if (signer.toLowerCase() !== job.buyer.toLowerCase()) {
      return NextResponse.json({ error: `x-job-signature was not signed by job ${jobId}'s buyer` }, { status: 401 });
    }

    if (job.sellerAgentId !== SELLER_AGENT_ID) {
      return NextResponse.json({ error: `Job ${jobId} was not created for this seller` }, { status: 400 });
    }
    // Known limitation: this only checks seller + amount, not which endpoint the job
    // was quoted for. Today the four routes happen to have distinct prices, so this
    // can't be exploited by accident, but nothing stops a job created against one
    // endpoint's price from being replayed against a different endpoint charging the
    // same amount. Binding a job to a specific endpoint is exactly what Phase 3's
    // requestHash check (once real) is meant to close — not fixed here on purpose,
    // since the contract side doesn't enforce it yet either.
    if (job.amount !== expectedAmount) {
      return NextResponse.json(
        { error: `Job ${jobId} amount (${job.amount}) does not match the quoted price (${expectedAmount})` },
        { status: 400 },
      );
    }

    try {
      // Record the job as settled in the same store the old settlement events used, so
      // the existing realtime dashboard keeps working off escrow jobs instead of Gateway
      // settlements. A logging failure here must never block a delivery the buyer has
      // already legitimately paid and authenticated for.
      const { error } = await supabase.from("payment_events").insert({
        endpoint,
        payer: job.buyer,
        amount_usdc: (Number(job.amount) / 1e6).toString(),
        network: "arc-testnet",
        gateway_tx: null,
        raw: { jobId: jobId.toString(), sellerAgentId: job.sellerAgentId.toString() },
      });
      if (error) {
        console.error("Failed to record payment event:", error.message);
      }
    } catch (err) {
      console.error("Failed to record payment event:", err instanceof Error ? err.message : err);
    }

    console.log(`[escrow] Job ${jobId} verified Active: ${endpoint} — ${price} from ${job.buyer}`);

    return handler(req);
  };
}
