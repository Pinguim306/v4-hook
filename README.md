# Quiver

> one v4 pool. 4663 arrows.

**Quiver** é um token de lançamento justo na **Robinhood Chain** nos moldes do [Prism](https://prism.0xsolazy.eth.limo/) ([código](https://github.com/0xsolazy/prism)): o primeiro token da Robinhood Chain em que **segurar é prover liquidez**.

- Cada **1 QUIVER** inteiro em carteira minta automaticamente **1 Arrow NFT** (ERC-721, arte 100% on-chain).
- Cada Arrow é uma fração **1/4663** da mesma e única posição de liquidez Uniswap v4.
- As taxas de todo swap no pool acumulam pró-rata para os Arrows — **sem staking, sem wrapper, sem approve de router**. Só segurar.
- Vendas fracionárias queimam o Arrow correspondente **permanentemente**: 4663 é teto, não piso. Menos arrows vivos = fatia maior de taxas para quem fica.

O supply de **4663** é uma homenagem à chain: `4663` é o chain ID da Robinhood Chain (**HOOD** em T9).

## Arquitetura (herdada do Prism)

| Contrato | Papel |
| --- | --- |
| `QuiverHook.sol` | ERC-20 + hook Uniswap v4 + dono da posição LP + roteador de taxas + lógica NFT estilo DN404 (storage empacotado) |
| `QuiverMirror.sol` | Fachada ERC-721 ("Quiver-LP") que delega todo estado ao hook |
| `QuiverArt.sol` | Arte generativa SVG on-chain — diagramas de balística de flecha, seed determinística por id |

## Rede

| | |
| --- | --- |
| Chain | Robinhood Chain (Arbitrum Orbit L2) |
| Chain ID | `4663` |
| RPC | `https://rpc.mainnet.chain.robinhood.com` |
| Explorer | `https://robinhoodchain.blockscout.com` |
| Gás | ETH (sub-centavo, blocos ~0,1s) |
| DEX | Uniswap v4 (live na chain) |

## Estrutura do repositório

```
contracts/   Foundry — QuiverHook, QuiverMirror, QuiverArt, BaseHook, testes e scripts de deploy
web/         Site de lançamento (Vite + React + TypeScript + viem), estático/IPFS-ready
docs/        Análise do Prism e plano de entrega
.github/     CI (forge build/test + build do site)
```

## Estado atual

| Fase | Estado |
| --- | --- |
| 1 · Fundação do repositório | ✅ Foundry + web + CI |
| 2 · Contratos | ✅ Hook, Mirror, Art, BaseHook (compilam) |
| 3 · Testes | ✅ 22 testes unitários (mock v4) passando · suíte e2e vs PoolManager/POSM reais reservada para CI |
| 4 · Deploy | ✅ scripts (CREATE2 + mineração de hook + seed) — **pendente P0**: endereços do v4 na chain 4663 |
| 5 · Site | ✅ build de produção funcional |
| 6 · Lançamento/comms | ⏳ após deploy em testnet/mainnet |

## Documentação

- [Contratos](contracts/README.md) — como buildar, testar e fazer deploy
- [Site](web/README.md) — como rodar e configurar
- [Análise do projeto Prism](docs/ANALISE-PRISM.md) — estrutura, estratégia e contratos do projeto de referência
- [Plano de entrega](docs/PLANO-DE-ENTREGA.md) — fases, entregáveis, riscos e cronograma do Quiver
