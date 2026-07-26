# 3. `JobEscrow.sol`

Status: **design confirmed, not yet implemented.** Depends on
[`01-research-and-decisions.md`](01-research-and-decisions.md) and
[`02-seller-bond.md`](02-seller-bond.md) — `JobEscrow` is the only caller allowed to move a
seller's reserved bond, so its interface assumes `SellerBond`'s is already settled.

## Purpose

One job = one escrowed payment. Buyer's USDC sits here until the buyer releases it, an
arbiter resolves a dispute in the seller's favor, or a timeout auto-releases it — never
before.

## State

```solidity
enum JobStatus { None, Active, Released, Disputed, Resolved, TimedOut }

struct Job {
    address buyer;
    uint256 sellerAgentId;
    address sellerPayoutAddress;   // snapshotted via identityRegistry.ownerOf() at creation
    uint256 amount;
    uint256 reservedBond;          // amount * minBondRatioBps / 10000 at creation time — fixed for this job's lifetime
    uint64  completionDeadline;
    JobStatus status;
    bytes32 validationRequestHash;
    bytes32 evidenceHash;
}

IERC20 public immutable usdc;
IIdentityRegistry public immutable identityRegistry;
IValidationRegistry public immutable validationRegistry;
address public immutable arbiter;
address public owner;
ISellerBond public sellerBond;                 // settable exactly once post-deploy

bool    public validationRegistryEnabled = true;
uint256 public minBondRatioBps = 2000;          // 20% default, owner-settable
uint64  public responseWindow = 48 hours;       // owner-settable

mapping(uint256 => Job) public jobs;
uint256 public nextJobId;
```

## Functions

```solidity
function createJob(uint256 sellerAgentId, uint256 amount, uint64 completionDeadline, bytes32 validationRequestHash) external returns (uint256 jobId);
function release(uint256 jobId) external;                          // onlyBuyer, status==Active
function dispute(uint256 jobId, bytes32 evidenceHash) external;    // onlyBuyer, status==Active, before deadline+responseWindow
function resolveDispute(uint256 jobId, bool sellerAtFault) external; // onlyArbiter, status==Disputed
function claimTimeout(uint256 jobId) external;                     // anyone, status==Active, now > deadline+responseWindow
```

### `createJob`
Validates `amount > 0`, `completionDeadline > now`. If `validationRegistryEnabled`, verifies
`validationRequestHash` names this contract as validator for `sellerAgentId` (exact getter
name TBD — pull the real ABI off Arcscan for `0xDB31f5d9167f8ebc8B30FbBF814c4d297c2D7F99`
before writing this check; see the open question in
[`01-research-and-decisions.md`](01-research-and-decisions.md)). Snapshots
`sellerPayoutAddress = identityRegistry.ownerOf(sellerAgentId)`. Computes
`reservedBond = amount * minBondRatioBps / 10000` and calls
`sellerBond.reserve(sellerAgentId, reservedBond)` — reverts here if bond is insufficient (no
separate ratio check needed in `JobEscrow`; `SellerBond` is the source of truth). Pulls
`amount` USDC via `SafeERC20.safeTransferFrom`.

### `release`
Pays `sellerPayoutAddress` the full `amount`. Calls
`sellerBond.releaseReservation(sellerAgentId, reservedBond)`. `try/catch`-wrapped
`validationResponse(..., 100, ..., "RELEASED")`.

### `dispute`
Records `evidenceHash` (the hash, not raw evidence), flips status to `Disputed`. No fund
movement yet — that only happens on `resolveDispute`.

### `resolveDispute(sellerAtFault=true)`
`sellerBond.slash(sellerAgentId, reservedBond, buyer)`; separately refunds the escrowed
`amount` to `buyer` from `JobEscrow`'s own holdings; `try/catch`-wrapped low-score
`validationResponse(..., 0, ..., "SELLER_AT_FAULT")`.

### `resolveDispute(sellerAtFault=false)` / `claimTimeout`
Same payout path as `release` — pay seller, release reservation, optimistic
`validationResponse`.

## Invariants this contract must uphold

1. Every job's `reservedBond` is fixed at creation and is the *only* amount ever slashed or
   released for that job — no recomputation later, no partial-slash fallback needed.
2. A job's status only ever moves forward through the state machine below — never backward,
   never skips a required precondition.
3. A Validation Registry call failing (reverting) must never block fund movement — every call
   into it is `try/catch`-wrapped behind `validationRegistryEnabled`.
4. `dispute`/`release` are only callable before `completionDeadline + responseWindow`;
   `claimTimeout` is only callable after it — the two are mutually exclusive by construction,
   not by a race that could double-pay.

## Job state machine

```mermaid
stateDiagram-v2
    [*] --> Active: createJob()
    Active --> Released: release() — buyer
    Active --> Disputed: dispute() — buyer
    Active --> TimedOut: claimTimeout() — anyone, after deadline+responseWindow
    Disputed --> Resolved: resolveDispute() — arbiter
    Released --> [*]
    TimedOut --> [*]
    Resolved --> [*]
```

## Full flow (happy path + both failure paths)

```mermaid
sequenceDiagram
    participant Buyer as Buyer Agent
    participant Seller as Seller Agent
    participant JE as JobEscrow.sol
    participant SB as SellerBond.sol
    participant VR as ERC-8004 Validation Registry

    Note over Seller,SB: one-time setup
    Seller->>SB: deposit(sellerAgentId, bondAmount)

    Buyer->>Seller: GET /premium/quote (unauthenticated)
    Seller->>VR: validationRequest(JobEscrow, sellerAgentId, requestHash)
    Seller-->>Buyer: 402 { price, sellerAgentId, requestHash, jobEscrowAddress }

    Buyer->>JE: usdc.approve(JobEscrow, amount)
    Buyer->>JE: createJob(sellerAgentId, amount, deadline, requestHash)
    JE->>SB: reserve(sellerAgentId, requiredBond)
    JE-->>Buyer: jobId

    Buyer->>Seller: retry request, presenting jobId
    Seller->>JE: view jobs(jobId) — confirm Active
    Seller-->>Buyer: deliver result

    alt buyer satisfied
        Buyer->>JE: release(jobId)
        JE->>Seller: transfer(amount)
        JE->>SB: releaseReservation(sellerAgentId, requiredBond)
        JE->>VR: validationResponse(100, "RELEASED")
    else buyer disputes
        Buyer->>JE: dispute(jobId, evidenceHash)
        Note over JE: arbiter reviews evidenceHash off-chain
        JE->>SB: slash(sellerAgentId, requiredBond, buyer)
        JE->>Buyer: refund(amount)
        JE->>VR: validationResponse(0, "SELLER_AT_FAULT")
    else buyer does nothing
        Note over JE: after deadline + responseWindow
        JE->>JE: anyone calls claimTimeout(jobId)
        JE->>Seller: transfer(amount)
    end
```

## Open questions / assumptions

- Validation Registry getter name for the `createJob` validator check — see
  [`01-research-and-decisions.md`](01-research-and-decisions.md).
- Whether `sellerPayoutAddress` should re-read `identityRegistry.ownerOf()` at payout time
  instead of using the value snapshotted at `createJob()` — currently planned as
  snapshot-at-creation (protects a job in flight from an agent ownership transfer mid-job);
  flag if that's the wrong tradeoff.

## Build order (see [`05-testing.md`](05-testing.md) for matching tests)

Validation registry disabled initially: skeleton → review → `createJob`/`release` happy path
wired to the real `SellerBond` (two-step deploy) → `dispute`/`resolveDispute` including the
reservation-slash path → `claimTimeout`. Full suite green with mocked registries before
Phase 3 wires in the real Validation Registry.
