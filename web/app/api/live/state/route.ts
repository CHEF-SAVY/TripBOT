import { NextResponse } from "next/server";
import { getBalance } from "viem/actions";
import { isAddress } from "viem";
import { jobEscrowAbi } from "@/lib/abi/job-escrow";
import { bot, envAddress, publicClient } from "@/lib/chain";
import { JobStatus, readJobPage } from "@/lib/jobs";
import { demoWriteReadiness } from "@/lib/security/readiness";

export const dynamic = "force-dynamic";

let cache: { at: number; value: unknown } | undefined;

export async function GET() {
  if (cache && Date.now() - cache.at < 5_000) return NextResponse.json(cache.value);
  try {
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
    const value = {
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
    cache = { at: Date.now(), value };
    return NextResponse.json(value);
  } catch (error) {
    console.error("Failed to read live BOT Chain state", error);
    return NextResponse.json({ error: "BOT Chain state is temporarily unavailable." }, { status: 503 });
  }
}
