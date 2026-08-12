import "server-only";

import { createHmac, randomUUID, timingSafeEqual } from "node:crypto";
import { z } from "zod";

const sellerKey = z.enum(["honest", "faulty", "absent"]);

const baseClaims = z.object({
  iat: z.number().int().nonnegative(),
  exp: z.number().int().positive(),
});

const accessClaims = baseClaims.extend({
  typ: z.literal("access"),
  visitorId: z.string().uuid(),
  ipHash: z.string().regex(/^[a-f0-9]{64}$/),
});

const quoteClaims = baseClaims.extend({
  typ: z.literal("quote"),
  nonce: z.string().uuid(),
  visitorId: z.string().uuid(),
  ipHash: z.string().regex(/^[a-f0-9]{64}$/),
  sellerKey,
});

const sessionClaims = baseClaims.extend({
  typ: z.literal("session"),
  sessionId: z.string().uuid(),
  visitorId: z.string().uuid(),
  ipHash: z.string().regex(/^[a-f0-9]{64}$/),
  sellerKey,
  jobId: z.string().regex(/^\d+$/),
});

export type AccessClaims = z.infer<typeof accessClaims>;
export type QuoteClaims = z.infer<typeof quoteClaims>;
export type SessionClaims = z.infer<typeof sessionClaims>;

function secret(): string {
  const value = process.env.SESSION_SECRET;
  if (!value || Buffer.byteLength(value) < 32) {
    throw new Error("SESSION_SECRET must contain at least 32 bytes");
  }
  return value;
}

function signature(payload: string): Buffer {
  return createHmac("sha256", secret()).update(payload).digest();
}

function issue(payload: object): string {
  const encoded = Buffer.from(JSON.stringify(payload)).toString("base64url");
  return `${encoded}.${signature(encoded).toString("base64url")}`;
}

function verify<T>(token: string, schema: z.ZodType<T>): T {
  if (token.length > 4_096) throw new Error("Token is too large");
  const [encoded, suppliedSignature, extra] = token.split(".");
  if (!encoded || !suppliedSignature || extra) throw new Error("Malformed token");
  const expected = signature(encoded);
  const supplied = Buffer.from(suppliedSignature, "base64url");
  if (supplied.length !== expected.length || !timingSafeEqual(supplied, expected)) {
    throw new Error("Invalid token signature");
  }
  let decoded: unknown;
  try {
    decoded = JSON.parse(Buffer.from(encoded, "base64url").toString("utf8"));
  } catch {
    throw new Error("Malformed token payload");
  }
  const claims = schema.parse(decoded);
  if ((claims as { exp: number }).exp <= Math.floor(Date.now() / 1_000)) throw new Error("Token expired");
  return claims;
}

function timestamps(ttlSeconds: number) {
  const iat = Math.floor(Date.now() / 1_000);
  return { iat, exp: iat + ttlSeconds };
}

export function hashBinding(value: string): string {
  return createHmac("sha256", secret()).update(`binding:${value}`).digest("hex");
}

export function issueAccessToken(ipHash: string) {
  const claims: AccessClaims = {
    typ: "access",
    visitorId: randomUUID(),
    ipHash,
    ...timestamps(6 * 60 * 60),
  };
  return { token: issue(claims), claims };
}

export function verifyAccessToken(token: string): AccessClaims {
  return verify(token, accessClaims);
}

export function issueQuoteToken(input: Pick<QuoteClaims, "nonce" | "visitorId" | "ipHash" | "sellerKey">) {
  return issue({ typ: "quote", ...input, ...timestamps(15 * 60) });
}

export function verifyQuoteToken(token: string): QuoteClaims {
  return verify(token, quoteClaims);
}

export function issueSessionToken(
  input: Pick<SessionClaims, "sessionId" | "visitorId" | "ipHash" | "sellerKey" | "jobId">,
) {
  return issue({ typ: "session", ...input, ...timestamps(6 * 60 * 60) });
}

export function verifySessionToken(token: string): SessionClaims {
  return verify(token, sessionClaims);
}
