import "server-only";

import { Agent, request as undiciRequest } from "undici";

type Json = null | boolean | number | string | Json[] | { [key: string]: Json };

/// Storage goes through undici directly for the same reason chain access does: Next's patched
/// global fetch does not reuse the connection pool, so every call re-paid a TLS handshake and
/// then died on undici's ten-second connect timeout. Keeping one keep-alive pool turns that
/// into a single handshake for the life of the process.
const storageAgent = new Agent({
  connect: { timeout: 20_000 },
  keepAliveTimeout: 60_000,
  keepAliveMaxTimeout: 300_000,
  connections: 6,
});

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

type StorageInit = { method: string; body?: string; headers?: Record<string, string> };

async function request<T>(path: string, init: StorageInit): Promise<T> {
  const { base, key } = config();
  const response = await undiciRequest(`${base}/rest/v1/${path}`, {
    method: init.method as "GET" | "POST" | "PATCH" | "DELETE",
    body: init.body,
    headers: {
      apikey: key,
      authorization: `Bearer ${key}`,
      "content-type": "application/json",
      ...init.headers,
    },
    dispatcher: storageAgent,
    // Generous enough to absorb a cold connection and a PostgREST schema-cache reload, both
    // of which land on the first visitor after a deploy and were measured at 6-15s. Still
    // well below the routes' maxDuration, so a genuinely hung call fails the request rather
    // than the whole invocation.
    headersTimeout: 15_000,
    bodyTimeout: 15_000,
  });
  if (response.statusCode >= 400) {
    const body = (await response.body.text()).slice(0, 500);
    console.error("Demo storage request failed", response.statusCode, body);
    throw new Error("Durable demo storage operation failed");
  }
  // Writes ask for `Prefer: return=minimal`, which PostgREST answers with 201 and an empty
  // body rather than 204, so status alone is not a reliable test for "nothing to parse".
  // Reading the body first and only parsing when it is non-empty covers both, and stops a
  // successful insert from surfacing as a JSON syntax error.
  const text = await response.body.text();
  if (!text) return undefined as T;
  return JSON.parse(text) as T;
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

export async function claimSignerLease(role: string, holder: string, ttlSeconds: number): Promise<boolean> {
  return request<boolean>("rpc/claim_signer_lease", {
    method: "POST",
    body: JSON.stringify({ p_role: role, p_holder: holder, p_ttl_seconds: ttlSeconds }),
  });
}

export async function releaseSignerLease(role: string, holder: string): Promise<boolean> {
  return request<boolean>("rpc/release_signer_lease", {
    method: "POST",
    body: JSON.stringify({ p_role: role, p_holder: holder }),
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
