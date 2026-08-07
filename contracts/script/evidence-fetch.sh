#!/usr/bin/env bash
# evidence-fetch.sh — retrieve dispute evidence anchored via evidence-submit.sh, by the
# blob transaction's hash.
#
# Calls BOT Chain's eth_getBlobSidecarByTxHash, then decodes the raw blob back to the
# original file bytes. Blobs are packed as 4096 32-byte BLS12-381 field elements (each with
# a mandatory leading zero byte); the first field element's data holds an 8-byte big-endian
# length prefix, and the payload itself starts at the second field element — this is the
# same "simple" encoding `cast send --blob --path` uses to pack data in, reverse-engineered
# and confirmed byte-for-byte here rather than assumed, since BOT Chain's docs don't specify
# an on-the-wire blob content format of their own.
#
# Usage:
#   ./evidence-fetch.sh <tx-hash> [output-file] [--rpc-url <url>]
#
# With no output-file, decoded evidence is written to stdout.

set -euo pipefail

TX_HASH="$1"
shift

OUT_FILE=""
RPC_URL="https://rpc.bohr.life"

if [ $# -gt 0 ] && [ "$1" != "--rpc-url" ]; then
  OUT_FILE="$1"
  shift
fi
while [ $# -gt 0 ]; do
  case "$1" in
    --rpc-url) RPC_URL="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

SIDECAR=$(curl -sf -X POST "$RPC_URL" -H "Content-Type: application/json" \
  -d "$(jq -n --arg tx "$TX_HASH" '{jsonrpc:"2.0",id:1,method:"eth_getBlobSidecarByTxHash",params:[$tx]}')")

BLOB_HEX=$(echo "$SIDECAR" | jq -r '.result.blobSidecar.blobs[0] // empty')
if [ -z "$BLOB_HEX" ]; then
  echo "error: no blob sidecar found for $TX_HASH ($SIDECAR)" >&2
  exit 1
fi

DECODE() {
  printf '%s' "$BLOB_HEX" | python3 -c "
import sys
hexstr = sys.stdin.read().strip()
data = bytes.fromhex(hexstr[2:] if hexstr.startswith('0x') else hexstr)
elems = [data[i:i+32] for i in range(0, len(data), 32)]
length = int.from_bytes(elems[0][1:9], 'big')
payload = b''.join(e[1:] for e in elems[1:])
sys.stdout.buffer.write(payload[:length])
"
}

if [ -n "$OUT_FILE" ]; then
  DECODE > "$OUT_FILE"
  echo "wrote $(wc -c < "$OUT_FILE") bytes to $OUT_FILE" >&2
else
  DECODE
fi
