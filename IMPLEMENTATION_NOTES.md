# Tripwire — Implementation Notes: what we're using, how, why, and where the facts came from

This is the companion to `PROJECT_OVERVIEW.md`. That doc is the pitch-level summary; this one is the working reference — for every product Arc/Circle put on the track's checklist, plus ERC-8004 and one dead-end we investigated, it lays out **exactly how it plugs into Tripwire mechanically**, **why that's the right call**, and **the specific source** (repo path + line numbers, or URL) each fact came from, so any of this can be independently re-checked as we build.

Three repos were cloned read-only into a scratch directory during research (not yet part of this project's actual working tree):
- `circlefin/arc-nanopayments` — the fork target
- `erc-8004/erc-8004-contracts` — the identity/validation registry reference
- `circlefin/arc-escrow` — investigated as a possible escrow template, turned out not to be one (see §9)

---

## 1. Arc

**What it is:** Circle's L1 network. Testnet chain ID `5042002`.

**How Tripwire implements it:** It's the deploy target, full stop — both `SellerBond.sol` and `JobEscrow.sol` live here and nowhere else. Every contract call in the system (bond deposits, job creation, release, dispute, slash) is a transaction on this chain. `foundry.toml` will point at Arc testnet's RPC for all `forge script`/`forge test --fork-url` operations.

**Why it matters here:** It's not optional — the track requires deployment on Arc specifically, and Arc's one distinguishing property we actually lean on is that its native gas token is USDC (see §2), which removes an entire category of "how does the agent pay for gas" problem other chains would force us to solve separately.

**Sources:**
- `https://docs.arc.io/arc/references/connect-to-arc` — RPC `https://rpc.testnet.arc.network`, chain ID `5042002`, explorer `testnet.arcscan.app`, faucet `faucet.circle.com` (fetched directly, cross-checked against the forked repo's hardcoded values — all matched exactly)
- `https://docs.arc.io/arc/references/contract-addresses` — canonical address list for anything already deployed on Arc

---

## 2. USDC

**What it is:** The settlement currency, and — specific to Arc — also the network's native gas token.

**How Tripwire implements it:** Every fund movement in both contracts is a `USDC.transferFrom`/`transfer` call via OpenZeppelin's `SafeERC20` against the address below. There is no other token anywhere in the system.

**Why it matters here:** Bond deposits, job escrow, releases, refunds, and slashes are all the same asset — no exchange-rate or bridging logic needed internally. And because it's also Arc's gas token, "the agent only ever needs to hold USDC" (a literal Agent Stack selling point) is true here without any extra plumbing.

**Sources:**
- `https://docs.arc.io/arc/references/contract-addresses` — USDC address `0x3600000000000000000000000000000000000000`
- Arc's native gas token being USDC (18 decimals) — confirmed both in `docs.arc.io/arc/references/connect-to-arc` and independently in the forked repo's own comment: `arc-nanopayments/agent.mts:77` ("Arc testnet gas = USDC with 18 decimals")

---

## 3. Agent Stack

**What it is:** Circle's umbrella term for the agent-facing tooling — Wallets, Paymaster, Gateway, App Kits, Contracts — marketed as one connected stack.

**How Tripwire implements it:** Not a single SDK call — it's the category the buyer and seller agents' wallets belong to (§4). Tripwire's own contracts are explicitly downstream of whatever the agent's Agent Stack wallet already approved; we don't call anything under this umbrella directly except through the specific products below.

**Why it matters here:** This is the framing the project deliberately doesn't fight — Circle's Agent Wallets already do spend-limit/policy enforcement, so Tripwire's job is exactly what's left over: what happens *after* the wallet lets a payment out the door.

**Sources:**
- `https://agents.circle.com` (referenced in this project's own CLAUDE.md reference list)
- `https://developers.circle.com/agent-stack/agent-wallets`

---

## 4. Circle (Agent) Wallets

**What it is:** Developer-Controlled Wallets with 2-of-2 MPC custody (Circle holds one key-share, the user/agent-owner holds the other — no single party can move funds alone), time-bound USDC spend limits, and recipient allowlists/blocklists enforced at the wallet layer before a transaction executes.

**How Tripwire implements it:** The forked repo already provisions one wallet each for buyer and seller — `arc-nanopayments/generate-wallets.mts` creates the keypairs, and `.env` holds `SELLER_ADDRESS`/`SELLER_PRIVATE_KEY`, `BUYER_ADDRESS`/`BUYER_PRIVATE_KEY`. Tripwire's contracts never touch this layer directly; they just receive calls from whatever address these wallets sign with (`msg.sender` in `createJob`, `release`, etc.).

**Why it matters here:** This is where "the agent only holds USDC" and "a human retains ultimate veto power" both actually live. We deliberately do **not** rebuild any of this — no spend caps, no allowlists, no MPC — inside `JobEscrow.sol` or `SellerBond.sol`. Duplicating it would be redundant and worse than what Circle already ships.

**Sources:**
- `https://developers.circle.com/agent-stack/agent-wallets` (2-of-2 MPC, spend limits, allowlists confirmed here)
- `arc-nanopayments/generate-wallets.mts` and `arc-nanopayments/README.md:44-50` (wallet generation + faucet funding steps, from the cloned repo)

---

## 5. App Kits

**What it is:** `@circle-fin/app-kit` — a small TypeScript SDK (plus adapter packages like `@circle-fin/adapter-viem-v2`) covering four capabilities: **Bridge** (cross-chain USDC via CCTP), **Swap**, **Send** (single-chain wallet-to-wallet), and **Unified Balance** (combine USDC held on multiple chains into one chain-abstracted balance).

**How Tripwire implements it (if at all):** Not on the MVP critical path. If used, it would be a Phase 7 stretch item: bridging buyer/seller USDC onto Arc testnet from another chain via `kit.bridge({from:{chain:"Ethereum_Sepolia"}, to:{chain:"Arc_Testnet"}, amount})`, before either agent ever calls `SellerBond.deposit()` or `JobEscrow.createJob()`. The MVP demo doesn't need this — `faucet.circle.com` funds wallets directly on Arc.

**Why it matters here:** Genuinely optional for the MVP. Worth flagging as a real, documented option if there's spare time and a cross-chain funding story would strengthen the demo — but not a load-bearing piece of the core mechanism.

**Sources:**
- `https://docs.arc.io/app-kit` (SDK reference, install/usage snippet, `"Arc_Testnet"` as a named chain constant)
- `https://www.arc.io/blog/app-kits-a-suite-of-sdks-to-build-onchain`
- `https://community.arc.network/public/blogs/ship-stablecoin-apps-faster-app-kits`
- `https://community.arc.io/public/blogs/quickstart-spotlight-bridge-usdc-to-arc-with-cctp-bridge-kit` (flagship tutorial is bridging *to* Arc Testnet specifically)

---

## 6. Circle Contracts (formerly "Smart Contract Platform")

**What it is:** A no-code console plus API/SDK (`@circle-fin/smart-contract-platform`) for deploying and managing smart contracts — either audited pre-built templates (ERC-20/721/1155/Airdrop) or your own compiled bytecode + ABI — with built-in wallet-signed deployment, event-webhook monitoring, and Gas Station-sponsored gas.

**How Tripwire implements it:** **We're using Foundry instead**, per this project's own explicit tech-stack choice — `forge build`/`forge test`/`forge script` for compiling, testing, and deploying both contracts directly via RPC. This is a deliberate choice, not an oversight: Foundry gives a standard, git-versioned, locally-reproducible dev loop (`forge test -vvv`, `cast call`) that's better suited to actually learning Solidity through this build than a closed console would be. Circle Contracts remains available as a legitimate *alternative* deployment path — swapping in `@circle-fin/smart-contract-platform` to push our compiled bytecode+ABI the same way `arc-escrow`'s backend does (see §9) — if we want to explicitly lean on it as a second "core product" checkbox for judging.

**Why it matters here:** Confirmed live on Arc Testnet since roughly December 2025, with Gas Station auto-sponsoring deployment gas for dev-controlled wallets — a real, if narrower, gasless story that does exist on Arc today (distinct from Paymaster, which doesn't — see §8). If we ever revisit the deploy mechanism, this is where we'd go, and it's a fairly small swap since we'd just be feeding it the same compiled artifacts Foundry already produces.

**Sources:**
- `https://developers.circle.com/products` (current name: "Contracts — Build and manage smart contracts")
- `https://developers.circle.com/w3s/smart-contract-platform`
- `https://www.circle.com/blog/circle-launches-smart-contract-platform-gas-station`
- `https://www.altcoinbuzz.io/cryptocurrency-news/circle-contracts-now-supports-arc-testnet-for-developers/` (dated ~Dec 6, 2025 Arc Testnet rollout announcement)
- `https://docs.arc.io/arc/tutorials/deploy-contracts` and `https://community.arc.io/public/blogs/quickstart-spotlight-deploy-an-erc-20-on-arc-using-circle-contracts` (Arc-specific tutorial, templates-only — custom-bytecode-on-Arc isn't directly demonstrated there, though documented as generally supported)
- `arc-escrow/lib/utils/smart-contract-platform-client.ts:20-24` and `arc-escrow/app/api/contracts/escrow/route.ts:112-131` (cloned repo — shows the actual SDK call pattern for pushing custom bytecode through this product)

---

## 7. Nanopayments (Circle Gateway)

**What it is:** Batched, off-chain-signed, on-chain-settled micropayments, accessed exclusively through a closed-source npm SDK (`@circle-fin/x402-batching`) — not a contract we can read or extend. On Arc testnet, its on-chain anchor is the Gateway Wallet contract, used only as EIP-712 signing metadata.

**How Tripwire implements it:** Kept **unchanged** for the 402 discovery/pricing step (a seller still quotes "$0.001" the same way). **Bypassed entirely for the actual job-payment settlement step** — the buyer calls `JobEscrow.createJob()` with a plain `usdc.approve()`/`transferFrom` instead of the SDK's `gateway.pay()`. Optionally reintroduced *after* a job resolves: the seller's backend can deposit the released funds into their Gateway balance via `gateway.deposit()`, the same direction the existing seller withdraw flow already uses in reverse.

**Why it matters here:** This is the one product where "how we use it" required correcting the original assumption. The spec initially imagined mirroring Gateway's on-chain deposit/release shape directly — but Gateway's actual settlement is a single opaque call with no seam to intercept mid-flow, and its whole point is instant, irreversible settlement, which is the exact thing Tripwire exists to not do for job payments. So it stays for what it's genuinely good at (cheap, high-frequency pricing calls) and steps aside for the one payment that needs to be conditional.

**Sources:**
- `arc-nanopayments/agent.mts:159-297` — buyer-side `GatewayClient.deposit()`/`.pay()` calls, deposit/redeposit logic
- `arc-nanopayments/lib/x402.ts:19-192` — seller-side `withGateway()` wrapper, `BatchFacilitatorClient.verify()`/`.settle()`, EIP-712 domain constants (`lib/x402.ts:23-26,56-59`) including the confirmed Gateway Wallet address `0x0077777d7EBA4688BDeF3E311b846F25870A19B9`
- `arc-nanopayments/app/api/gateway/{balance,withdraw}/route.ts` — the existing withdraw-direction pattern our post-release deposit orchestration will mirror
- `README.md:5` (arc-nanopayments) — "Circle Gateway batches many signed offchain authorizations into a single onchain settlement"

---

## 8. Paymaster

**What it is:** ERC-4337 (account abstraction) gas sponsorship — a Paymaster contract fronts gas for a UserOperation and deducts USDC from the user's smart contract account instead.

**How Tripwire implements it:** Not implemented, deliberately. Checked directly against Circle's published supported-networks list — Arc isn't on it (Arbitrum, Base, Avalanche, Ethereum, Optimism, Polygon, Unichain are). No Paymaster contract address exists anywhere on Arc's own docs either.

**Why it matters here:** This would look like a gap if left unexplained, so it's disclosed directly rather than glossed over — but it's a non-issue in practice, because Arc's native gas token already *is* USDC (§2). The thing Paymaster exists to guarantee elsewhere ("agents never need to hold a separate gas currency") is already true on Arc by construction. Worth noting Circle Contracts' own Gas Station (§6) does sponsor gas on Arc Testnet for its dev-controlled wallets specifically — a different, narrower mechanism that does work here, just not Paymaster itself.

**Sources:**
- `https://developers.circle.com/paymaster` (ERC-4337 mechanism, supported-network list)
- `https://www.circle.com/blog/introducing-circle-paymaster`
- `https://docs.arc.io/arc/references/contract-addresses` (cross-checked — no Paymaster address listed)
- `https://docs.arc.io/arc/references/connect-to-arc` (confirms USDC as native gas token, 18 decimals)

---

## 9. ERC-8004 (Identity + Validation Registry) — required by the spec, not a track "core product"

**What it is:** A portable on-chain agent identity standard. Identity Registry is an ERC-721 contract where `agentId` is the token ID; Validation Registry is a two-step, two-party attestation protocol.

**How Tripwire implements it:**
- `SellerBond.sol` keys every bond balance by `agentId` (`uint256`), and validates a caller controls a given agentId via `identityRegistry.isAuthorizedOrOwner(msg.sender, agentId)` — this reverts automatically for a nonexistent agentId, doubling as the existence check.
- `JobEscrow.createJob()` requires the seller to have already called `validationRequest(jobEscrowAddress, sellerAgentId, requestURI, requestHash)` naming `JobEscrow` as the validator; only that exact contract address can later call `validationResponse()` for that hash. This is why the seller-self-registers-per-job model was chosen over having `JobEscrow` request on the seller's behalf — the latter would require the seller to grant the contract standing operator approval over their identity NFT, which is more privilege than necessary.

**Why it matters here:** Gives Tripwire a standardized, portable agent identity instead of inventing a proprietary registry, and makes job outcomes checkable by *other* systems through the Validation Registry — not just something internal to our own contract's storage.

**Sources:**
- `erc-8004-contracts/contracts/IdentityRegistryUpgradeable.sol:60-79` (three `register()` overloads), `:126,132,205` (`getAgentWallet`, `setAgentWallet`, `isAuthorizedOrOwner`)
- `erc-8004-contracts/contracts/ValidationRegistryUpgradeable.sol:69-133` (`initialize`, `validationRequest`, `validationResponse`), `:135-187` (read-side getters)
- `erc-8004-contracts/scripts/custom-chains.ts:32-37,67-71` and `erc-8004-contracts/scripts/addresses.ts:59,67-71` — Arc Testnet chain ID `5042002` classified under `TESTNET_CHAIN_IDS`, resolving to the shared testnet registry addresses
- Live confirmation (not just trusting the repo): `https://testnet.arcscan.app/api/v2/addresses/0x8004Cb1BF31DAf7788923b405b754f57acEB4272` — Blockscout API call confirming a verified `ERC1967Proxy` with implementation `ValidationRegistryUpgradeable` actually deployed at that address, not merely listed in a config file

---

## 10. `arc-escrow` — investigated as a possible template, ruled out (worth recording why)

**What it is:** Circle's own sample app claiming a "deposit → AI-validated deliverable submission → release/refund" flow via an "EIP-712 Refund Protocol."

**Why we looked:** Circle's Arc contract-addresses page lists an on-chain `FxEscrow` contract, which sent us looking for other Circle escrow patterns — that search surfaced this separate sample repo, whose README description sounded like a closer match to `JobEscrow.sol` than anything else we'd found (Gateway is opaque, ERC-8004 isn't an escrow at all).

**What we actually found, reading the real contract:** No job-state enum, no on-chain deliverable submission, no on-chain approval gating a release — the entire "AI validation" step is a plain OpenAI vision-model check inside a Next.js API route that, if it passes, just fires an ordinary unconditional `withdraw()`. Nothing about the AI decision is ever verified on-chain. There's also no timeout/auto-release logic (a `releaseTimestamp` field exists on the `Payment` struct but is never read anywhere), and no bond/stake/slashing concept at all.

**Why it matters here:** It confirmed our own planned design — a real on-chain job-state machine, arbiter-gated resolution, and timeout auto-release — is *more* rigorous than Circle's own reference app, not less. Good validation, not a reason to change course. The one piece worth borrowing: its EIP-712 signature pattern for "the recipient consents to an early action" (`RefundProtocol.sol:239-302,378-388`) is a clean template *if* we ever want a signature-gated action in `JobEscrow`, but it's not an AI-oracle attestation pattern and doesn't solve validation the way ERC-8004's Validation Registry does.

**Sources:**
- `arc-escrow/contracts/escrow_smart_contract/RefundProtocol.sol` (389 lines, read in full — `Payment` struct at lines 21-28, `pay`/`withdraw`/`refundByArbiter`/`earlyWithdrawByArbiter` at lines 95,199,137,239)
- `arc-escrow/app/api/contracts/validate-work/route.ts` (320 lines, read in full — the OpenAI-vision-then-plain-`withdraw()` flow, lines 102-163,205-207,256-270)
- `arc-escrow/supabase/migrations/20250523160711_add_lockup_seconds.sql` and `20260219193800_remove_lockup_columns.sql` — confirms a timeout-like feature was tried at the application layer and later reverted, never replaced

---

## How we'll actually build this

Matches the working style already set for this project (skeleton first, talk it through, then implement in small increments):

1. **Phase 0 setup** — fork `arc-nanopayments` on GitHub, clone it locally, confirm the unmodified buyer→seller x402 flow actually works end-to-end on Arc testnet with faucet funds, before either contract exists. `forge init` a `contracts/` project alongside it.
2. **Per contract**: I write the interface/skeleton only (function signatures, state variables, no bodies) — we review it together — then I implement one function at a time, with its Foundry test written alongside it, running `forge test` after each before moving to the next. Nothing gets implemented in one big dump.
3. **Nothing gets deployed to Arc testnet without asking first** — that spends real faucet funds and, once verified, isn't cleanly undoable.
4. **Backend rewiring** happens after both contracts' interfaces are stable (so we're not rewriting the TypeScript side against a moving Solidity target).
5. **Demo scripts** get built as soon as the contracts alone work (via raw `cast send` against the deployed addresses) — independent of whether the backend rewiring is finished, so "does the mechanism work" and "does the full agent flow work" can be verified separately.

Full phase-by-phase detail (including the Foundry test list) is in the plan file at `~/.claude/plans/flickering-percolating-owl.md`.
