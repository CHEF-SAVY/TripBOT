export const identityRegistryAbi = [
  {
    type: "function",
    name: "ownerOf",
    inputs: [{ name: "agentId", type: "uint256" }],
    outputs: [{ name: "owner", type: "address" }],
    stateMutability: "view",
  },
] as const;
