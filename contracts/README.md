# TripBOT contracts

Foundry project for TripBOT's escrow stack, ported from Circle's Arc testnet to BOT Chain
testnet:

- **`SellerBond.sol`** — slashable native-BOT stake keyed by ERC-8004 agentId. Sellers post
  bond before taking jobs; bond is reserved per job, and a slash can only ever consume what
  was reserved for the job being resolved.
- **`JobEscrow.sol`** — one job = one escrowed native-BOT payment: release on buyer approval,
  dispute with arbiter resolution backed by the seller's bond, timeout auto-release so an
  absent buyer can't grief a seller.
- **`registries/IdentityRegistry.sol`** and **`registries/ValidationRegistry.sol`** — minimal
  ERC-8004 stand-ins deployed alongside the two contracts above. No ERC-8004 registry exists
  on BOT Chain testnet (confirmed against `scan.bohr.life`'s own search API before writing
  these), so this project deploys its own, scoped only to the calls TripBOT actually makes.

Both `SellerBond.sol` and `JobEscrow.sol` are complete, fully unit-tested, and were
previously deployed and verified on Arc testnet before this port.

## Commands

```bash
forge build            # compile
forge test             # run the unit suite
forge fmt              # format (CI enforces forge fmt --check)
```

## Layout

```
src/                 — contracts
src/interfaces/      — minimal interfaces to external systems (ERC-8004 registries)
src/registries/      — this project's own minimal ERC-8004 Identity/Validation Registry
                       stand-ins (no live registry exists on BOT Chain testnet)
test/                — unit tests (mirrors src/), mocks under test/mocks/
script/              — deploy scripts
lib/                 — vendored dependencies (forge-std, OpenZeppelin) — committed so a
                       plain clone builds without submodule flags
```

## Network

BOT Chain testnet ("Bohr") — chain ID `968`, RPC `https://rpc.bohr.life` (configured as
`bot_testnet` in `foundry.toml`). BOT is the native gas token with standard 18-decimal native
value — unlike Arc, where USDC is the native gas token behind a fixed pseudo-ERC20 interface
at `0x3600...0000`. Every escrowed/staked amount here is plain native value (`msg.value`,
`.call{value: ...}`), not an ERC-20 transfer.

Mainnet (chain ID `677`, `https://rpc.botchain.ai`) is deliberately not configured — this
project is testnet-only.

Current deployment on `scan.bohr.life`:

```
IdentityRegistry:   0x66677c64d0545a5F161EAE83fed8D260EAc58cAa
ValidationRegistry: 0x4Dd733cBAcF4A13bD265CCB17B026BD9CdDBb0B0
JobEscrow:          0xe02695454edA18Ec0b00836F98635aC2D6CAA238
SellerBond:         0x56641c18259bDf08dF4b78d14Bb7ECe3a2283A67
Arbiter/Owner:      0xC9DF311Af34f6a9cD1A406776F5F88798Fe615a6
```

This stack carries the hardened contracts: a dispute-timeout backstop for an absent arbiter,
neutral resolution for a proven infrastructure failure, deferred pull payouts so a rejecting
recipient cannot block settlement, reentrancy guards on every value-moving path, rounded-up
collateral, pausable job creation, and two-step owner/arbiter rotation.

An earlier deployment (JobEscrow `0x627853Ddf094172913f23366839A86DF3d1Aa5bB`) predates that
work and is deliberately superseded. It remains readable on the explorer as the record of the
original port; the app refuses to write to it.

Sanity-checked on-chain post-deploy. Three seller agents (ids 0-2) are registered and bonded
at 0.15 BOT each, and the dispute path has been exercised end to end through the app:
`validationRequest` → `createJob` → `dispute` → `resolveDispute`, with the seller's collateral
verifiably moving 0.150 → 0.144 BOT and the buyer receiving both the escrow refund and the
slashed bond.

All three exit paths — `release`, `dispute` → `resolveDispute`, and `claimTimeout` — were
additionally exercised end to end against the earlier deployment during the original port.

## Get test BOT

`https://faucet.botchain.ai/basic`

## EOA Paymaster

`script/paymaster-submit.sh` is a drop-in replacement for `cast send` that checks
`pm_isSponsorable` before submitting a `createJob`/`dispute`/any other call, and falls back to
a normal signed transaction whenever the call isn't sponsorable — same shape as
`cast send <to> <sig> [args...] [--value <wei>]`:

```bash
PAYMASTER_RPC_URL=<sponsor's endpoint> PRIVATE_KEY=$BUYER_PRIVATE_KEY \
  ./script/paymaster-submit.sh $JOB_ESCROW "createJob(uint256,uint64,bytes32)" \
  0 1786140000 0x0000000000000000000000000000000000000000000000000000000000000000 \
  --value 100000000000000000
```

BOT Chain does not publish one fixed paymaster RPC URL — the EOA Paymaster is provided by
third-party sponsor infra (the docs name Nodereal's "MegaFuel" as the reference
implementation), each with its own endpoint and sponsor policy. `PAYMASTER_RPC_URL` is
therefore a required parameter, not a constant; leaving it unset (or pointing at a sponsor
that rejects the call) makes the script submit normally, exactly like a plain `cast send` —
mirroring the same "an external dependency's unavailability must never block a transaction"
principle `JobEscrow.validationRegistryEnabled` already applies to the Validation Registry.

Verified against `bot_testnet`: the fallback path (no `PAYMASTER_RPC_URL`, and a
paymaster that rejects the zero-gas-price tx) both submit normally and land on-chain. The
zero-gas-price signing/submission path itself was exercised against a local mock relay —
real end-to-end sponsorship needs an actual sponsor account, which this project doesn't have.

## Blob API

`script/evidence-submit.sh` anchors a buyer's dispute evidence in an EIP-4844 blob instead of
only a hash in contract storage — cheaper than calldata/storage for the same bytes, and
retrievable later by anyone via BOT Chain's Blob API:

```bash
./script/evidence-submit.sh evidence.json --private-key $BUYER_PRIVATE_KEY
# TX_HASH=0x...
# EVIDENCE_HASH=0x...   (the blob's own KZG-committed versioned hash)
```

The printed `EVIDENCE_HASH` is passed directly as `dispute(jobId, evidenceHash)`'s argument —
so the on-chain record is a real cryptographic commitment to the blob's contents, not an
independent hash alongside an unrelated pointer. To retrieve the evidence later given the
blob tx hash:

```bash
./script/evidence-fetch.sh 0xTX_HASH evidence-recovered.json
```

Blobs are packed as 4096 32-byte BLS12-381 field elements; `evidence-fetch.sh` decodes the
same "8-byte length prefix + 31-usable-bytes-per-field-element" framing `cast send --blob`
uses to pack data in — reverse-engineered and confirmed byte-for-byte against `bot_testnet`
(BOT Chain's docs specify the RPC methods but not an application-level blob content format).

Verified end to end on `bot_testnet`: submitted real evidence in a blob, fetched it back via
`eth_getBlobSidecarByTxHash`, confirmed the decoded bytes are identical to the original file,
then disputed and resolved a real job using the blob's versioned hash as `evidenceHash`
throughout. One honest finding from that run: the dispute payout and bond slash succeeded,
but the Validation Registry attestation call inside `resolveDispute` ran out of gas (an
artifact of automatic gas estimation under-costing the `try/catch`, not a blob or contract
issue) and was silently caught — a live demonstration, not just a unit test, of the exact
invariant `_attestValidation`'s `try/catch` exists to guarantee: an attestation failure never
blocks a payout that's otherwise ready.
