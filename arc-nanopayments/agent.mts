import { createWalletClient, createPublicClient, http, erc20Abi, parseUnits, keccak256, toBytes } from "viem";
import { arcTestnet } from "viem/chains";
import { privateKeyToAccount } from "viem/accounts";
import { createJob, releaseJob, disputeJob, signJobId } from "./lib/jobEscrow.ts";

// --- CLI args ---
// One job, start to finish, per run — matches the two-recordable-runs demo script
// (CLAUDE.md): plain `npm run agent` drives the clean release; `-- --dispute` drives
// the disputed-slash run using the same real delivery, just forcing the buyer's
// verdict to "bad" rather than faking the seller's response.
const ENDPOINTS = {
  quote: { path: "/api/premium/quote", method: "GET" as const },
  dataset: { path: "/api/premium/dataset", method: "GET" as const },
  compute: {
    path: "/api/premium/compute",
    method: "POST" as const,
    body: { text: "Hello from the Tripwire escrow demo!" },
  },
  "agent-task": { path: "/api/premium/agent-task", method: "GET" as const },
};
type EndpointName = keyof typeof ENDPOINTS;

function parseArgs() {
  const args = process.argv.slice(2);
  let endpoint: EndpointName = "quote";
  let forceDispute = false;

  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--endpoint" && args[i + 1]) {
      const val = args[i + 1] as EndpointName;
      if (!(val in ENDPOINTS)) {
        console.error(`Unknown endpoint "${val}". Choices: ${Object.keys(ENDPOINTS).join(", ")}`);
        process.exit(1);
      }
      endpoint = val;
      i++;
    } else if (args[i] === "--dispute") {
      forceDispute = true;
    }
  }

  return { endpoint, forceDispute };
}

const { endpoint, forceDispute } = parseArgs();
const target = ENDPOINTS[endpoint];

const BASE_URL = process.env.BASE_URL ?? "http://localhost:3000";
const ARC_TESTNET_USDC = "0x3600000000000000000000000000000000000000" as const;
const ARC_TESTNET_RPC = "https://rpc.testnet.arc.network";
// Plenty for what is, end to end, a same-run sequence of HTTP calls and confirmations —
// not a long-lived job, just comfortable margin against testnet block-time variance.
const JOB_DURATION_SECONDS = 3600n;

const buyerKey = process.env.BUYER_PRIVATE_KEY as `0x${string}` | undefined;
if (!buyerKey) {
  console.error("Missing BUYER_PRIVATE_KEY. Run `npm run generate-wallets` first.");
  process.exit(1);
}

const account = privateKeyToAccount(buyerKey);
const publicClient = createPublicClient({ chain: arcTestnet, transport: http(ARC_TESTNET_RPC) });
const walletClient = createWalletClient({ account, chain: arcTestnet, transport: http(ARC_TESTNET_RPC) });

console.log(`Buyer: ${account.address}`);
console.log(`Target: ${target.method} ${BASE_URL}${target.path}${forceDispute ? " (forcing a dispute for the demo)" : ""}`);

function requestInit() {
  return target.method === "POST"
    ? { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(target.body) }
    : { method: "GET" as const };
}

// --- 1. Unauthenticated request -> 402 with what's needed to create a job ---
const url = `${BASE_URL}${target.path}`;
const quoteRes = await fetch(url, requestInit());
if (quoteRes.status !== 402) {
  console.error(`Expected 402 Payment Required, got ${quoteRes.status}: ${await quoteRes.text()}`);
  process.exit(1);
}
const quote = (await quoteRes.json()) as {
  price: string;
  sellerAgentId: string;
  requestHash: `0x${string}`;
  jobEscrowAddress: `0x${string}`;
};
console.log(`402 received: ${quote.price} USDC, sellerAgentId ${quote.sellerAgentId}, JobEscrow ${quote.jobEscrowAddress}`);

const amount = parseUnits(quote.price.replace("$", ""), 6);

// --- 2. Approve JobEscrow to pull the payment ---
console.log(`Approving ${quote.price} USDC for JobEscrow...`);
const approveTxHash = await walletClient.writeContract({
  address: ARC_TESTNET_USDC,
  abi: erc20Abi,
  functionName: "approve",
  args: [quote.jobEscrowAddress, amount],
});
await publicClient.waitForTransactionReceipt({ hash: approveTxHash });

// --- 3. Create the escrowed job ---
console.log("Creating job...");
const completionDeadline = BigInt(Math.floor(Date.now() / 1000)) + JOB_DURATION_SECONDS;
const { jobId, txHash: createTxHash } = await createJob(walletClient, quote.jobEscrowAddress, {
  sellerAgentId: BigInt(quote.sellerAgentId),
  amount,
  completionDeadline,
  validationRequestHash: quote.requestHash,
});
console.log(`Job ${jobId} created (tx ${createTxHash})`);

// --- 4. Retry, presenting the jobId and proof we're its buyer ---
// The signature is what actually authenticates this request — jobId alone is a public,
// sequential, guessable number, so without it anyone who saw or guessed a valid jobId
// could redeem someone else's paid delivery.
console.log("Retrying with jobId...");
const jobSignature = await signJobId(walletClient, jobId);
const deliveryRes = await fetch(url, {
  ...requestInit(),
  headers: { ...requestInit().headers, "x-job-id": jobId.toString(), "x-job-signature": jobSignature },
});
if (!deliveryRes.ok) {
  console.error(`Delivery request failed: ${deliveryRes.status} ${await deliveryRes.text()}`);
  process.exit(1);
}
const deliveryText = await deliveryRes.text();
console.log(`Delivered: ${deliveryText.slice(0, 200)}${deliveryText.length > 200 ? "..." : ""}`);

// --- 5. Judge the response ---
// MVP bar per the plan: valid, non-empty, and matches what was requested (here: parses
// as the JSON every route actually returns). Tighter validation is an explicit stretch
// goal, not required for the MVP.
let isGood = deliveryText.trim().length > 0;
if (isGood) {
  try {
    JSON.parse(deliveryText);
  } catch {
    isGood = false;
  }
}
if (forceDispute) {
  console.log("--dispute passed: treating this delivery as bad regardless of content, for the demo.");
  isGood = false;
}
console.log(`Verdict: ${isGood ? "GOOD" : "BAD"}`);

// --- 6. Release or dispute ---
if (isGood) {
  console.log("Releasing payment...");
  const releaseTxHash = await releaseJob(walletClient, quote.jobEscrowAddress, jobId);
  console.log(`Released (tx ${releaseTxHash}). Seller paid in full, bond reservation freed.`);
} else {
  const evidenceHash = keccak256(toBytes(deliveryText || "no-content-delivered"));
  console.log(`Disputing with evidenceHash ${evidenceHash}...`);
  const disputeTxHash = await disputeJob(walletClient, quote.jobEscrowAddress, jobId, evidenceHash);
  console.log(`Disputed (tx ${disputeTxHash}). Awaiting arbiter resolution via resolveDispute().`);
}
