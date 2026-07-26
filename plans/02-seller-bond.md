# 2. `SellerBond.sol`

Status: **design confirmed, not yet implemented.** Depends on
[`01-research-and-decisions.md`](01-research-and-decisions.md) — read that first, especially
the per-job reservation rationale (finding 5) before this file makes full sense.

## Purpose

Sellers post USDC stake against their ERC-8004 `agentId` before they're eligible to take
jobs. Bond is **reserved per job**, not just ratio-checked once at creation — this is the one
meaningful departure from the original spec, closing a gap where concurrent jobs against one
bond could each individually pass a ratio check and then simultaneously be un-fundable at
dispute time.

## State

```solidity
IERC20 public immutable usdc;
IIdentityRegistry public immutable identityRegistry;
address public immutable jobEscrow;          // set once, constructor-only — nothing else can ever slash/reserve

address public owner;
uint64  public withdrawalTimelock = 3 days;   // owner-settable; requests snapshot an absolute unlockTime

struct WithdrawalRequest { uint256 amount; uint64 unlockTime; }

mapping(uint256 => uint256) public bondBalance;          // agentId => gross posted
mapping(uint256 => uint256) public reserved;             // agentId => sum locked by active/disputed jobs
mapping(uint256 => WithdrawalRequest) public pendingWithdrawal;
```

`jobEscrow` is set once in the constructor (or via a one-time `setSellerBond`/`setJobEscrow`
pattern to resolve the circular deploy dependency — see
[`06-build-sequence.md`](06-build-sequence.md) Phase 4) and is never owner-mutable after that.
This is the single fact that makes `slash()` safe: nothing but the one audited contract that
called `reserve()` can ever call `slash()`.

## Functions

- **`deposit(agentId, amount)`** — permissionless top-up via `transferFrom`. Anyone can top up
  any agent's bond (useful if a third party wants to back a seller), credits `bondBalance`.
- **`requestWithdrawal(agentId, amount)`** — only the agentId's owner/operator
  (`identityRegistry.isAuthorizedOrOwner(msg.sender, agentId)`); requires
  `amount <= bondOf(agentId)` (already net of reservations); reverts if a request is already
  pending for that agent.
- **`completeWithdrawal(agentId)`** — requires `block.timestamp >= pendingWithdrawal[agentId].unlockTime`;
  pays out and clears the request.
- **`reserve(agentId, amount)`** — `onlyJobEscrow`; reverts `InsufficientBond` if
  `amount > bondOf(agentId)`; adds to `reserved[agentId]`.
- **`releaseReservation(agentId, amount)`** — `onlyJobEscrow`; reverts if
  `amount > reserved[agentId]`; subtracts from `reserved[agentId]`.
- **`slash(agentId, amount, recipient)`** — `onlyJobEscrow`; requires
  `amount <= reserved[agentId]` — this is the invariant that makes reservation meaningful: a
  slash can only ever consume what was actually locked for a specific job. Decrements both
  `bondBalance` and `reserved`, transfers `amount` to `recipient`.
- **`bondOf(agentId)`** — view: `bondBalance[agentId] - pendingWithdrawal[agentId].amount - reserved[agentId]`.
  This is the true "free" bond both `createJob()`'s reservation call and a seller's own
  withdrawal request see.

## Invariants this contract must uphold

1. `reserved[agentId]` can only ever be moved by `JobEscrow` (`onlyJobEscrow` on `reserve`,
   `releaseReservation`, `slash`) — no owner backdoor.
2. `slash(agentId, amount, _)` always requires `amount <= reserved[agentId]` — a slash can
   never exceed what was locked for the job actually being resolved, and can never touch a
   seller's un-reserved free bond.
3. `bondOf()` nets out both `pendingWithdrawal` and `reserved` — a seller can never withdraw
   funds that are either mid-timelock-request or backing an active job.
4. A withdrawal request's `unlockTime` is snapshotted absolutely at request time — a later
   global `withdrawalTimelock` change (e.g. shortened for a demo) never retroactively affects
   an already-pending request.

## Open questions / assumptions

- Exact `IIdentityRegistry` interface/import path for `isAuthorizedOrOwner` — confirm against
  the real `erc-8004-contracts` ABI once cloned (see finding in
  [`01-research-and-decisions.md`](01-research-and-decisions.md)), don't hand-write the
  interface from memory.
- Whether `deposit()` should be restricted to the agent's own owner/operator vs. fully
  permissionless (currently planned permissionless — flag if that's wrong; a permissionless
  top-up means anyone can raise a seller's eligibility, which seems fine but hasn't been
  explicitly discussed).

## Build order (see [`05-testing.md`](05-testing.md) for matching tests)

Skeleton (function signatures, no bodies) → review together → implement in this order, tests
green after each step before moving on:
1. `deposit` / `bondOf`
2. `requestWithdrawal` / `completeWithdrawal` / timelock
3. `reserve` / `releaseReservation` / `slash`
