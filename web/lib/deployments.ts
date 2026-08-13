import type { Address } from "viem";

/// The hardened stack the app reads and writes. Deployed 2026-08-13 from
/// contracts/script/Deploy.s.sol, wiring verified on-chain after the run.
export const BOT_TESTNET_DEPLOYMENT = {
  chainId: 968,
  deploymentBlock: 19_658_534n,
  jobEscrow: "0xe02695454edA18Ec0b00836F98635aC2D6CAA238" as Address,
  sellerBond: "0x56641c18259bDf08dF4b78d14Bb7ECe3a2283A67" as Address,
  identityRegistry: "0x66677c64d0545a5F161EAE83fed8D260EAc58cAa" as Address,
  validationRegistry: "0x4Dd733cBAcF4A13bD265CCB17B026BD9CdDBb0B0" as Address,
} as const;

/// The first BOT Chain *testnet* deployment, kept only so the readiness check can refuse it
/// by name. It predates the hardening — no dispute-timeout backstop, no neutral resolution,
/// no deferred payouts — so it must never be the target of a funded session, even if a stale
/// environment variable points there.
///
/// Confusing coincidence worth knowing: the mainnet deployment carries this same address.
/// Contract addresses derive from deployer and nonce, and the deployer began at nonce zero on
/// both chains, so mainnet reproduced the testnet sequence exactly. They are different chains
/// running different bytecode — mainnet has the hardened contracts — and this app only ever
/// talks to testnet, so the guard below is only ever evaluated against chain 968. Should the
/// app ever be pointed at mainnet, it would refuse to write; that is the safe direction to
/// fail, but the stated reason would be wrong.
export const LEGACY_JOB_ESCROW = "0x627853Ddf094172913f23366839A86DF3d1Aa5bB" as Address;
