#!/usr/bin/env bash
# Pre-flight: validate the Uniswap v4 infrastructure addresses on Robinhood Chain
# before any deploy. Requires `cast` (Foundry) and network access to the RPC.
#
#   ./preflight.sh                       # uses defaults below
#   RPC_URL=... ./preflight.sh           # override RPC
set -euo pipefail

RPC_URL="${RPC_URL:-https://rpc.mainnet.chain.robinhood.com}"
POOL_MANAGER="${POOL_MANAGER:-0x8366a39CC670B4001A1121B8F6A443A643e40951}"
POSITION_MANAGER="${POSITION_MANAGER:-0x58daec3116aae6D93017bAAea7749052E8a04fA7}"
PERMIT2="${PERMIT2:-0x000000000022D473030F116dDEE9F6B43aC78BA3}"

pass=0
fail=0
ok()   { echo "  ✔ $1"; pass=$((pass + 1)); }
bad()  { echo "  ✘ $1"; fail=$((fail + 1)); }

echo "== Robinhood Chain pre-flight =="
echo "RPC: $RPC_URL"
echo

# 1. Chain id must be 4663.
chainid=$(cast chain-id --rpc-url "$RPC_URL")
[ "$chainid" = "4663" ] && ok "chain id is 4663" || bad "chain id is $chainid (expected 4663)"

# 2. Each address must hold code.
for pair in "PoolManager:$POOL_MANAGER" "PositionManager:$POSITION_MANAGER" "Permit2:$PERMIT2"; do
  name="${pair%%:*}"; addr="${pair##*:}"
  size=$(cast codesize "$addr" --rpc-url "$RPC_URL")
  [ "${size:-0}" -gt 2 ] && ok "$name has code ($size bytes) at $addr" || bad "$name has NO code at $addr"
done

# 3. Interface probes — the exact functions seed()/pokeFees() depend on.
if cast call "$POSITION_MANAGER" "nextTokenId()(uint256)" --rpc-url "$RPC_URL" >/dev/null 2>&1; then
  ok "POSM answers nextTokenId()"
else
  bad "POSM does not answer nextTokenId() — wrong contract?"
fi

posm_pm=$(cast call "$POSITION_MANAGER" "poolManager()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "")
if [ "$(echo "$posm_pm" | tr 'A-F' 'a-f')" = "$(echo "$POOL_MANAGER" | tr 'A-F' 'a-f')" ]; then
  ok "POSM.poolManager() == PoolManager (cross-check)"
else
  bad "POSM.poolManager() = $posm_pm ≠ $POOL_MANAGER"
fi

if cast call "$PERMIT2" "DOMAIN_SEPARATOR()(bytes32)" --rpc-url "$RPC_URL" >/dev/null 2>&1; then
  ok "Permit2 answers DOMAIN_SEPARATOR()"
else
  bad "Permit2 does not answer DOMAIN_SEPARATOR()"
fi

echo
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ] || exit 1
