# 6. Build sequence

Status: **this file is the single source of truth for "where are we right now."** Update its
checkboxes as work happens — don't let it drift out of sync with the actual repo state. As of
2026-07-26, every box below is unchecked; nothing has been implemented.

## Phase 0 — Baseline

Prerequisites (verified working on this machine 2026-07-26): Node v22.22.2, `gh`
authenticated as CHEF-SAVY, Foundry 1.5.1, Docker 29.6.2. Supabase runs via `npx supabase`
(no global CLI needed) — the seller app hard-depends on it for payment-event persistence and
its realtime dashboard.

**LLM finding (2026-07-26, supersedes the earlier "mock mode" framing):** the shipped
`agent.mts` contains **no LLM code at all** — it's a scripted Gateway payment loop; the
LangChain/DeepAgents agent the README describes never shipped (see
[`04-backend-integration.md`](04-backend-integration.md)). So **no API key is needed for the
baseline, period.** If we later add an LLM judgment layer for the demo, the decision stands:
**Groq free tier** (OpenAI-compatible, ~30 req/min / 1K req/day, tool calling on
`llama-3.3-70b-versatile`), fallback **Gemini free tier** — both verified free as of
2026-07-26, no card required.

- [x] Fork `circlefin/arc-nanopayments` on GitHub. *(2026-07-26 → CHEF-SAVY/arc-nanopayments)*
- [x] Clone it into this project's working tree. *(→ `arc-nanopayments/`)*
- [x] `npm install`; copy `.env.example` → `.env.local`. *(2026-07-26)*
- [x] `npm run generate-wallets`. *(2026-07-26 — buyer `0x6C0f42E1B229746D3AD4445a2700E336a3479072`)*
- [x] Fund the buyer wallet via `faucet.circle.com`. *(2026-07-26 — 20 USDC, visible both as
      native gas balance (18-dec) and via the ERC-20 facade at `0x3600…0000` (6-dec) —
      confirmed same funds, two views)*
- [x] Set up Supabase locally. *(2026-07-26 — full stack up via `npx supabase start`;
      **required a fix**: the repo's migrations rely on default privileges that don't apply
      on a fresh local stack, so service-role inserts failed with "permission denied" —
      added `supabase/migrations/20260726000000_explicit_grants.sql` in the fork)*
- [x] Confirm the buyer→seller x402 flow end-to-end on Arc testnet. *(2026-07-26 — 402 →
      signed authorization → facilitator verify → settle → content + Supabase event row.
      **Required a fix**: the repo's hardcoded `maxTimeoutSeconds: 345600` (4d) now fails
      Circle's facilitator with `authorization_validity_too_short` — the authorization must
      outlive the Gateway Wallet's on-chain `withdrawalDelay` (1209600s = 14d); set to 15d
      in `lib/x402.ts`. Note: each `npm run agent` run strands its remaining Gateway balance
      on a throwaway ephemeral key — our rewiring drops that pattern anyway)*
- [x] `forge init` a `contracts/` Foundry project alongside the fork. *(2026-07-26 —
      forge-std v1.16.2, boilerplate removed, `arc_testnet` RPC in foundry.toml)*
- [x] Install OpenZeppelin + forge-std. *(OpenZeppelin v5.6.1)*
- [ ] Register buyer/seller `agentId`s on the Identity Registry — Arc has a dedicated
      tutorial: `docs.arc.io/arc/tutorials/register-your-first-ai-agent`.
- [ ] Sanity-check the USDC contract's ABI on Arcscan behaves as plain ERC20 —
      `balanceOf`/`transfer` already confirmed working via the faucet + payment flow;
      `approve`/`transferFrom` (what `createJob`/`deposit` actually need) still untested.
- [x] `git init` this repo. *(2026-07-26 — root repo tracks docs + plans; `arc-nanopayments/`
      and `contracts/` are separate nested git repos, ignored at root for now — how to
      compose them into the single public hackathon repo (submodules vs. flattening) is an
      open decision to settle before the first push)*

## Phase 1 — `SellerBond.sol`
Plan: [`02-seller-bond.md`](02-seller-bond.md). Tests: [`05-testing.md`](05-testing.md).
- [ ] Skeleton (signatures only, no bodies) — review together before implementing.
- [ ] `deposit` / `bondOf` against mocks, tests green.
- [ ] `requestWithdrawal` / `completeWithdrawal` / timelock, tests green.
- [ ] `reserve` / `releaseReservation` / `slash`, tests green.
- [ ] Full `SellerBond` suite green before moving to Phase 2.

## Phase 2 — `JobEscrow.sol` (Validation Registry disabled initially)
Plan: [`03-job-escrow.md`](03-job-escrow.md). Tests: [`05-testing.md`](05-testing.md).
- [ ] Skeleton — review together.
- [ ] `createJob` / `release` happy path wired to the real `SellerBond` (two-step deploy).
- [ ] `dispute` / `resolveDispute` including the reservation-slash path.
- [ ] `claimTimeout`.
- [ ] Full suite green with mocked registries.

## Phase 3 — ERC-8004 wiring
- [ ] Pull the real Validation Registry ABI off Arcscan for
      `0xDB31f5d9167f8ebc8B30FbBF814c4d297c2D7F99` — resolve the open question in
      [`01-research-and-decisions.md`](01-research-and-decisions.md) about the exact getter
      name.
- [ ] Add the `requestHash` check to `createJob`.
- [ ] Add `try/catch`-wrapped `validationResponse` calls at `release`/`resolveDispute`/
      `claimTimeout`.
- [ ] Run `ArcForkIntegration.t.sol` against the live registry as a pre-deploy gate.

## Phase 4 — Deploy
**Confirm with the project owner before spending faucet funds or overwriting a prior
deployment — per this project's explicit working rule.**
- [ ] Re-confirm addresses against `docs.arc.io/arc/references/contract-addresses` (don't
      trust the four-plus-day-old values recorded in
      [`01-research-and-decisions.md`](01-research-and-decisions.md)).
- [ ] Deploy `JobEscrow` first.
- [ ] Deploy `SellerBond` with `JobEscrow`'s address baked in.
- [ ] Call `JobEscrow.setSellerBond()` once.
- [ ] Verify both contracts on Arcscan.
- [ ] Record deployed addresses in this file and in the README.

## Phase 5 — Backend rewiring
Plan: [`04-backend-integration.md`](04-backend-integration.md).
- [ ] Can start once Phase 2's interfaces are stable — doesn't need to wait on Phase 3/4 to
      *start*, but needs real deployed addresses to run end-to-end.
- [ ] Buyer side (`agent.mts`).
- [ ] Seller side (`lib/x402.ts`).
- [ ] Optional release → Gateway deposit step.

## Phase 6 — Demo scripts + README
Plan: [`07-demo-and-deployment.md`](07-demo-and-deployment.md),
[`08-disclosures.md`](08-disclosures.md).
- [ ] Can start as soon as Phase 2 is done — decoupled from backend wiring finishing.
- [ ] Raw `cast send` scripts for both demo runs (clean release; dispute + slash).
- [ ] README covering the gap being filled, the honest disclosures, deployed addresses.

## Phase 7 — Stretch (post-Checkpoint-2, only if time allows)
- [ ] Tighter delivery validation (beyond "non-empty, matches request").
- [ ] Seller dashboard polish (the forked repo's existing dashboard, if extended).
- [ ] App Kit bridging as an onboarding flow (explicitly out of MVP scope per
      `PROJECT_OVERVIEW.md` §3).

## Definition of done (from `CLAUDE.md`, restated here for one-glance tracking)
- [ ] `SellerBond.sol` and `JobEscrow.sol` deployed and verified on Arc testnet.
- [ ] Backend actually creating real jobs through the forked agent flow — not a mocked call.
- [ ] Both demo runs (clean release, disputed slash) working end-to-end and recordable.
- [ ] Foundry tests for: bond deposit/withdrawal timelock/slash-only-by-escrow, job creation
      with bond-ratio check, release, dispute, timeout auto-release.
- [ ] README documenting the gap being filled, with the disclosures from
      [`08-disclosures.md`](08-disclosures.md).
