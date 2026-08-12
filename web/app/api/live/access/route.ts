import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";
import { assertDemoWriteReady } from "@/lib/security/readiness";
import { ACCESS_COOKIE, clientIp, requireSameOrigin, safeSecretEqual } from "@/lib/security/request";
import { hashBinding, issueAccessToken, verifyAccessToken } from "@/lib/security/tokens";
import { claimAccessAttempt } from "@/lib/storage";

const bodySchema = z.object({ code: z.string().min(1).max(128) }).strict();

export async function GET(request: NextRequest) {
  try {
    const token = request.cookies.get(ACCESS_COOKIE)?.value;
    if (!token) return NextResponse.json({ authorized: false });
    const claims = verifyAccessToken(token);
    return NextResponse.json({ authorized: claims.ipHash === hashBinding(clientIp(request)) });
  } catch {
    return NextResponse.json({ authorized: false });
  }
}

export async function POST(request: NextRequest) {
  try {
    requireSameOrigin(request);
    assertDemoWriteReady();
    const body = bodySchema.parse(await request.json());
    if (!(await claimAccessAttempt(hashBinding(clientIp(request))))) {
      return NextResponse.json({ error: "Too many access attempts. Try again later." }, { status: 429 });
    }
    const expected = process.env.DEMO_ACCESS_CODE;
    if (!expected || !safeSecretEqual(body.code, expected)) {
      return NextResponse.json({ error: "That judge access code is not valid." }, { status: 401 });
    }
    const { token, claims } = issueAccessToken(hashBinding(clientIp(request)));
    const response = NextResponse.json({ authorized: true, expiresAt: claims.exp });
    response.cookies.set(ACCESS_COOKIE, token, {
      httpOnly: true,
      secure: process.env.NODE_ENV === "production",
      sameSite: "strict",
      path: "/",
      maxAge: 6 * 60 * 60,
    });
    return response;
  } catch (error) {
    console.error("Judge access setup failed", error);
    return NextResponse.json({ error: "The funded buyer demo is not ready yet." }, { status: 503 });
  }
}

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
