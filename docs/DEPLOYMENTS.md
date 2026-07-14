# Deployments

## Robinhood Chain — Uniswap v4 infrastructure

| | |
| --- | --- |
| Chain | Robinhood Chain (Arbitrum Orbit L2) |
| Chain ID | `4663` |
| RPC | `https://rpc.mainnet.chain.robinhood.com` |
| Explorer | `https://robinhoodchain.blockscout.com` |
| Native gas | ETH |

| Contract | Address |
| --- | --- |
| Uniswap v4 **PoolManager** | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| Uniswap v4 **PositionManager** | `0x58daec3116aae6D93017bAAea7749052E8a04fA7` |
| **Permit2** | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |

All three checksums validate. These feed `contracts/.env` (see `.env.example`) for the deploy and
seed scripts. They should still be confirmed on-chain via the Blockscout explorer before mainnet
deploy (the RPC was not reachable from the build environment to verify programmatically).

## Quiver contracts

Filled in after deploy + seed.

| Contract | Address |
| --- | --- |
| QuiverHook (ERC-20 `QUIVER`) | _TBD_ |
| QuiverMirror (ERC-721 `Arrow` / `QUIVER-LP`) | _TBD_ |
| POSM position tokenId (LP) | _TBD_ |
| Seed tx | _TBD_ |

After deploy, set `VITE_HOOK_ADDRESS` / `VITE_MIRROR_ADDRESS` for the web build so the site goes live.
