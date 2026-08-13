import { NextResponse } from "next/server";
import { jobEscrowAbi } from "@/lib/abi/job-escrow";
import { bot, envAddress, publicClient, warmRpc } from "@/lib/chain";
import { readBond } from "@/lib/jobs";
import { withLastGood } from "@/lib/last-good";
import { getSellers } from "@/lib/sellers";

export const dynamic = "force-dynamic";

export async function GET() {
  const { body, ok } = await withLastGood("sellers", 20_000, async () => {
    await warmRpc();
    // The bond ratio is an owner-settable risk parameter, so the amount a buyer stands to
    // recover is derived from the chain rather than assumed, using the same round-up the
    // escrow applies when it reserves collateral.
    const ratio = await publicClient.readContract({
      address: envAddress("JOB_ESCROW_ADDRESS"),
      abi: jobEscrowAbi,
      functionName: "minBondRatioBps",
    });

    const sellers = await Promise.all(
      getSellers().map(async (seller) => {
        const bond = seller.agentId === null ? null : await readBond(seller.agentId);
        const atRiskWei = (seller.priceWei * ratio + 9_999n) / 10_000n;
        return {
          atRiskBot: bot(atRiskWei),
          atRiskCovered: bond ? bond.free >= atRiskWei : false,
          key: seller.key,
          name: seller.name,
          archetype: seller.archetype,
          agentId: seller.agentId?.toString() ?? null,
          priceBot: seller.priceBot,
          service: seller.service,
          description: seller.description,
          configured: seller.configured,
          bond: bond?.display ?? null,
        };
      }),
    );
    return { sellers, updatedAt: new Date().toISOString() };
  });
  if (!ok) return NextResponse.json({ error: "Seller bond state is temporarily unavailable." }, { status: 503 });
  return NextResponse.json(body);
}
