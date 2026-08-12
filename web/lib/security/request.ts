import "server-only";

import { NextRequest } from "next/server";
import { timingSafeEqual } from "node:crypto";
import { hashBinding, verifyAccessToken, type AccessClaims } from "./tokens";

export const ACCESS_COOKIE = "tripbot_judge";

export function clientIp(request: NextRequest): string {
  const forwarded = request.headers.get("x-forwarded-for")?.split(",")[0]?.trim();
  return (forwarded || request.headers.get("x-real-ip") || "local").slice(0, 64);
}

export function requireSameOrigin(request: NextRequest): void {
  const origin = request.headers.get("origin");
  const host = request.headers.get("x-forwarded-host") || request.headers.get("host");
  if (!origin || !host) throw new Error("A same-origin browser request is required");
  let originHost: string;
  try {
    originHost = new URL(origin).host;
  } catch {
    throw new Error("Invalid request origin");
  }
  if (originHost !== host) throw new Error("Cross-origin request rejected");
}

export function safeSecretEqual(supplied: string, expected: string): boolean {
  const left = Buffer.from(hashBinding(`access:${supplied}`), "hex");
  const right = Buffer.from(hashBinding(`access:${expected}`), "hex");
  return timingSafeEqual(left, right);
}

export function requireJudgeAccess(request: NextRequest): AccessClaims {
  const token = request.cookies.get(ACCESS_COOKIE)?.value;
  if (!token) throw new Error("Judge access is required");
  const claims = verifyAccessToken(token);
  if (claims.ipHash !== hashBinding(clientIp(request))) throw new Error("Judge session binding changed");
  return claims;
}
