# Tripwire contracts

Foundry project for Tripwire's escrow stack, ported from Circle's Arc testnet to BOT Chain
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
  these), so this project deploys its own, scoped only to the calls Tripwire actually makes.

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

Deployed and verified on `scan.bohr.life`:

```
IdentityRegistry:   0x9e0F863AE8165688c6e5Ec335236bD459f2DdC8b
ValidationRegistry: 0xA29b9F92Eb6A64B9371F86f80e458743341c6c9F
JobEscrow:          0x627853Ddf094172913f23366839A86DF3d1Aa5bB
SellerBond:         0x3A40b1dd835f271e2E67C5b2AEb82F27D4d5ec5D
Arbiter/Owner:      0xC9DF311Af34f6a9cD1A406776F5F88798Fe615a6
```

Full lifecycle sanity-checked on-chain post-deploy: seller registered (agentId 0), bond
posted, then all three exit paths exercised end to end — `createJob` → `release`,
`createJob` → `dispute` → `resolveDispute` (seller-at-fault slash), and `createJob` →
`claimTimeout`.

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

## Blob API (not yet wired)

`eth_getBlobSidecars` / `eth_getBlobSidecarByTxHash` — a cheaper place than contract storage
to anchor dispute evidence alongside the on-chain `evidenceHash`. Nice-to-have, not required
for the core escrow lifecycle.
