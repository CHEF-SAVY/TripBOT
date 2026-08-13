# TripBOT

Escrow-backed job settlement for agent-to-agent payments on **BOT Chain testnet** — payment
releases only on verified delivery, backed by a slashable seller bond.

Built for the BOT Chain Africa Builder Challenge (AI & AI Agents track). The escrow contracts
were originally written for Circle's Arc testnet during the Encode Club ARC Hackathon and
ported here; that provenance is noted for honesty, but TripBOT has no Arc dependency, no Arc
history, and no Arc identity.

## What this is, in one paragraph

Two AI agents want to trade a service for payment. Today, payment either settles irreversibly
the instant it's sent, or it doesn't move at all — there's no in-between. TripBOT adds that
in-between: a buyer's payment sits in an on-chain escrow contract instead of releasing
immediately, and a seller has to post a slashable bond before they're even eligible to take
the job. If delivery is good, the buyer releases the escrow and the seller gets paid in full.
If it isn't, the buyer disputes, and — once resolved — the seller's own posted stake
compensates the buyer instead of the buyer just losing the money.

## Try it

A judge plays the buyer end to end, funded by a server-side testnet wallet. The browser never
holds a key.

```bash
cd web
cp .env.example .env.local     # fill in wallets, session secret, access code, Supabase
npm install && npm run dev
```

- `/` — what the product argues, with live contract numbers
- `/live` — the funded buyer session

The run **stops at the funding step and asks**, because spending someone's money without
asking is the thing this product exists to argue against. Choose a seller, read the 402-style
quote and its on-chain validation request, approve the exact amount, inspect what arrives, and
then release or dispute. A dispute resolved against the seller pays the buyer twice — the
escrow refund, and the seller's slashed collateral — from two different contracts.

## Architecture

```mermaid
sequenceDiagram
    participant Buyer as Buyer Agent
    participant Seller as Seller Agent
    participant JE as JobEscrow.sol
    participant SB as SellerBond.sol
    participant VR as ValidationRegistry.sol

    Note over Seller,SB: one-time setup
    Seller->>SB: deposit{value: bondAmount}(sellerAgentId)

    Seller->>VR: validationRequest(JobEscrow, sellerAgentId, requestURI)
    Seller-->>Buyer: quote { price, sellerAgentId, requestHash, jobEscrowAddress }

    Buyer->>JE: createJob{value: amount}(sellerAgentId, deadline, requestHash)
    JE->>SB: reserve(sellerAgentId, requiredBond)
    JE-->>Buyer: jobId

    Seller->>JE: view jobs(jobId) — confirm Active
    Seller-->>Buyer: deliver result

    alt buyer satisfied
        Buyer->>JE: release(jobId)
        JE->>Seller: call{value: amount}("")
        JE->>SB: releaseReservation(sellerAgentId, requiredBond)
        JE->>VR: validationResponse(100, "RELEASED")
    else buyer disputes, seller at fault
        Buyer->>JE: dispute(jobId, evidenceHash)
        Note over JE: arbiter reviews evidenceHash off-chain
        JE->>SB: slash(sellerAgentId, requiredBond, buyer)
        JE->>Buyer: call{value: amount}("")
        JE->>VR: validationResponse(0, "SELLER_AT_FAULT")
    else infrastructure failed, nobody at fault
        Note over JE: resolveDisputeNeutral — refund without a slash
        JE->>Buyer: call{value: amount}("")
    else arbiter never responds
        Note over JE: after the arbitration window, claimDisputeTimeout
        JE->>Buyer: call{value: amount}("")
    else buyer does nothing
        Note over JE: after deadline + responseWindow
        JE->>JE: anyone calls claimTimeout(jobId)
        JE->>Seller: call{value: amount}("")
    end
```

No external dependency can block a payout. Validation Registry calls are wrapped, the registry
integration has an owner-controlled kill switch, a payout that a recipient rejects becomes a
pull-payment credit rather than a revert, and both timeout paths exist so neither an absent
buyer nor an absent arbiter can strand funds.

## Deployment — BOT Chain testnet (chain 968)

| Contract | Address |
|---|---|
| JobEscrow | `0xe02695454edA18Ec0b00836F98635aC2D6CAA238` |
| SellerBond | `0x56641c18259bDf08dF4b78d14Bb7ECe3a2283A67` |
| IdentityRegistry | `0x66677c64d0545a5F161EAE83fed8D260EAc58cAa` |
| ValidationRegistry | `0x4Dd733cBAcF4A13bD265CCB17B026BD9CdDBb0B0` |

Explorer: [scan.bohr.life](https://scan.bohr.life). An earlier deployment exists on chain and
is deliberately superseded — the app refuses to write to it.

## Status

- Contracts complete, 138 unit tests passing, `forge fmt --check` clean.
- Full lifecycle verified on-chain, not only in tests: quote, escrow funding, delivery,
  dispute, and an arbiter ruling that slashed real collateral to the buyer.
- Web app complete: read APIs, funded buyer session, arbiter resolution, judge access gate.

## Honest disclosures

- **Dispute resolution is single-arbiter (the deployer wallet)** — centralized-for-now, not
  pretend-decentralized.
- **No ERC-8004 registry exists on BOT Chain testnet.** This project deploys its own minimal
  Identity/Validation Registry stand-ins. They are ERC-8004-*inspired*, not a claim of
  compliance, and the identity stand-in does not implement agent transfer.
- **Dispute evidence is hash-only.** The evidence is canonicalised and committed on-chain as a
  hash; EIP-4844 blob anchoring is proven in `contracts/script/` but is not wired into the web
  flow, and the interface says so rather than implying otherwise.
- **The EOA Paymaster path has no sponsor account**, so every transaction self-pays. It is not
  wired into the app.
- **The seller endpoints are archetypes served in-process**, not independent HTTP services.
  Delivery still requires a signature recovering to the job's buyer and is claimed once per job
  in durable storage.
- **Testnet only.** No mainnet deployment has been done or is planned for this submission.
- **Demo wallets are disposable burners.** At demo prices, gas exceeds the buyer's compensation
  — the mechanism pays out exactly as designed, but nobody comes out ahead on a 0.03 BOT job.

## Repo layout

```
README.md            — this file
LICENSE              — Apache-2.0
.github/workflows/   — CI: Foundry build/test/fmt, plus web lint/typecheck/build
contracts/           — Foundry project: JobEscrow + SellerBond + ERC-8004 stand-ins
web/                 — Next.js app: landing page, funded judge session, read APIs
```

## Reference links

- BOT Chain dev docs: dev-docs.botchain.ai
- BOT Chain testnet explorer: scan.bohr.life
- BOT Chain testnet faucet: faucet.botchain.ai/basic
- ERC-8004 spec: eips.ethereum.org/EIPS/eip-8004
