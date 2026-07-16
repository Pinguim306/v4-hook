#!/usr/bin/env bash
# Verify launched CoilHook tokens on Blockscout.
#
# Every CoilHook embeds per-launch immutables (creator, supply, fees) in its bytecode, so
# Blockscout's "similar match" does NOT propagate from one verified token to the others —
# each token needs its own verification. All constructor args are recoverable from the
# hook's public getters, so this script rebuilds them on-chain and submits each token.
#
#   ./verify-tokens.sh              # verify every token launched by the launchpad
#   ./verify-tokens.sh 0xTOKEN...   # verify a single token
#
# Overridable env: RPC, LAUNCHPAD, VERIFIER_URL, FOUNDRY_PROFILE, SLEEP_BETWEEN.
# Blockscout's API is flaky ("Something went wrong" = rate limit); each submission is
# retried up to 3x with a 60s pause, and tokens are spaced SLEEP_BETWEEN seconds apart.
set -uo pipefail
cd "$(dirname "$0")"

RPC="${RPC:-https://rpc.mainnet.chain.robinhood.com}"
LAUNCHPAD="${LAUNCHPAD:-0x089450e936d758b4c3E122Aa80A754aBF1bd0FFD}"
VERIFIER_URL="${VERIFIER_URL:-https://robinhoodchain.blockscout.com/api}"
export FOUNDRY_PROFILE="${FOUNDRY_PROFILE:-e2e}"
SLEEP_BETWEEN="${SLEEP_BETWEEN:-30}"

BLOCKSCOUT_BASE="${VERIFIER_URL%/api}"

call() { cast call "$1" "$2" ${3:+"$3"} --rpc-url "$RPC"; }
num() { awk '{print $1}'; }                    # "1000000000000000000000000000 [1e27]" -> first field
str() { sed -e 's/^"//' -e 's/"$//'; }         # strip cast's surrounding quotes

is_verified() {
    # Best effort — on API failure assume unverified and let the submission decide.
    curl -sf --max-time 15 "$BLOCKSCOUT_BASE/api/v2/smart-contracts/$1" 2>/dev/null \
        | grep -q '"is_verified"[[:space:]]*:[[:space:]]*true'
}

verify_token() {
    local token="$1"
    echo "=== $token ==="

    if is_verified "$token"; then
        echo "    already verified, skipping"
        return 0
    fi

    local pm posm permit2 fee_rcpt treasury creator supply p_bps h_bps b_bps name symbol
    pm=$(call "$token" "poolManager()(address)")            || { echo "    getter failed"; return 1; }
    posm=$(call "$token" "POSM()(address)")
    permit2=$(call "$token" "PERMIT2()(address)")
    fee_rcpt=$(call "$token" "feeRecipient()(address)")
    treasury=$(call "$token" "platformTreasury()(address)")
    creator=$(call "$token" "creator()(address)")
    supply=$(call "$token" "SUPPLY()(uint256)" | num)
    p_bps=$(call "$token" "PROTOCOL_FEE_BPS()(uint256)" | num)
    h_bps=$(call "$token" "HOLDER_FEE_BPS()(uint256)" | num)
    b_bps=$(call "$token" "BURN_FEE_BPS()(uint256)" | num)
    name=$(call "$token" "name()(string)" | str)
    symbol=$(call "$token" "symbol()(string)" | str)
    echo "    $name ($symbol)  fees=($p_bps,$h_bps,$b_bps)  creator=$creator"

    local args
    args=$(cast abi-encode \
        "c(address,address,address,address,address,address,address,uint256,string,string,(uint256,uint256,uint256))" \
        "$pm" "$LAUNCHPAD" "$posm" "$permit2" "$fee_rcpt" "$treasury" "$creator" \
        "$supply" "$name" "$symbol" "($p_bps,$h_bps,$b_bps)") || { echo "    encode failed"; return 1; }

    local attempt
    for attempt in 1 2 3; do
        if forge verify-contract "$token" src/CoilHook.sol:CoilHook \
            --verifier blockscout --verifier-url "$VERIFIER_URL" \
            --constructor-args "$args"; then
            echo "    submitted OK"
            return 0
        fi
        echo "    attempt $attempt failed (Blockscout API flaky), waiting 60s..."
        sleep 60
    done
    echo "    FAILED after 3 attempts — re-run later: ./verify-tokens.sh $token"
    return 1
}

if [ $# -ge 1 ]; then
    verify_token "$1"
    exit $?
fi

count=$(cast call "$LAUNCHPAD" "marketsCount()(uint256)" --rpc-url "$RPC" | num)
echo "Launchpad $LAUNCHPAD has $count markets"

failed=0
for ((i = 0; i < count; i++)); do
    token=$(cast call "$LAUNCHPAD" \
        "markets(uint256)(address,address,bool,string,string,string,uint256)" "$i" \
        --rpc-url "$RPC" | head -1 | num)
    verify_token "$token" || failed=$((failed + 1))
    [ "$i" -lt $((count - 1)) ] && sleep "$SLEEP_BETWEEN"
done

echo
if [ "$failed" -gt 0 ]; then
    echo "$failed token(s) failed — re-run this script, already-verified ones are skipped."
    exit 1
fi
echo "All tokens submitted. Check the green ✓ on Blockscout in a few minutes."
