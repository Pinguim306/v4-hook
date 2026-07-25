#!/usr/bin/env bash
# Pre-flight for launching Coil on Circle's Arc network (testnet first).
# Probes everything the multi-chain deploy needs and prints a go/no-go table.
# Requires `cast` (Foundry) and network access to the Arc RPC.
#
#   ./preflight-arc.sh                       # Arc testnet defaults
#   RPC_URL=... CHAIN_ID=... ./preflight-arc.sh
set -uo pipefail

# Arc public testnet defaults (mainnet expected summer 2026 — override via env when live).
RPC_URL="${RPC_URL:-https://rpc.testnet.arc.network}"
CHAIN_ID="${CHAIN_ID:-5042002}"

# Canonical singletons that MIGHT already exist on Arc.
PERMIT2="${PERMIT2:-0x000000000022D473030F116dDEE9F6B43aC78BA3}"
CREATE2_PROXY="0x4e59b44847b379578588920cA78FbF26c0B4956C" # deterministic-deployment-proxy
# If Circle/Uniswap publish official v4 addresses for Arc, pass them here to check:
POOL_MANAGER="${POOL_MANAGER:-}"
POSITION_MANAGER="${POSITION_MANAGER:-}"
WRAPPED_NATIVE="${WRAPPED_NATIVE:-}" # wrapped-USDC (WETH9-style), needed by POSM

# A funded wallet (faucet) to probe native decimals; optional.
PROBE_ADDRESS="${PROBE_ADDRESS:-}"

pass=0; fail=0; warn=0
ok()   { echo "  ✔ $1"; pass=$((pass + 1)); }
bad()  { echo "  ✘ $1"; fail=$((fail + 1)); }
note() { echo "  ⚠ $1"; warn=$((warn + 1)); }

echo "== Arc pre-flight =="
echo "RPC: $RPC_URL"
echo

chainid=$(cast chain-id --rpc-url "$RPC_URL" 2>/dev/null)
if [ -z "$chainid" ]; then
    bad "RPC unreachable — try an alternative endpoint (Alchemy/QuickNode/dRPC all serve Arc)"
    echo; echo "$pass ok, $fail failed, $warn warnings"; exit 1
fi
[ "$chainid" = "$CHAIN_ID" ] && ok "chain id is $chainid" || bad "chain id is $chainid (expected $CHAIN_ID)"

# EVM version: v4-core needs cancun (tload/tstore).
if cast block latest --rpc-url "$RPC_URL" --json 2>/dev/null | grep -q '"blobGasUsed"'; then
    ok "cancun fields present in blocks (tload/tstore for v4 likely supported)"
else
    note "cancun fields not visible in block — confirm Arc supports EIP-1153 before deploying v4"
fi

# Native gas = USDC. The whitepaper says 6 decimals — but what matters to contracts/frontends is
# how msg.value/balances are scaled on-chain. Probe a funded address to see the raw wei scale.
if [ -n "$PROBE_ADDRESS" ]; then
    bal=$(cast balance "$PROBE_ADDRESS" --rpc-url "$RPC_URL" 2>/dev/null)
    echo "  · native balance of $PROBE_ADDRESS = $bal wei-units"
    note "sanity-check: if you faucetted 1 USDC, 1e6 here means 6-dec native, 1e18 means 18-dec scaling"
else
    note "set PROBE_ADDRESS=<faucet-funded wallet> to probe the native USDC decimal scaling"
fi

codeat() { cast codesize "$1" --rpc-url "$RPC_URL" 2>/dev/null || echo 0; }

# Permit2 + the CREATE2 proxy that can deploy it keylessly at the canonical address.
if [ "$(codeat "$PERMIT2")" != "0" ]; then
    ok "Permit2 already deployed at canonical $PERMIT2"
else
    if [ "$(codeat "$CREATE2_PROXY")" != "0" ]; then
        note "Permit2 missing but the deterministic-deployment proxy exists — Permit2 can be deployed at the canonical address (permit2 repo: forge script)"
    else
        bad "Permit2 missing AND no CREATE2 proxy at $CREATE2_PROXY — canonical-address deploy not possible; a custom Permit2 address will be needed"
    fi
fi

for pair in "PoolManager:$POOL_MANAGER" "PositionManager:$POSITION_MANAGER" "WrappedNative:$WRAPPED_NATIVE"; do
    name="${pair%%:*}"; addr="${pair##*:}"
    if [ -z "$addr" ]; then
        note "$name: no known address on Arc — will be part of our own v4-stack deploy"
    elif [ "$(codeat "$addr")" != "0" ]; then
        ok "$name has code at $addr"
    else
        bad "$name has NO code at $addr"
    fi
done

echo
echo "$pass ok, $fail failed, $warn warnings"
[ "$fail" -eq 0 ] || exit 1
