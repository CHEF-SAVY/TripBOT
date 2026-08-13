import { NextResponse } from "next/server";
import { getBalance } from "viem/actions";
import { isAddress } from "viem";
import { jobEscrowAbi } from "@/lib/abi/job-escrow";
import { bot, envAddress, publicClient, warmRpc } from "@/lib/chain";
import { JobStatus, readJobPage } from "@/lib/jobs";
import { withLastGood } from "@/lib/last-good";
import { demoWriteReadiness } from "@/lib/security/readiness";

export const dynamic = "force-dynamic";

export async function GET() {
  // Longer than the old five seconds: every miss costs a round of calls to an RPC that has
  // been taking seconds per connection, and this figure changes only when the chain does.
  const { body, ok } = await withLastGood("state", 15_000, async () => {
    await warmRpc();
    const escrow = envAddress("JOB_ESCROW_ADDRESS");
    const buyerAddress = process.env.BUYER_ADDRESS;
    const [jobPage, ratio, responseWindow, registryEnabled, sellerBond, arbiter, buyerBalance] = await Promise.all([
      readJobPage(1, 50),
      publicClient.readContract({ address: escrow, abi: jobEscrowAbi, functionName: "minBondRatioBps" }),
      publicClient.readContract({ address: escrow, abi: jobEscrowAbi, functionName: "responseWindow" }),
      publicClient.readContract({ address: escrow, abi: jobEscrowAbi, functionName: "validationRegistryEnabled" }),
      publicClient.readContract({ address: escrow, abi: jobEscrowAbi, functionName: "sellerBond" }),
      publicClient.readContract({ address: escrow, abi: jobEscrowAbi, functionName: "ARBITER" }),
      buyerAddress && isAddress(buyerAddress)
        ? getBalance(publicClient, { address: buyerAddress })
        : Promise.resolve(null),
    ]);
    const active = jobPage.jobs.filter((job) => job.status === JobStatus.Active).length;
    const disputed = jobPage.jobs.filter((job) => job.status === JobStatus.Disputed).length;
    const escrowed = jobPage.jobs.reduce(
      (sum, job) => sum + (job.status === JobStatus.Active || job.status === JobStatus.Disputed ? job.amount : 0n),
      0n,
    );
    const readiness = demoWriteReadiness();
    return {
      chain: { id: 968, name: "BOT Chain Testnet", explorer: "https://scan.bohr.life" },
      totalJobs: jobPage.total.toString(),
      visibleJobs: jobPage.jobs.length,
      activeJobs: active,
      disputedJobs: disputed,
      escrowedBot: bot(escrowed),
      bondRatioBps: ratio.toString(),
      bondRatioPercent: Number(ratio) / 100,
      responseWindowSeconds: Number(responseWindow),
      validationRegistryEnabled: registryEnabled,
      buyerBalanceBot: buyerBalance === null ? null : bot(buyerBalance),
      writeEnabled: readiness.ready,
      writeModeReason: readiness.reason,
      identities: { jobEscrow: escrow, sellerBond, arbiter },
      updatedAt: new Date().toISOString(),
    };
  });
  if (!ok) return NextResponse.json({ error: "BOT Chain state is temporarily unavailable." }, { status: 503 });
  return NextResponse.json(body);
}
