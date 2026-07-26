# Tripwire contracts

Foundry project for Tripwire's two contracts:

- **`SellerBond.sol`** — slashable USDC stake keyed by ERC-8004 agentId. Sellers post bond
  before taking jobs; bond is reserved per job, and a slash can only ever consume what was
  reserved for the job being resolved.
- **`JobEscrow.sol`** *(upcoming)* — one job = one escrowed payment: release on buyer
  approval, dispute with arbiter resolution backed by the seller's bond, timeout
  auto-release so an absent buyer can't grief a seller.

## Commands

```bash
forge build            # compile
forge test             # run the unit suite
forge fmt              # format (CI enforces forge fmt --check)
```

Fork tests against live Arc testnet registries (pre-deploy gate):

```bash
forge test --match-contract ArcForkIntegration --fork-url https://rpc.testnet.arc.network
```

## Layout

```
src/                 — contracts
src/interfaces/      — minimal interfaces to external systems (ERC-8004 registries),
                       signatures taken from the verified ABIs on Arc testnet
test/                — unit tests (mirrors src/), mocks under test/mocks/
script/              — deploy scripts
lib/                 — vendored dependencies (forge-std, OpenZeppelin) — committed so a
                       plain clone builds without submodule flags
```

## Network

Arc testnet — chain ID `5042002`, RPC `https://rpc.testnet.arc.network` (configured as
`arc_testnet` in `foundry.toml`). USDC is the native gas token, with an ERC-20 interface at
`0x3600000000000000000000000000000000000000`. Deployed contract addresses will be recorded
here after deployment.
