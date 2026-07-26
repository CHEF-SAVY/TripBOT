# 5. Foundry test plan

Status: **planned, not yet written.** Depends on
[`02-seller-bond.md`](02-seller-bond.md) and [`03-job-escrow.md`](03-job-escrow.md) — write
each contract's tests alongside its implementation, function by function, not as a separate
pass at the end.

## Layout

```
contracts/test/SellerBond.t.sol
contracts/test/JobEscrow.t.sol
contracts/test/mocks/          — mock USDC, mock Identity Registry, mock Validation Registry
contracts/test/ArcForkIntegration.t.sol   — vm.createSelectFork against real Arc testnet + real registries
```

## `SellerBond.t.sol`

- `deposit` credits `bondBalance` correctly (any caller, any recipient agent).
- `requestWithdrawal` reverts if caller isn't the agent's owner/operator.
- `requestWithdrawal` reverts if `amount > bondOf(agentId)` (i.e. respects net-of-reservation).
- `completeWithdrawal` reverts before `unlockTime`, succeeds and pays out after.
- A later global `withdrawalTimelock` change doesn't affect an already-pending request's
  snapshotted `unlockTime`.
- `reserve` / `releaseReservation` / `slash` all revert when called by anything other than the
  `jobEscrow` address.
- `slash` reverts if `amount > reserved[agentId]`.
- **Invariant check**: a pending withdrawal request can never be completed in a way that dips
  into reserved bond — this should be structurally impossible given `bondOf()`'s netting;
  write a test asserting it can't be constructed, as a check on the invariant itself rather
  than a single-path test.

## `JobEscrow.t.sol`

- `createJob` reverts on insufficient bond (via `SellerBond.reserve`'s own revert, not a
  duplicate check in `JobEscrow`).
- `createJob` reverts on a deadline in the past.
- **The property the reservation design exists to guarantee**: two concurrent jobs against the
  same bond both succeed if the bond covers both ratios, and a simultaneous double-dispute-at-
  fault fully slashes both without either reverting.
- `release` / `dispute` / `resolveDispute` / `claimTimeout`: access-control tests (only buyer,
  only arbiter, anyone respectively where specified) and state-machine tests (correct
  preconditions enforced, correct resulting status).
- A reverting/failing `validationResponse` call inside `try/catch` never blocks fund movement
  — test this explicitly by making the mock Validation Registry revert and asserting
  `release`/`resolveDispute`/`claimTimeout` still complete correctly.

## `ArcForkIntegration.t.sol`

`vm.createSelectFork` against the real Arc testnet RPC and the real deployed Identity/
Validation Registry addresses (see [`01-research-and-decisions.md`](01-research-and-decisions.md)
for current values — re-confirm before use). This is a pre-deploy smoke test, not a
unit-test replacement: it exists to catch "the real registry's interface doesn't actually
match what we assumed" before spending faucet funds on a real deploy.

## Commands

```
forge test -vvv                                                              # full unit suite, run after each function
forge test --match-contract ArcForkIntegration --fork-url https://rpc.testnet.arc.network   # before any real deploy
```

## Open questions / assumptions

- Whether the mock Validation Registry needs to faithfully replicate the real two-step
  `validationRequest`/`validationResponse` access control, or can be simplified for unit
  tests as long as the fork test covers the real thing — currently assumed the mock can be
  simplified, since the fork test is what actually gates correctness against the live
  contract.
