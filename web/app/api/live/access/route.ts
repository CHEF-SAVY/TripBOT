import { NextRequest, NextResponse } from "next/server";
import { assertDemoWriteReady } from "@/lib/security/readiness";
import { ACCESS_COOKIE, clientIp, requireSameOrigin } from "@/lib/security/request";
import { hashBinding, issueAccessToken, verifyAccessToken } from "@/lib/security/tokens";
import { claimAccessAttempt } from "@/lib/storage";

/// Issues the visitor identity the buyer session is bound to.
///
/// There is deliberately no access code. A judged demo that asks for a secret before it will
/// do anything is a demo nobody tries, and the code was never what protected the wallet — the
/// per-IP tour limit, the preflight balance floors, the IP-bound HMAC tokens, and the
/// one-delivery-per-job claim all work exactly the same without it.
///
/// The identity still matters: it is what the tour limiter counts against and what the quote
/// and session tokens are bound to, so a token issued to one visitor cannot be replayed by
/// another.
export async function GET(request: NextRequest) {
  const ipHash = hashBinding(clientIp(request));

  // Return the existing identity untouched when it is still valid and still bound to this
  // address, so a page refresh does not consume a fresh slot from the limiter.
  const existing = request.cookies.get(ACCESS_COOKIE)?.value;
  if (existing) {
    try {
      const claims = verifyAccessToken(existing);
      if (claims.ipHash === ipHash) {
        return NextResponse.json({ authorized: true, expiresAt: claims.exp });
      }
    } catch {
      // Fall through and mint a new one.
    }
  }

  try {
    assertDemoWriteReady();
  } catch {
    // Read-only mode: the page still renders live chain state, there is just nothing to sign.
    return NextResponse.json({ authorized: false, reason: "read-only" });
  }

  // Still rate limited, now against issuing identities rather than guessing a secret.
  if (!(await claimAccessAttempt(ipHash))) {
    return NextResponse.json({ authorized: false, reason: "rate-limited" }, { status: 429 });
  }

  const { token, claims } = issueAccessToken(ipHash);
  const response = NextResponse.json({ authorized: true, expiresAt: claims.exp });
  response.cookies.set(ACCESS_COOKIE, token, {
    httpOnly: true,
    secure: process.env.NODE_ENV === "production",
    sameSite: "strict",
    path: "/",
    maxAge: 6 * 60 * 60,
  });
  return response;
}

/// Clears the identity, which is what actually re-enables a live run for someone who has
/// already used their tour slot.
export async function DELETE(request: NextRequest) {
  try {
    requireSameOrigin(request);
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : "Invalid request" }, { status: 403 });
  }
  const response = NextResponse.json({ authorized: false });
  response.cookies.set(ACCESS_COOKIE, "", { httpOnly: true, sameSite: "strict", path: "/", maxAge: 0 });
  return response;
}
