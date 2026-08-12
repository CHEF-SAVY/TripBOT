import { NextResponse } from "next/server";
import { readBond } from "@/lib/jobs";
import { getSellers } from "@/lib/sellers";

export const dynamic = "force-dynamic";

export async function GET() {
  try {
    const sellers = await Promise.all(
      getSellers().map(async (seller) => {
        const bond = seller.agentId === null ? null : await readBond(seller.agentId);
        return {
          key: seller.key,
          name: seller.name,
          archetype: seller.archetype,
          agentId: seller.agentId?.toString() ?? null,
          endpoint: seller.endpoint,
          priceBot: seller.priceBot,
          service: seller.service,
          description: seller.description,
          configured: seller.configured,
          bond: bond?.display ?? null,
        };
      }),
    );
    return NextResponse.json({ sellers, updatedAt: new Date().toISOString() });
  } catch (error) {
    console.error("Failed to read seller catalogue", error);
    return NextResponse.json({ error: "Seller bond state is temporarily unavailable." }, { status: 503 });
  }
}
