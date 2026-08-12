import "server-only";

type Json = null | boolean | number | string | Json[] | { [key: string]: Json };

function config() {
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) throw new Error("Durable demo storage is unavailable");
  const parsed = new URL(url);
  if (parsed.protocol !== "https:" && parsed.hostname !== "localhost" && parsed.hostname !== "127.0.0.1") {
    throw new Error("SUPABASE_URL must use HTTPS outside local development");
  }
  return { base: parsed.toString().replace(/\/$/, ""), key };
}

async function request<T>(path: string, init: RequestInit): Promise<T> {
  const { base, key } = config();
  const response = await fetch(`${base}/rest/v1/${path}`, {
    ...init,
    cache: "no-store",
    headers: {
      apikey: key,
      authorization: `Bearer ${key}`,
      "content-type": "application/json",
      ...init.headers,
    },
    signal: AbortSignal.timeout(8_000),
  });
  if (!response.ok) {
    const body = (await response.text()).slice(0, 500);
    console.error("Demo storage request failed", response.status, body);
    throw new Error("Durable demo storage operation failed");
  }
  if (response.status === 204) return undefined as T;
  return (await response.json()) as T;
}

export type StoredQuote = {
  nonce: string;
  visitor_hash: string;
  ip_hash: string;
  seller_key: "honest" | "faulty" | "absent";
  request_hash: string;
  validation_tx_hash: string;
  price_wei: string;
  seller_agent_id: string;
  expires_at: string;
};

export async function claimTour(visitorHash: string, ipHash: string, sellerKey: string) {
  const rows = await request<Array<{ result: "claimed" | "already_ran" | "capacity" }>>(
    "rpc/claim_demo_tour",
    { method: "POST", body: JSON.stringify({ p_visitor_hash: visitorHash, p_ip_hash: ipHash, p_seller_key: sellerKey }) },
  );
  return rows[0]?.result;
}

export async function claimAccessAttempt(ipHash: string): Promise<boolean> {
  return request<boolean>("rpc/claim_demo_access_attempt", {
    method: "POST",
    body: JSON.stringify({ p_ip_hash: ipHash }),
  });
}

export async function storeQuote(quote: StoredQuote): Promise<void> {
  await request("demo_quotes", {
    method: "POST",
    headers: { Prefer: "return=minimal" },
    body: JSON.stringify(quote),
  });
}

export async function consumeQuote(nonce: string, visitorHash: string, ipHash: string): Promise<StoredQuote | null> {
  const rows = await request<StoredQuote[]>("rpc/consume_demo_quote", {
    method: "POST",
    body: JSON.stringify({ p_nonce: nonce, p_visitor_hash: visitorHash, p_ip_hash: ipHash }),
  });
  return rows[0] ?? null;
}

export async function storeSession(row: Record<string, Json>): Promise<void> {
  await request("demo_sessions", {
    method: "POST",
    headers: { Prefer: "return=minimal" },
    body: JSON.stringify(row),
  });
}

export type StoredSession = {
  id: string;
  quote_nonce: string;
  visitor_hash: string;
  ip_hash: string;
  seller_key: "honest" | "faulty" | "absent";
  job_id: string | null;
  evidence_hash: string | null;
  evidence: Json;
  create_tx_hash: string | null;
  evidence_tx_hash: string | null;
  verdict: "accept" | "dispute" | null;
  verdict_tx_hash: string | null;
  state: "funding" | "delivered" | "settling" | "settled" | "resolving" | "resolved" | "failed";
};

export async function getSession(id: string): Promise<StoredSession | null> {
  const rows = await request<StoredSession[]>(`demo_sessions?id=eq.${encodeURIComponent(id)}&select=*`, {
    method: "GET",
  });
  return rows[0] ?? null;
}

export async function updateSession(id: string, values: Record<string, Json>): Promise<void> {
  await request(`demo_sessions?id=eq.${encodeURIComponent(id)}`, {
    method: "PATCH",
    headers: { Prefer: "return=minimal" },
    body: JSON.stringify(values),
  });
}

export async function claimVerdict(
  id: string,
  visitorHash: string,
  ipHash: string,
  verdict: "accept" | "dispute",
): Promise<boolean> {
  return request<boolean>("rpc/claim_demo_verdict", {
    method: "POST",
    body: JSON.stringify({ p_id: id, p_visitor_hash: visitorHash, p_ip_hash: ipHash, p_verdict: verdict }),
  });
}

export async function claimResolution(id: string, visitorHash: string, ipHash: string): Promise<boolean> {
  return request<boolean>("rpc/claim_demo_resolution", {
    method: "POST",
    body: JSON.stringify({ p_id: id, p_visitor_hash: visitorHash, p_ip_hash: ipHash }),
  });
}

export async function claimDelivery(row: Record<string, Json>): Promise<boolean> {
  try {
    await request("job_deliveries", {
      method: "POST",
      headers: { Prefer: "return=minimal" },
      body: JSON.stringify(row),
    });
    return true;
  } catch {
    return false;
  }
}
