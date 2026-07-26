# 1. Research findings and locked-in design decisions

Status: **confirmed** (from the 2026-07-21 research session — cloned and read the real repos
and live bytecode, not just docs). Full sourcing with file:line citations lives in
`IMPLEMENTATION_NOTES.md` at the repo root — this file is the condensed, decision-oriented
version to build against.

## Findings that changed the plan from the original `CLAUDE.md` spec

1. **Circle Gateway is a closed-source npm SDK** (`@circle-fin/x402-batching`), not a contract
   that can be read or extended. The buyer's current payment in the forked `arc-nanopayments`
   repo is one opaque `gateway.pay()` call with no seam to intercept mid-flow.
   → **Decision:** job payments bypass Gateway entirely. Buyer does a plain USDC
   `approve`/`transferFrom` into `JobEscrow`. Gateway is only used afterward, backend-side, as
   an optional step to deposit released funds into the seller's Gateway balance — this can
   never be contract logic since Solidity can't call an off-chain SDK/REST API.

2. **ERC-8004's Validation Registry is a two-step, two-party protocol**, confirmed against the
   real deployed contract on Arc testnet (proxy `0x8004Cb1BF31DAf7788923b405b754f57acEB4272`,
   impl `ValidationRegistryUpgradeable` at `0xDB31f5d9167f8ebc8B30FbBF814c4d297c2D7F99`): only
   the exact address named as `validatorAddress` in a prior `validationRequest()` may later
   call `validationResponse()`.
   → **Decision:** `JobEscrow` can't unilaterally attest. The seller self-registers a
   `validationRequest()` naming `JobEscrow` as validator, per job, before `createJob()` will
   accept it — least-privilege, no standing operator approval granted to the contract.

3. **Circle Paymaster does not support Arc at all** (ERC-4337-based; supported networks are
   Arbitrum/Base/Avalanche/Ethereum/Optimism/Polygon/Unichain — Arc absent, no Paymaster
   address anywhere in Arc's docs).
   → **Turns out not to matter:** Arc's native gas token is USDC itself, so "agents only ever
   hold USDC" is already true by Arc's own design. No Paymaster wiring needed.

4. **`circlefin/arc-escrow`** (Circle's own "AI-validated deliverable" sample) is not a useful
   structural template for `JobEscrow.sol` — its contract has no job-state machine, no
   on-chain approval gating, and no timeout logic; the "AI validation" is a pure off-chain
   OpenAI check in front of an unconditional `withdraw()`, never verified on-chain.
   → Confirms our planned design (real state machine + arbiter gating + timeout) is more
   rigorous than Circle's own reference, not a reason to change course.

5. **A gap in the original spec**: the spec only ratio-checked bond at job creation, not
   reserved per-job. Concurrent jobs against one bond could each individually pass the ratio
   check, then a multi-dispute could leave `slash()` unable to cover everything.
   → **Decision:** real per-job bond reservation, not a cheap mitigation — see
   `SellerBond.reserve()`/`releaseReservation()` in [`02-seller-bond.md`](02-seller-bond.md).

## Confirmed live Arc testnet addresses

Independently verified against live bytecode, not assumed from a repo's config table:

| Item | Value |
|---|---|
| RPC | `https://rpc.testnet.arc.network` |
| Chain ID | `5042002` |
| USDC | `0x3600000000000000000000000000000000000000` |
| Gateway Wallet | `0x0077777d7EBA4688BDeF3E311b846F25870A19B9` |
| Identity Registry | `0x8004A818BFB912233c491871b3d84c89A494BD9e` |
| Validation Registry (proxy) | `0x8004Cb1BF31DAf7788923b405b754f57acEB4272` |
| Validation Registry (impl) | `0xDB31f5d9167f8ebc8B30FbBF814c4d297c2D7F99` |
| Explorer | `https://testnet.arcscan.app` |
| Faucet | `https://faucet.circle.com` |

**Re-confirm these against `docs.arc.io/arc/references/contract-addresses` before the actual
deploy in Phase 4** — the project's own working rule is never to deploy from memory, and these
were recorded four-plus days before implementation starts.

## Locked-in design decisions (build against these; don't re-litigate without a reason)

1. **Bond reservation is real, not a ratio-check-only approximation.** `SellerBond` tracks
   `reserved[agentId]` directly. At `createJob()`, `JobEscrow` calls
   `sellerBond.reserve(agentId, requiredBond)` where
   `requiredBond = amount * minBondRatioBps / 10000`; reverts if
   `bondBalance - pendingWithdrawal - reserved < requiredBond`. That exact `requiredBond` is
   stored on the `Job` struct and is the only amount ever slashed or released for that job —
   funds are locked at creation time, so resolution is unconditionally fundable.
2. **Dispute window and timeout grace period are merged into one `responseWindow`**
   (owner-settable, default 48h): buyer can `release()`/`dispute()` any time up to
   `completionDeadline + responseWindow` (including before the deadline itself); after that,
   anyone can `claimTimeout()`.
3. **Seller self-registers validation per job.** Seller's backend calls
   `validationRequest(jobEscrowAddress, sellerAgentId, requestURI, requestHash)` naming
   `JobEscrow` as validator, hands `requestHash` to the buyer in the 402 response.
   `createJob()` takes `requestHash` and verifies it against the registry before activating.
4. **Withdrawal timelock defaults to 3 days**, owner-settable, snapshotted as an absolute
   `unlockTime` at request time (later global changes don't retroactively affect in-flight
   requests). Lower it live (e.g. 60–120s) immediately before recording demo videos —
   document that in the README as a demo-only adjustment.
5. **Other adopted defaults** (low-controversy — flag now if any look wrong):
   - `bondOf()` returns net of both pending withdrawal and reserved amounts.
   - Arbiter and owner are separate state variables (same deployer key for the hackathon, but
     a one-line change to rotate later).
   - Every Validation Registry external call is wrapped in `try/catch` behind an
     owner-toggleable `validationRegistryEnabled` bool — the registry's own spec is "still
     under active discussion," so a flaky registry can never brick fund movement.
   - Two-step deploy order resolves the circular constructor dependency: `JobEscrow` first
     with a one-time `setSellerBond()`, then `SellerBond` with `JobEscrow`'s address baked in
     as `immutable`.
   - `contracts/` (a Foundry project) lives alongside a fork of `arc-nanopayments` at the repo
     root, not nested inside it.

## Open questions / assumptions still to verify before relying on them

- The exact getter name/shape for checking "does this `requestHash` name `JobEscrow` as
  validator" on the Validation Registry — not yet pulled from the real ABI on Arcscan. Do this
  at the start of Phase 3 ([`06-build-sequence.md`](06-build-sequence.md)), don't guess the
  method name.
- The Gateway SDK method that mirrors the existing seller withdraw-flow pattern
  (`app/api/gateway/withdraw/route.ts`) for the optional post-release deposit step — unconfirmed
  until that file is read post-clone.
- `identityRegistry.isAuthorizedOrOwner(msg.sender, agentId)` as the intended access-control
  check for bond deposit/withdrawal — confirmed to exist on the interface, not yet confirmed
  as the *right* one for every call site that needs it.
