// Generated from contracts/out/ValidationRegistry.sol/ValidationRegistry.json.
export const validationRegistryAbi = [
  {
    type: "event",
    name: "ValidationRequested",
    inputs: [
      { name: "requestHash", type: "bytes32", indexed: true },
      { name: "validatorAddress", type: "address", indexed: true },
      { name: "agentId", type: "uint256", indexed: true },
    ],
  },
  {
    type: "function",
    name: "validationRequest",
    inputs: [
      { name: "validatorAddress", type: "address" },
      { name: "agentId", type: "uint256" },
      { name: "requestURI", type: "string" },
    ],
    outputs: [{ name: "requestHash", type: "bytes32" }],
    stateMutability: "nonpayable",
  },
] as const;
