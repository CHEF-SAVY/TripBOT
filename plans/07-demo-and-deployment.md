# 7. Deployment, demo runs, and verification

Status: **planned, not yet executed.** Depends on Phases 0–4 of
[`06-build-sequence.md`](06-build-sequence.md) being complete.

## Deployment checklist (Phase 4)

1. Re-confirm every address in [`01-research-and-decisions.md`](01-research-and-decisions.md)
   against `docs.arc.io/arc/references/contract-addresses` — don't deploy from memory.
2. **Ask before deploying** — this spends real faucet funds and, once verified on Arcscan,
   isn't cleanly undoable.
3. Deploy `JobEscrow` → deploy `SellerBond` (with `JobEscrow`'s address baked in as
   `immutable`) → call `JobEscrow.setSellerBond()` once.
4. Verify both contracts on `https://testnet.arcscan.app`.
5. `cast call` each view function (`bondOf`, `jobs`) against the deployed addresses to confirm
   state reads correctly before recording anything else.
6. Record the deployed addresses in [`06-build-sequence.md`](06-build-sequence.md) Phase 4 and
   in the final README.

## Demo script — two runs, both recordable

### Run 1 — clean release
1. Seller deposits bond: `SellerBond.deposit(sellerAgentId, bondAmount)`.
2. Buyer creates a job: `JobEscrow.createJob(...)`, shown on Arcscan as the USDC deposit.
3. Seller delivers via the existing x402 flow.
4. Buyer calls `release(jobId)`.
5. Show the seller's USDC balance move, on Arcscan.

### Run 2 — disputed slash
1. Seller deposits bond (or reuses Run 1's, if bond is high enough net of Run 1's already-
   released reservation).
2. Buyer creates a job.
3. Seller doesn't deliver, or delivers garbage.
4. Buyer calls `dispute(jobId, evidenceHash)`.
5. Arbiter calls `resolveDispute(jobId, sellerAtFault=true)`.
6. Show on Arcscan: the bond getting slashed (`SellerBond.slash` transfer to buyer) and the
   buyer's escrowed principal getting refunded — both in the same `resolveDispute` transaction
   or its immediate effects.

Both runs recorded via terminal output (raw `cast send` scripts, decoupled from whether
backend rewiring is finished — per [`06-build-sequence.md`](06-build-sequence.md) Phase 6)
plus the Arc block explorer showing the deposit, the completion/dispute call, and the
release-or-slash transaction. This is explicitly the whole pitch, not a last-week polish item
— build it as soon as Phase 2's contracts work, don't wait for backend wiring or a frontend.

## Pre-recording adjustment

Lower `withdrawalTimelock` live (e.g. to 60–120 seconds) immediately before recording, so a
withdrawal-timelock demonstration (if included) doesn't require a multi-day wait. Document
this in the README explicitly as a demo-only adjustment, not the production default (3 days).

## Verification checklist (before either demo run is considered "working")

- [ ] `forge test -vvv` full unit suite green.
- [ ] `forge test --match-contract ArcForkIntegration --fork-url https://rpc.testnet.arc.network`
      green against the real registries.
- [ ] Both contracts verified on Arcscan (source matches deployed bytecode).
- [ ] Backend rewiring actually run against the seller app on Arc testnet with faucet funds —
      not a mocked call, per the project's definition of done.
- [ ] Both demo runs recorded end-to-end without manual contract-state patching mid-recording.
