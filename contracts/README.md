# Quiver — contracts

Uniswap v4 hook that is simultaneously the ERC-20 (`QUIVER`), the LP owner, the fee router, and
an ERC-721 ledger (`Arrow` / `Quiver-LP`). Faithful adaptation of [Prism](https://github.com/0xsolazy/prism),
retargeted to Robinhood Chain with a supply of **4663** (the chain id; HOOD in T9).

| Contract | Role |
| --- | --- |
| `src/QuiverHook.sol` | ERC-20 + v4 hook (afterSwap) + LP owner + MasterChef-style fee router + DN404-style packed NFT ledger |
| `src/QuiverMirror.sol` | Stateless ERC-721 facade; delegates all reads/writes to the hook |
| `src/QuiverArt.sol` | Fully on-chain generative SVG art (arrow ballistics), deterministic per token |
| `src/base/BaseHook.sol` | Minimal self-contained v4 hook base (validates address flags, guards callbacks) |

## Layout

```
src/            the contracts
test/           unit suite (mock v4) — runs anywhere
test/e2e/       end-to-end suite against a real PoolManager + PositionManager (native solc)
test/mocks/     lightweight v4 stand-ins for the unit suite
script/         Deploy (CREATE2 + hook-address mining) and Seed (one-shot launch)
art-samples/    a few rendered Arrow SVGs for reference
```

## Build & test

Dependencies are pinned and installed by `bootstrap.sh` (used by CI):

```bash
./bootstrap.sh
forge build
forge test -vv                                                  # unit suite
FOUNDRY_PROFILE=e2e forge test --match-path "test/e2e/**" -vv   # e2e suite
```

Compiler profiles: the default profile builds everything except `test/e2e/` with **via-IR at
800 optimizer runs** (our hook's inlined art library requires via-IR; 800 runs keeps it under
the EIP-170 size limit). The `e2e` profile mirrors upstream v4-core's settings (via-IR,
44444444 runs) — the only combination solc 0.8.26 compiles `Pool.sol` with under via-IR.

### Restricted networks (no native solc)

Where the solc binary hosts are blocked but npm is reachable, a solc-js shim lets Foundry compile.
The `sandbox` profile skips the heavy e2e compilation unit (which exceeds the WASM compiler's memory);
the mock-based unit suite gives full logic coverage:

```bash
npm install                 # brings in solc-js 0.8.26
FOUNDRY_PROFILE=sandbox forge test --use ./solc-wrapper.js
```

`solc-wrapper.js` and `package.json` exist solely for that fallback; CI uses a native solc and the
default and e2e profiles, compiling and running the full suite.

## Deploy (Robinhood Chain)

```bash
export POOL_MANAGER=0x...        # v4 PoolManager on chain 4663
export POSITION_MANAGER=0x...    # v4 PositionManager
export PERMIT2=0x000000000022D473030F116dDEE9F6B43aC78BA3
export HOOK_OWNER=0x...          # may call seed() once; renounced inside seed()

forge script script/Deploy.s.sol:DeployQuiver --rpc-url $RPC_URL --broadcast --private-key $PK

export HOOK=0x...                # from the deploy output
export TICK_LOWER=-6000
export TICK_UPPER=0
forge script script/Seed.s.sol:SeedQuiver --rpc-url $RPC_URL --broadcast --private-key $PK
```

`seed()` initializes the pool, deposits the whole 4663 supply as one-sided QUIVER liquidity, then
renounces ownership — a provably immutable fair launch.
