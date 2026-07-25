# Deployments

## Arc Testnet (Circle) — self-deployed Uniswap v4 infrastructure

Deployed 2026-07-17 via `script/arc/DeployArcV4Stack.s.sol` (see docs/MULTICHAIN-ARC.md).

| | |
| --- | --- |
| Chain | Arc (Circle L1 "stablechain") — public testnet |
| Chain ID | `5042002` |
| RPC | `https://rpc.testnet.arc.network` |
| Explorer | `https://testnet.arcscan.app` (Blockscout) |
| Native gas | USDC (18-decimal native scaling, probed on-chain) |
| Deployer / PoolManager owner | `0xD2bb88DCCF3835B5dC24D08e6Bf40578a5889265` |

| Contract | Address |
| --- | --- |
| Uniswap v4 **PoolManager** | `0x46Eb19af432954d126077E1764ef5F6A0013dE68` |
| **WrappedNative** (WUSDC, 18 dec) | `0xCAC743f6e58aB2585B513457867E6848aBa145c8` |
| **PositionDescriptor** (no proxy) | `0x1b0509784F26337d5dcb45513d17761fBBfce02D` |
| Uniswap v4 **PositionManager** | `0xf1F19d6E6345E233D6D34EF3e0c390CE5DFf7D49` |
| **Permit2** (pre-existing, canonical) | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |

Compiler notes for verification: PoolManager/WrappedNative at profile.e2e settings
(0.8.26, via-IR, 44444444 runs); PositionManager at 500 runs and PositionDescriptor
at 1 run (the e2e profile's compilation_restrictions, mirroring upstream).
CoilLaunchpad for Arc: pending (waiting on launch-price ticks — see MULTICHAIN-ARC.md).

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

Deployed on Robinhood Chain (4663), 2026-07.

| Contract | Address |
| --- | --- |
| QuiverHook (ERC-20 `QUIVER`) | `0xB3071C5c5F5f1762eC635Dff76e2AB07B1Eb0040` |
| QuiverMirror (ERC-721 `Arrow` / `QUIVER-LP`) | `0x4f2F1B0Da1cBa6F08ccAfA4ED62b82a2a077Fb84` |
| Deploy owner | `0x1f44d7645cfdB900472A54FFF0E4e762D1d75230` |
| Deploy tx | `0x514ac6443078035200ee24b25680025b8b4c82279293e97a4f66926b35658ca5` |
| POSM position tokenId (LP) | `106484` |
| Seed tx | `0x13c440eb0f65422bd3eb12b70baa95e38c3c4166504a6d480524b268d9fa3b10` |
| Owner after seed | `0x0000000000000000000000000000000000000000` (renounced) |
| Launch ticks | `TICK_LOWER=-887200`, `TICK_UPPER=69000` (~0.001 ETH/QUIVER) |

After deploy, set `VITE_HOOK_ADDRESS` / `VITE_MIRROR_ADDRESS` for the web build so the site goes live.
