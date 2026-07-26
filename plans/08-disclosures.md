# 8. Honest disclosures — must land in the final README

Status: **content confirmed, not yet written into a README** (no README exists yet — this
file is the source list for when one gets written in Phase 6).

These are things that would look like unexplained gaps or overclaims if left out. The
project's own working style is to disclose them directly rather than gloss over them.

- **Dispute resolution is single-arbiter (the deployer wallet) for the hackathon** —
  explicitly centralized-for-now, not pretend-decentralized. State this plainly, don't bury it.
- **ERC-8004's Validation Registry spec is itself still under active discussion.** Integration
  is defensively wrapped (`try/catch` behind `validationRegistryEnabled`) specifically so it
  can never brick settlement — explain that this is *why* the wrapping exists, not just that
  it does.
- **Circle Paymaster isn't available on Arc.** Arc's native USDC gas token already satisfies
  the underlying "agents only hold USDC" requirement without it — state the finding and the
  mitigating fact together, not the gap alone.
- **Bond reservation is a real per-job lock, not a cheap ratio-only approximation** — chosen
  deliberately over the faster mitigation once the gap was identified (see finding 5 in
  [`01-research-and-decisions.md`](01-research-and-decisions.md)), because the fix was
  tractable within the build window. Worth stating as a design strength, not just a caveat.
- **Link the x402 FAQ section on escrow being explicit future work** (x402.gitbook.io/x402) —
  this is the direct textual basis for "the gap Tripwire fills."
- **Link/quote Circle's Agent Stack terms of service disclaiming outcome guarantees**
  (agents.circle.com) — the other half of the textual basis for the gap.
- **The withdrawal timelock demo adjustment** — if the recorded demo used a shortened timelock
  (see [`07-demo-and-deployment.md`](07-demo-and-deployment.md)), say so explicitly; the
  production default is 3 days.

## Not disclosures, but should also land in the README

- Deployed contract addresses (from [`06-build-sequence.md`](06-build-sequence.md) Phase 4).
- The architecture diagrams from `PROJECT_OVERVIEW.md` §4 (sequence + state machine), reused
  rather than redrawn.
- A pointer to `IMPLEMENTATION_NOTES.md` for anyone who wants the fully-sourced version of
  every integration decision.
