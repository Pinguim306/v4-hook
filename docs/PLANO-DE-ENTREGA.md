# Plano de entrega — Quiver

Token de lançamento justo na **Robinhood Chain**, nos moldes do Prism (ver [ANALISE-PRISM.md](ANALISE-PRISM.md)).

## 0. Identidade do projeto

| | |
| --- | --- |
| **Nome** | **Quiver** (aljava — onde Robin Hood guarda as flechas) |
| **Token** | `QUIVER` (ERC-20, 18 decimais) |
| **NFT** | **Arrow** — coleção "Quiver-LP" (`QUIVER-LP`) |
| **Supply** | **4663** — o chain ID da Robinhood Chain (4663 = HOOD em T9) |
| **Slogan** | *"one v4 pool. 4663 arrows."* |
| **Tese** | Cada 1 QUIVER inteiro = 1 Arrow NFT = 1/4663 da única posição LP v4. Segurar é prover liquidez; taxas de todo swap acumulam pró-rata; vender fração queima a flecha para sempre. |
| **Arte** | Diagramas de balística de flecha 100% on-chain (SVG), no mesmo estilo blueprint/monospace do Prism: grid, trajetória parabólica da flecha, alvo, anotações de ângulo de disparo, velocidade e alcance como traits |

O nome segue a mesma lógica do Prism (substantivo concreto de uma sílaba forte, metáfora que explica a mecânica): a **aljava (Quiver)** é o pool único; cada **flecha (Arrow)** é uma share. Disparar (vender) uma flecha fracionada a destrói. Alternativas consideradas e mantidas como reserva: *Longbow*, *Fletch*, *Sherwood*.

## 1. Rede e dependências

| | |
| --- | --- |
| Chain | Robinhood Chain — Arbitrum Orbit L2, mainnet desde 01/jul/2026 |
| Chain ID | `4663` |
| RPC | `https://rpc.mainnet.chain.robinhood.com` (Alchemy/QuickNode/dRPC também suportam) |
| Explorer | Blockscout — `https://robinhoodchain.blockscout.com` |
| Gás | ETH nativo, sub-centavo, blocos ~0,1s |
| Uniswap | v2/v3/**v4** e UniswapX live na chain (anúncio oficial da Uniswap) |
| Testnet | Robinhood Chain testnet pública (dry-run antes do mainnet) |

**P0 (resolvida):** endereços do v4 na Robinhood Chain (chain 4663) — registrados em [DEPLOYMENTS.md](DEPLOYMENTS.md) e em `contracts/.env.example`:

- PoolManager: `0x8366a39CC670B4001A1121B8F6A443A643e40951`
- PositionManager: `0x58daec3116aae6D93017bAAea7749052E8a04fA7`
- Permit2: `0x000000000022D473030F116dDEE9F6B43aC78BA3`

Checksums validados. Falta apenas confirmar on-chain no Blockscout antes do deploy em mainnet (o RPC não estava acessível no ambiente de build para verificação programática).

## 2. Fases e entregáveis

### Fase 1 — Fundação do repositório (0,5 dia)

- Workspace: `contracts/` (Foundry) + `web/` (Vite + React + TypeScript + wagmi/viem) + `docs/`.
- Dependências pinadas: solady, v4-core, v4-periphery, permit2.
- CI (GitHub Actions): `forge build`, `forge test`, lint do front.

**Critério de aceite:** `forge test` e `npm run build` verdes no CI.

### Fase 2 — Contratos (2–3 dias)

Adaptação fiel da arquitetura Prism, com mudanças mínimas e conscientes:

| Contrato | Base | Mudanças |
| --- | --- | --- |
| `QuiverHook.sol` | PrismHook | `SUPPLY = 4663 ether`; nome/símbolo; mesmos parâmetros de pool (fee 1%, tickSpacing 200, par ETH nativo/token, flag `afterSwap`) |
| `QuiverMirror.sol` | PrismMirror | nome "Quiver-LP" / símbolo "QUIVER-LP" |
| `QuiverArt.sol` | PrismArt | **reescrita criativa**: trajetória de flecha em vez de refração de luz. Traits: `Launch Angle` (°), `Draw Weight` (lb), `Range` (m), `Fletching Hue` (0–360). Mesma técnica: seed `keccak256(id, address(this))`, SVG 400×400, base64 JSON |
| `base/BaseHook.sol` | idem Prism | sem mudanças |

Melhorias pontuais sobre o original (baixo risco, alto valor):

- Renúncia de ownership embutida: `seed()` já chama `renounceOwnership()` ao final (no Prism o owner permanece, ainda que sem poderes sobre fundos).
- Comentários NatSpec em inglês, docs em PT-BR.

**Critério de aceite:** compila com otimizador (via-IR desligado — o pipeline IR do solc 0.8.26 não compila o PoolManager do v4-core); diff auditável contra o original.

### Fase 3 — Testes (2–3 dias)

- **Unit (Foundry):** realinhamento ERC20↔NFT (mint/burn/move, pares e solo), contabilidade de fees (acumulador, feeDebt, pending), mirror (transfer/approve/operator, safeTransfer, auto-transferência proibida), arte (tokenURI válido, determinismo da seed).
- **Fuzz/invariantes:** `totalShares == Σ NFTs vivos`; `Σ balances inteiros ≥ totalShares`; fees creditadas nunca excedem fees coletadas; nenhum caminho permite claim duplo.
- **Fork test** contra a Robinhood Chain mainnet (RPC público): `seed()` real contra o POSM da chain, swap via UniversalRouter, `pokeFees()`, `claim()` ponta a ponta.
- Gas snapshot dos caminhos quentes (transfer que cruza limiar de unidade).

**Critério de aceite:** 100% dos testes verdes, incluindo fork test na chain real.

### Fase 4 — Deploy e seed (1 dia + janela de lançamento)

1. **Mineração do endereço do hook** (HookMiner/CREATE2): o endereço precisa codificar a flag `AFTER_SWAP`.
2. Script Foundry de deploy parametrizado (POSM, Permit2, PoolManager, owner).
3. **Testnet primeiro:** ciclo completo (deploy → seed → swaps → poke → claim) na Robinhood testnet.
4. Mainnet: deploy, verificação no Blockscout, `seed()` com preço inicial e range definidos (liquidez unilateral em QUIVER, full-range-equivalente como o Prism), renúncia de ownership.
5. Registro público dos endereços em `docs/DEPLOYMENTS.md`.

**Critério de aceite:** pool ativo no Uniswap na Robinhood Chain; compra de QUIVER minta Arrow NFT visível no Blockscout.

### Fase 5 — Site (3–4 dias, em paralelo às fases 2–4)

Estático e auto-hospedável (IPFS-ready), estética Prism: fundo escuro, monospace, diagramas técnicos, quase nenhum framework visual.

Seções:

1. **Hero** — slogan, contadores live (arrows vivos / 4663, fees acumuladas em ETH e QUIVER, preço).
2. **Mecânica** — explicação em 4 passos com diagramas (comprar → mintar → acumular → queimar).
3. **Swap** — botão "Buy QUIVER" integrando o Uniswap (link direto para a interface na Robinhood Chain; embed opcional via UniversalRouter em v2 do site).
4. **My Quiver** — conecta carteira (wagmi): lista Arrows do usuário renderizando o SVG on-chain via `tokenURI`, fees pendentes por NFT, botões `claim`/`claimMany`/`withdrawPending`.
5. **Gallery** — grid dos Arrows vivos (leitura via eventos do mirror/Blockscout API).
6. **Docs/FAQ** — endereços dos contratos, links do explorer, código-fonte, riscos.

**Critério de aceite:** site funcional apontando para mainnet, publicado em IPFS + domínio (ENS `.eth.limo` como o Prism e/ou domínio convencional).

### Fase 6 — Lançamento e comunicação (contínuo)

- Conta X do projeto (nos moldes de `@prism_lp`), thread de lançamento explicando a mecânica e o fair launch.
- Publicação do código no GitHub (repo público, como o Prism — a legibilidade do código é parte do marketing).
- Registro do token no Blockscout (logo/metadata), DEX Screener e CoinGecko após tração.
- Aproveitar timing: janela de gás patrocinado da Robinhood Chain (90 dias pós-mainnet) e o programa de US$1M da Arbitrum Open House para builders na chain.

## 3. Cronograma resumido

| Semana | Entrega |
| --- | --- |
| 1 | Fases 1–2 (fundação + contratos) e início da 3 (testes) e 5 (site) |
| 2 | Fase 3 completa, dry-run em testnet (fase 4), site beta |
| 3 | Review externo do diff vs Prism, deploy mainnet, seed, site live, comms |

## 4. Riscos e mitigações

| Risco | Impacto | Mitigação |
| --- | --- | --- |
| Endereços/versões do v4 na Robinhood Chain divergirem do esperado (POSM sem `initializePool` no multicall etc.) | Alto | Fork test na chain real antes de qualquer deploy (fase 3); pendência P0 |
| Bug introduzido na adaptação (arte/realinhamento) | Alto | Mudanças mínimas + diff auditável contra o Prism + invariantes fuzz |
| Colisão de nome/ticker (existe token "4663" na chain; "Quiver" em outros contextos fintech) | Médio | Checar ticker no Blockscout/DEX Screener antes do deploy; alternativas Longbow/Fletch/Sherwood prontas |
| eth.limo/ENS pode não ser o canal ideal para público Robinhood | Baixo | Publicar em IPFS **e** domínio convencional |
| `pokeFees()` custoso no primeiro comprador pós-acúmulo | Baixo | Cron/keeper opcional chamando `pokeFees()` periodicamente |

## 5. Fora de escopo (v1)

- Ecossistema derivado tipo Spectrum/dStable (fase futura, se houver tração).
- Auditoria formal paga (substituída por review + fidelidade ao original battle-tested; reavaliar se TVL crescer).
- Embed de swap próprio no site (v1 linka para a interface da Uniswap).
