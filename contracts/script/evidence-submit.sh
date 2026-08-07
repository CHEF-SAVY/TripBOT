#!/usr/bin/env bash
# evidence-submit.sh — anchor dispute evidence in a BOT Chain blob (EIP-4844) instead of
# only an on-chain hash in contract storage.
#
# JobEscrow.dispute(jobId, evidenceHash) already records a content-addressed hash of the
# buyer's evidence — that part doesn't change. What this script adds is a cheap place to put
# the *evidence itself*: a blob transaction costs far less than calldata/storage for the same
# bytes, and BOT Chain's Blob API (eth_getBlobSidecarByTxHash) lets anyone fetch it back later
# by the transaction hash. The blob's own KZG-committed versioned hash — not a second,
# independent keccak256 — is used as `evidenceHash`, so the on-chain record is a direct
# cryptographic commitment to the blob, not just a pointer alongside an unrelated hash.
#
# Usage:
#   ./evidence-submit.sh <evidence-file> [--private-key <key>] [--rpc-url <url>]
#
# Prints, on stdout, the two values dispute() needs:
#   TX_HASH=0x...        (pass to evidence-fetch.sh later to retrieve the raw evidence)
#   EVIDENCE_HASH=0x...  (pass as the evidenceHash argument to dispute(jobId, evidenceHash))

set -euo pipefail

EVIDENCE_FILE="$1"
shift

RPC_URL="https://rpc.bohr.life"
PRIVATE_KEY="${PRIVATE_KEY:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --private-key) PRIVATE_KEY="$2"; shift 2 ;;
    --rpc-url) RPC_URL="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$PRIVATE_KEY" ]; then
  echo "error: PRIVATE_KEY must be set (env or --private-key)" >&2
  exit 1
fi
if [ ! -f "$EVIDENCE_FILE" ]; then
  echo "error: evidence file not found: $EVIDENCE_FILE" >&2
  exit 1
fi

FROM=$(cast wallet address --private-key "$PRIVATE_KEY")

# The `to` address is irrelevant to blob storage — a blob's data lives in the sidecar, not in
# execution — so this self-sends to the buyer's own address with no calldata, purely as a
# carrier for the blob.
RECEIPT=$(cast send "$FROM" --blob --path "$EVIDENCE_FILE" \
  --private-key "$PRIVATE_KEY" --rpc-url "$RPC_URL" --json)

TX_HASH=$(echo "$RECEIPT" | jq -r '.transactionHash')

VERSIONED_HASH=$(cast tx "$TX_HASH" --rpc-url "$RPC_URL" --json | jq -r '.blobVersionedHashes[0]')

echo "TX_HASH=$TX_HASH"
echo "EVIDENCE_HASH=$VERSIONED_HASH"
