import type { Address } from "viem";

export const BOT_TESTNET_DEPLOYMENT = {
  chainId: 968,
  deploymentBlock: 19_062_989n,
  jobEscrow: "0x627853Ddf094172913f23366839A86DF3d1Aa5bB" as Address,
  sellerBond: "0x3A40b1dd835f271e2E67C5b2AEb82F27D4d5ec5D" as Address,
  identityRegistry: "0x9e0F863AE8165688c6e5Ec335236bD459f2DdC8b" as Address,
  validationRegistry: "0xA29b9F92Eb6A64B9371F86f80e458743341c6c9F" as Address,
} as const;
