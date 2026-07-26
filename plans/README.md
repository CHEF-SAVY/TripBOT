# Tripwire — build plans

This folder is the actionable, modular breakdown of how Tripwire gets built. It exists
separately from `PROJECT_OVERVIEW.md` (the pitch-level summary) and `IMPLEMENTATION_NOTES.md`
(the sourced research reference) at the repo root — those explain *what* Tripwire is and
*why* each design decision was made; this folder is *how* we actually build it, broken into
pieces small enough to review, confirm, and implement one at a time without losing track of
where we are.

## Why it's split this way

One giant plan file invites the same problem as one giant contract: you can't hold it all in
your head at once, so mistakes hide in the parts you skimmed. Each file below covers exactly
one module or phase. Read one, agree on it, implement it, get its tests green, then move to
the next. Don't jump ahead — a later file sometimes assumes an earlier one's interface is
already settled.

## Files, in the order they should be read/built

| # | File | Covers | Depends on |
|---|---|---|---|
| 1 | [`01-research-and-decisions.md`](01-research-and-decisions.md) | Confirmed facts about Circle Gateway, ERC-8004, Paymaster, Arc that override the original spec's assumptions, plus the design decisions already locked in against them | — |
| 2 | [`02-seller-bond.md`](02-seller-bond.md) | `SellerBond.sol` — state, functions, invariants, open questions | 1 |
| 3 | [`03-job-escrow.md`](03-job-escrow.md) | `JobEscrow.sol` — state, functions, invariants, open questions | 1, 2 |
| 4 | [`04-backend-integration.md`](04-backend-integration.md) | Rewiring the forked `arc-nanopayments` buyer/seller agents onto the contracts | 2, 3 |
| 5 | [`05-testing.md`](05-testing.md) | Foundry test plan for both contracts, including the fork-test pre-deploy gate | 2, 3 |
| 6 | [`06-build-sequence.md`](06-build-sequence.md) | Phase-by-phase build order (Phase 0–7) with a status checkbox per phase — the single source of truth for "where are we right now" | all above |
| 7 | [`07-demo-and-deployment.md`](07-demo-and-deployment.md) | Deploy steps, both demo runs, and the verification checklist before either | 6 |
| 8 | [`08-disclosures.md`](08-disclosures.md) | Honest-disclosure notes that must land in the final README | — |

## Status as of 2026-07-26

**Nothing has been implemented yet.** No git repo, no Foundry project, no clone of
`arc-nanopayments` in this working tree. Everything in this folder is *design*, carried
over from the research/design session on 2026-07-21 and reorganized into this modular form
today. Current position: **Phase 0** of [`06-build-sequence.md`](06-build-sequence.md) —
fork and clone `arc-nanopayments`, confirm its unmodified x402 flow works end-to-end on Arc
testnet before writing a line of Solidity.

## Working rules for this folder

- **Confirm before implementing.** Each contract/module file gets read and agreed on before
  its corresponding code is written — per the project's stated working style (skeleton first,
  talk it through, implement incrementally).
- **Flag assumptions, don't silently resolve them.** Every file below has an "Open questions /
  assumptions" section where anything not yet independently verified is called out explicitly
  rather than guessed at.
- **Update `06-build-sequence.md`'s checkboxes as phases complete** — that file is the one
  piece of ground truth for progress; don't let it drift out of sync with what's actually
  been built.
- **Nothing gets committed/pushed until the relevant plan file is confirmed.** These plans are
  the checkpoint gate the project owner asked for before code lands in git history.
- **One branch per plan (added 2026-07-26).** Every plan that produces code is implemented on
  its own branch, named after the plan file, and merged into `main` with `--no-ff` only when
  its work is done and its tests are green. That keeps `main` always-working and makes bug
  hunting clean: `git log --first-parent main` reads as one merge per plan, so a regression
  points straight at the plan that introduced it, and `git bisect` can then dig inside just
  that branch's commits.
  - `phase-0-baseline` — remaining Phase 0 verification work (agent registration, USDC
    `approve`/`transferFrom` check)
  - `plan-02-seller-bond` — `SellerBond.sol` + its unit tests
  - `plan-03-job-escrow` — `JobEscrow.sol` + its unit tests + the fork test
  - `plan-04-backend-integration` — the buyer/seller rewiring
  - `plan-07-demo-deployment` — deploy scripts + demo `cast` scripts
  - Plans 01, 05, 06, 08 don't get branches: 01/08 are reference docs, 06 is the progress
    tracker (its checkbox updates ride along on whichever branch did the work), and 05's
    tests are written alongside the contracts on the 02/03 branches, not as a separate
    effort.
  - Edits to the plan documents themselves go straight to `main` — branching a text edit
    adds ceremony without debugging value.
