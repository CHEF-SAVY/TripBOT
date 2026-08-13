import "server-only";

import { parseEther } from "viem";

export type SellerArchetype = "honest" | "faulty" | "absent";
export type SellerKey = "honest" | "faulty" | "absent";

type SellerDefinition = {
  key: SellerKey;
  name: string;
  archetype: SellerArchetype;
  agentIdEnv: string;
  fallbackAgentId?: bigint;
  priceBot: string;
  service: string;
  description: string;
};

const definitions: SellerDefinition[] = [
  {
    key: "honest",
    name: "Atlas Data Agent",
    archetype: "honest",
    agentIdEnv: "SELLER_HONEST_AGENT_ID",
    fallbackAgentId: 0n,
    priceBot: "0.010000",
    service: "Market pulse dataset",
    description: "Returns a complete, schema-valid market snapshot.",
  },
  {
    key: "faulty",
    name: "Drift Research Agent",
    archetype: "faulty",
    agentIdEnv: "SELLER_FAULTY_AGENT_ID",
    priceBot: "0.030000",
    service: "Research synthesis",
    description: "Returns a visibly malformed result that the buyer can dispute.",
  },
  {
    key: "absent",
    name: "Null Signal Agent",
    archetype: "absent",
    agentIdEnv: "SELLER_ABSENT_AGENT_ID",
    priceBot: "0.005000",
    service: "Signal quote",
    description: "Accepts a job but fails to deliver a usable response.",
  },
];

function readAgentId(definition: SellerDefinition): bigint | null {
  const raw = process.env[definition.agentIdEnv];
  if (!raw) return definition.fallbackAgentId ?? null;
  if (!/^\d+$/.test(raw)) throw new Error(`${definition.agentIdEnv} must be an unsigned integer`);
  return BigInt(raw);
}

export function getSellers() {
  return definitions.map((definition) => {
    const agentId = readAgentId(definition);
    return {
      ...definition,
      agentId,
      configured: agentId !== null,
      priceWei: parseEther(definition.priceBot),
    };
  });
}

export function getSeller(key: string) {
  return getSellers().find((seller) => seller.key === key);
}
