# Quiver — web

Static launch site (Vite + React + TypeScript + viem). Blueprint aesthetic; wallet integration via
the injected EIP-1193 provider (no heavy connector dependency tree). Builds to a fully static,
IPFS-ready `dist/` (relative asset paths).

## Develop

```bash
npm install
npm run dev
```

## Build

```bash
npm run build      # → dist/
npm run preview
```

## Configuration

The bundle targets Robinhood Chain (id 4663) by default. Override at build time so the same site can
point at testnet or a specific deployment:

| Env var | Meaning |
| --- | --- |
| `VITE_RPC_URL` | RPC endpoint (default: mainnet Robinhood Chain) |
| `VITE_HOOK_ADDRESS` | Deployed QuiverHook (ERC-20). Empty → pre-launch UI |
| `VITE_MIRROR_ADDRESS` | Deployed QuiverMirror (ERC-721) |

With no address set the site shows a pre-launch state; the moment `VITE_HOOK_ADDRESS` is provided,
live counters, the "My Quiver" panel (arrows + on-chain art + fee claiming), and explorer links
activate.
