# Tripwire

Escrow-backed job settlement for agent-to-agent USDC payments on Arc — payment releases only on verified delivery, backed by a slashable seller bond.

## Project overview

Tripwire is a settlement layer for agent-to-agent job payments. It plugs into two existing systems, extending rather than replacing them:

- **Circle Nanopayments / x402 on Arc** — payment rails, USDC movement, batch settlement.
- **ERC-8004 ("Trustless Agents")** — portable on-chain agent identity and reputation.

Neither solves conditional, outcome-based payment. x402 payments are irreversible pushes today — escrow-style conditional transfers are explicitly listed as future work in the spec, not built. Circle's own Agent Stack terms of service say plainly that Circle does not guarantee the performance, availability, or outcome of agent-initiated transactions with third parties. That's the exact gap Tripwire fills: money doesn't fully move until the job is verified done, and if it isn't, the seller's own posted stake compensates the buyer.

We deliberately do NOT rebuild spend-limit/policy enforcement — Circle's Agent Wallets already does that (time-bound caps, allowlists, wallet-layer enforcement with 2-of-2 MPC custody). Use it, don't duplicate it.

## Hackathon context

Encode Club, ARC Hackathon, Agentic Economy track. Judging explicitly rewards: agents with decision logic tied to real signals, autonomous USDC settlement, use of Agent Stack for wallets/payments/onchain actions, and use of Nanopayments/Paymaster for agent-to-agent or service payments. Build directly into those — don't route around them.

- Checkpoint 1 — 19 Jul: satisfied by this doc.
- Checkpoint 2 — 26 Jul: contracts deployed to Arc testnet, backend wired to a real job flow.
- Final — 9 Aug: working MVP, public repo, 3-min demo, README, no placeholders.
- Demo: a live job that gets disputed, showing the bond actually pay out — not just theory.

## Tech stack, and how each piece gets used

- **Arc testnet** — deploy target. Pull current RPC + contract addresses from docs.arc.io/arc/references/contract-addresses before every deploy; don't hardcode from memory.
- **Foundry** — build/test/deploy the two new contracts.
- **Circle Nanopayments (Circle Gateway)** — its batch-settlement scheme already deposits buyer funds into on-chain escrow once and redeems vouchers later. Mirror that deposit-then-release shape for JobEscrow rather than inventing a new custody pattern — check the real Gateway contract's deposit flow before writing ours.
- **Circle Paymaster** — sponsors gas for the deposit/release/dispute calls so agents only ever need to hold USDC.
- **Circle Agent Wallets** — this is how the buyer and seller agents hold and move USDC day-to-day (their own custody, spend caps, allowlists). Tripwire's contracts sit downstream of a payment the agent's own wallet already approved — we're not replacing that layer, we're adding what happens after the money leaves it.
- **ERC-8004** — Identity Registry for agent IDs (both buyer and seller register once), Validation Registry as the target for completion/dispute attestations.
- **x402** — unchanged for service discovery/pricing (still how a seller advertises "this costs $X"); what changes is that payment settles into escrow instead of releasing immediately.
- **circlefin/arc-nanopayments** — the fork we extend for the buyer/seller agent and backend, instead of building agents from scratch.

## Setup — do this first

1. Fork `circlefin/arc-nanopayments`, get its buyer agent paying its seller agent for real on Arc testnet, faucet-funded (faucet.circle.com). Confirm the baseline works before changing anything.
2. Check whether ERC-8004 registries already have a reference deployment on Arc testnet. If not, deploy `erc-8004/erc-8004-contracts` yourself and record the addresses.
3. Read the real Circle Gateway batch-settlement deposit/redeem flow and the real ERC-8004 Identity/Validation Registry interfaces before designing anything below against them. Walk me through both — don't assume the shape, confirm it.

## What to build

### SellerBond.sol
Sellers post USDC stake against their ERC-8004 agent ID before they're eligible to take jobs.

- `deposit(agentId, amount)` — pulls USDC via transferFrom, credits the agent's bond balance.
- `requestWithdrawal(agentId, amount)` / `completeWithdrawal(agentId)` — withdrawal goes through a timelock, so a seller can't yank their bond right before a dispute lands.
- `slash(agentId, amount, recipient)` — callable only by JobEscrow's address (set once, not owner-mutable after deploy, so nothing else can drain a seller's bond).
- `bondOf(agentId)` — view, used by JobEscrow to check a seller has enough posted before accepting a job.

### JobEscrow.sol
The core flow. One job = one escrowed payment.

- `createJob(sellerAgentId, amount, completionDeadline)` — buyer calls, USDC moves from buyer into escrow. Reverts if `SellerBond.bondOf(sellerAgentId)` is under some minimum ratio of `amount` (start at 20%, make it configurable — this is a risk parameter, not a fixed constant).
- `release(jobId)` — buyer calls once they've checked the delivered work is good. Pays the seller in full.
- `dispute(jobId, evidenceHash)` — buyer calls instead, within the dispute window. Evidence hash on-chain, not raw evidence.
- `resolveDispute(jobId, sellerAtFault)` — MVP: single arbiter address (your deployer wallet, clearly labeled in the README as centralized-for-now, not pretend-decentralized). Seller at fault: calls `SellerBond.slash()`, buyer refunded from escrow plus the slashed bond. Not at fault: releases to seller as normal.
- `claimTimeout(jobId)` — if the buyer never calls release or dispute within a grace period after the deadline, anyone can trigger auto-release to the seller. Without this a buyer can grief a seller forever by doing nothing — don't skip it.

Once the real ERC-8004 Validation Registry interface is confirmed (setup step 3), wire `release` and `resolveDispute` to also write an attestation there — that's what makes the outcome portable and checkable by other systems, not just internal to this contract.

## Backend integration

Modify the forked repo's existing buyer/seller server code (already TypeScript/Node) — this is a rewiring job, not a new service:

- Buyer's payment call becomes `createJob()` instead of an immediate x402 settle.
- Seller still delivers the service exactly as x402 already does — the HTTP 402 request/response shape doesn't change.
- Buyer's client checks the response it got back, then calls `release()` or `dispute()` accordingly. For a first pass, "good response" can just mean a valid, non-empty result matching what was requested. Tighter validation is a stretch goal.

## Frontend

Default: skip it. Demo via terminal output plus the Arc block explorer showing the deposit, the completion call, and the release-or-slash transaction — that proves the mechanism works and costs no build time. The forked repo's existing seller dashboard is there if there's time left to extend it for a cleaner demo video, but it's not required for anything in the definition of done below.

## Demo script

Two runs, both recordable:

1. A job that completes cleanly — deposit, delivery, release. Show the seller's balance move.
2. A job where the seller doesn't deliver, or delivers garbage — deposit, dispute, resolve, show the bond getting slashed and the buyer refunded.

Build this early. It's the whole pitch, not a last-week polish item.

## How I want to work

- I'm a junior backend dev, strongest in Rust and Go, still building depth in Solidity. Don't assume Solidity idioms are obvious to me, but don't over-explain basic programming concepts either.
- Walk me through design decisions and tradeoffs before writing non-trivial code. I want the reasoning, not just working code.
- Build incrementally: interface or skeleton first, talk it through, then implement. Don't dump a fully-built contract in one shot.
- Flag assumptions explicitly instead of silently picking one.
- Ask before deploying anything to testnet that costs faucet funds or overwrites a prior deployment.

## Definition of done for the hackathon MVP

- `SellerBond.sol` and `JobEscrow.sol` deployed and verified on Arc testnet
- Backend actually creating real jobs through the forked agent flow — not a mocked call
- Both demo runs (clean release, disputed slash) working end-to-end and recordable
- Foundry tests for: bond deposit/withdrawal timelock/slash-only-by-escrow, job creation with bond-ratio check, release, dispute, timeout auto-release
- README documenting the gap being filled — link the x402 FAQ section on escrow being future work, and Circle's own Agent Stack terms disclaiming outcome guarantees — plus an honest note that dispute resolution is single-arbiter for the hackathon, not decentralized

## Reference links

- Arc docs: docs.arc.io
- Arc contract addresses (check before every deploy): docs.arc.io/arc/references/contract-addresses
- Arc testnet faucet: faucet.circle.com
- Circle Agent Stack: agents.circle.com
- Circle Nanopayments reference app: github.com/circlefin/arc-nanopayments
- ERC-8004 reference contracts: github.com/erc-8004/erc-8004-contracts
- ERC-8004 spec: eips.ethereum.org/EIPS/eip-8004
- x402 spec/FAQ: x402.gitbook.io/x402
