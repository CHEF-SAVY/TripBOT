import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";
import { readJobPage, readProofs, serializeJob } from "@/lib/jobs";
import { warmRpc } from "@/lib/chain";
import { withLastGood } from "@/lib/last-good";

export const dynamic = "force-dynamic";

const querySchema = z.object({
  page: z.coerce.number().int().min(1).max(10_000).default(1),
  limit: z.coerce.number().int().min(1).max(50).default(20),
});

export async function GET(request: NextRequest) {
  const parsed = querySchema.safeParse(Object.fromEntries(request.nextUrl.searchParams));
  if (!parsed.success) return NextResponse.json({ error: "Invalid pagination parameters." }, { status: 400 });
  const key = `jobs:${parsed.data.page}:${parsed.data.limit}`;
  const { body, ok } = await withLastGood(key, 20_000, async () => {
    await warmRpc();
    const [{ jobs, total }, proofState] = await Promise.all([
      readJobPage(parsed.data.page, parsed.data.limit),
      readProofs(),
    ]);
    return {
      jobs: jobs.map((job) =>
        serializeJob(job, proofState.proofs.get(job.id.toString()), proofState.resolutions.get(job.id.toString())),
      ),
      page: parsed.data.page,
      limit: parsed.data.limit,
      total: total.toString(),
      updatedAt: new Date().toISOString(),
    };
  });
  if (!ok) return NextResponse.json({ error: "BOT Chain job proofs are temporarily unavailable." }, { status: 503 });
  return NextResponse.json(body);
}
