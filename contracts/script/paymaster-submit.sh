#!/usr/bin/env bash
# paymaster-submit.sh — submit a JobEscrow/SellerBond call through BOT Chain's EOA
# Paymaster when sponsorable, falling back to a normal signed transaction otherwise.
#
# BOT Chain's EOA Paymaster (see contracts/README.md and
# https://dev-docs.botchain.ai/docs/Developers/eoa-paymaster/) is provided by third-party
# infra (the docs name Nodereal's "MegaFuel" as the reference implementation) — there is no
# single fixed paymaster RPC URL for BOT Chain testnet the way there is for the chain's own
# RPC endpoint. This script therefore takes the paymaster endpoint as a required parameter
# (PAYMASTER_RPC_URL) rather than assuming one. Without a real sponsor account behind that
# URL, every call here falls back to normal submission — which is exactly the intended
# behavior per the paymaster spec's own "Best Practice: implement proper error handling /
# fallback mechanisms" guidance, and mirrors how JobEscrow itself treats its own external
# dependencies (see JobEscrow's validationRegistryEnabled kill switch): a missing or
# unavailable paymaster must never block a transaction from being submitted normally.
#
# Usage:
#   PAYMASTER_RPC_URL=<sponsor endpoint> PRIVATE_KEY=<0x...> \
#     ./paymaster-submit.sh <to> <sig> [args...] [--value <wei>]
#
# Example (buyer creating a job, falling back to normal submission if no paymaster is set):
#   PRIVATE_KEY=$BUYER_PRIVATE_KEY ./paymaster-submit.sh \
#     $JOB_ESCROW "createJob(uint256,uint64,bytes32)" 0 1786140000 0x00...00 \
#     --value 100000000000000000
#
# Required env:
#   PRIVATE_KEY        — signer's private key
# Optional env:
#   PAYMASTER_RPC_URL  — sponsor's paymaster JSON-RPC endpoint (pm_isSponsorable +
#                        eth_sendRawTransaction). If unset, skips the sponsorship check
#                        entirely and submits normally — same effect as an unsponsorable tx.
#   RPC_URL            — BOT Chain RPC for gas estimation and normal-path submission
#                        (default: bot_testnet's https://rpc.bohr.life)

set -euo pipefail

RPC_URL="${RPC_URL:-https://rpc.bohr.life}"
TO="$1"
SIG="$2"
shift 2

ARGS=()
VALUE="0"
while [ $# -gt 0 ]; do
  if [ "$1" = "--value" ]; then
    VALUE="$2"
    shift 2
  else
    ARGS+=("$1")
    shift
  fi
done

if [ -z "${PRIVATE_KEY:-}" ]; then
  echo "error: PRIVATE_KEY must be set" >&2
  exit 1
fi

FROM=$(cast wallet address --private-key "$PRIVATE_KEY")
CALLDATA=$(cast calldata "$SIG" "${ARGS[@]}")
GAS_HEX=$(cast estimate "$TO" "$SIG" "${ARGS[@]}" --value "$VALUE" --from "$FROM" --rpc-url "$RPC_URL" | xargs printf '0x%x')
VALUE_HEX=$(printf '0x%x' "$VALUE")

submit_normally() {
  echo "Submitting normally (unsponsored) to $RPC_URL..." >&2
  cast send "$TO" "$SIG" "${ARGS[@]}" --value "$VALUE" --private-key "$PRIVATE_KEY" --rpc-url "$RPC_URL"
}

if [ -z "${PAYMASTER_RPC_URL:-}" ]; then
  echo "PAYMASTER_RPC_URL not set — no sponsor configured, submitting normally." >&2
  submit_normally
  exit 0
fi

# --- pm_isSponsorable -------------------------------------------------------
SPONSOR_CHECK=$(curl -sf -X POST "$PAYMASTER_RPC_URL" \
  -H "Content-Type: application/json" \
  -d "$(jq -n \
    --arg to "$TO" --arg from "$FROM" --arg value "$VALUE_HEX" \
    --arg data "$CALLDATA" --arg gas "$GAS_HEX" \
    '{jsonrpc:"2.0",id:1,method:"pm_isSponsorable",params:[{to:$to,from:$from,value:$value,data:$data,gas:$gas}]}'
  )" || echo '{}')

SPONSORABLE=$(echo "$SPONSOR_CHECK" | jq -r '.result.Sponsorable // false')
POLICY=$(echo "$SPONSOR_CHECK" | jq -r '.result.SponsorPolicy // "none"')

if [ "$SPONSORABLE" != "true" ]; then
  echo "Not sponsorable (policy: $POLICY) — falling back to normal submission." >&2
  submit_normally
  exit 0
fi

echo "Sponsorable under policy \"$POLICY\" — submitting gas-free via paymaster." >&2

# --- sign a zero-gas-price tx and hand it to the paymaster ------------------
RAW_TX=$(cast mktx "$TO" "$SIG" "${ARGS[@]}" --value "$VALUE" --legacy --gas-price 0 \
  --private-key "$PRIVATE_KEY" --rpc-url "$RPC_URL")

SUBMIT_RESPONSE=$(curl -sf -X POST "$PAYMASTER_RPC_URL" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg raw "$RAW_TX" '{jsonrpc:"2.0",id:1,method:"eth_sendRawTransaction",params:[$raw]}')")

TX_HASH=$(echo "$SUBMIT_RESPONSE" | jq -r '.result // empty')
if [ -z "$TX_HASH" ]; then
  echo "Paymaster submission failed ($SUBMIT_RESPONSE) — falling back to normal submission." >&2
  submit_normally
  exit 0
fi

echo "$TX_HASH"
