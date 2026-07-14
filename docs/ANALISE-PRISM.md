# Análise do projeto Prism

Referência: site `https://prism.0xsolazy.eth.limo/` · repositório `https://github.com/0xsolazy/prism` · X `@prism_lp`

## 1. O que é

Prism é "o primeiro token Uniswap v4 em que segurar é ganhar". Slogan do contrato: **"one v4 pool. five thousand facets."**

- Token ERC-20 **PRISM**, supply fixo de **5.000** (18 decimais).
- Cada 1 PRISM inteiro em carteira minta automaticamente **1 Prism NFT** (máx. 5.000 NFTs).
- Cada NFT é uma fração **1/5000** da **mesma e única posição LP** no Uniswap v4 (par ETH/PRISM).
- Taxas de todo swap (fee do pool = 1%) acumulam pró-rata para os NFTs vivos.
- Vender fração de um token inteiro **queima o NFT permanentemente** — 5.000 é teto, não piso. Deflação de shares: quem fica ganha fatia maior.
- **Sem staking, sem wrapper de LP, sem approve de router.** A UX é: comprou → segurou → ganha.

Lançado na Ethereum em maio/2026 por um anon (0xsolazy, com ajuda de "Colby"). Fair launch: 100% do supply é mintado para o próprio contrato e depositado como liquidez unilateral no `seed()`. ATH de market cap ~$6M; gerou um ecossistema derivado (Spectrum — launchpad de índices que usa 90% da receita para buy&burn de PRISM; dStable — camada de settlement), coberto pela newsletter do Zeneca (Letter 117).

## 2. Estrutura do repositório

Repositório minimalista e 100% Solidity — apenas 3 contratos publicados (1 commit, sem framework):

```
PrismArt.sol      — biblioteca de arte SVG on-chain
PrismHook.sol     — contrato central (ERC20 + hook v4 + LP + fees + NFT ledger)
PrismMirror.sol   — fachada ERC-721
base/BaseHook.sol — base padrão de hook v4 (importado pelo PrismHook)
```

Dependências: Solady (ERC20, Ownable, ReentrancyGuard), Uniswap v4-core / v4-periphery, Permit2. Pragma `^0.8.26` (usa transient storage / `tstore`).

## 3. Os contratos em detalhe

### 3.1 PrismHook.sol — o núcleo

Um único contrato que é, ao mesmo tempo:

1. **O ERC-20** (Solady) — `name() = "Prism"`, `SUPPLY = 5000 ether`, `UNIT = 1 ether`.
2. **O hook do pool v4** — permissão `afterSwap` apenas (no-op funcional; a flag existe para o endereço do hook ser válido e o pool ser exclusivo do contrato). Pool: `currency0 = ETH nativo (address(0))`, `currency1 = o próprio token`, `fee = 10_000` (1%), `tickSpacing = 200`.
3. **O dono da posição LP** — `seed()` (onlyOwner, uma única vez) inicializa o pool no PositionManager (POSM) via multicall e minta a posição com todo o supply, unilateral em token (preço inicial abaixo do range ⇒ 100% token, 0 ETH ⇒ fair launch sem capital do deployer).
4. **O ledger NFT estilo DN404** — inspirado no DN404 do Vectorized:
   - `_afterTokenTransfer` do ERC-20 realinha NFTs: `alvo = balanceOf(user) / UNIT`; minta/queima/move NFTs para bater com o alvo (`_realignSolo` / `_realignPair`).
   - Storage agressivamente empacotado: `_oo` (owner 160 bits + ownedIndex 32 bits num slot), `_ownedSlots` (8 tokenIds uint32 por slot), `_addressData`, `_feeDebt` (dívida ETH + dívida token em um slot). Objetivo: 1 SSTORE frio por mint em vez de vários.
   - Endereços de infra (PoolManager, o próprio hook) são ignorados no realinhamento — o pool não minta NFTs.
   - Flag transiente `_SILENT_SLOT` (tstore/tload) evita realinhamento recursivo quando a transferência ERC-20 é disparada por uma transferência de NFT via mirror.
5. **O distribuidor de taxas** — modelo MasterChef (acumulador por share):
   - `pokeFees()`: coleta fees da posição (DECREASE_LIQUIDITY com 0 + TAKE_PAIR) e incrementa `accFeesPerShareETH/PRISM` (escala 1e12), denominador = `totalShares` (nº de NFTs vivos).
   - `_maybePoke()` antes de mints (não durante swap — checa `poolManager.isUnlocked()`): novos NFTs entram com `feeDebt` atual e não diluem fees passadas.
   - `claim(tokenId)` / `claimMany`: paga ETH + PRISM devidos ao dono do NFT; falha no envio de ETH cai em `pendingETH` (pull-payment).
   - Burns e transferências de NFT capturam o devido em `pendingETH/PRISM` do holder (`withdrawPending()`), então fee acumulada nunca se perde — só a **participação futura** morre com o burn.

### 3.2 PrismMirror.sol — a fachada ERC-721

Contrato fino, "Prism-LP". Não guarda estado: todos os `ownerOf/balanceOf/tokenURI/approve/transferFrom` delegam ao hook (`handleNFTTransfer/Approve/SetApprovalForAll`, `nft*` views). O hook chama de volta `emitTransfer/emitApproval` (onlyHook) para os eventos saírem do endereço do mirror — é isso que marketplaces indexam. Transferir o NFT move também 1 token ERC-20 (com a flag silent ligada). Auto-transferência é proibida (evitaria colheita grátis de pending).

### 3.3 PrismArt.sol — arte on-chain

Biblioteca pura, sem storage. `tokenURI(id, seed)` retorna `data:application/json;base64` com SVG embutido. Seed determinística: `keccak256(id, address(hook))` — nenhum byte de arte em storage. O SVG (400×400) é um **diagrama técnico de óptica**: grid tênue, prisma isométrico wireframe, feixe de luz branco incidente e um único feixe refratado colorido (a única cor da peça), anotações tipo blueprint (crosshair, arco de ângulo), bloco de título monospace com digest da seed, índice de refração *n* e comprimento de onda λ. Traits: Hue (0–360), Refractive Index (1.450–1.650), Wavelength (410–699 nm), derivados de bytes individuais da seed.

## 4. A estratégia (por que funcionou)

1. **Mecânica nova e explicável em uma frase** — "segurar é prover liquidez". O produto *é* o meme.
2. **Fair launch verificável on-chain** — 100% do supply na pool, sem alocação de time, sem pré-venda. O deployer não coloca ETH (liquidez unilateral).
3. **Incentivo a segurar unidades inteiras** — vender fração queima o NFT para sempre ⇒ pressão psicológica/econômica contra dump; deflação de shares recompensa holders.
4. **Yield real, não emissão** — as taxas vêm do volume do próprio pool (1%), em ETH + token. Sem inflação, sem promessas.
5. **Escassez com identidade** — 5.000 NFTs com arte on-chain minimalista e temática coerente (óptica/prisma) dá camada de colecionável e negociabilidade em marketplaces NFT "de graça".
6. **Site minimalista auto-hospedado** (ENS + IPFS via eth.limo) reforça o ethos cripto-nativo/imutável.
7. **Superfície de código pequena e legível** — 3 contratos, código comentado, inspiração declarada (DN404) — facilita a devida diligência da comunidade.

## 5. Riscos/pontos de atenção observados no design

- `seed()` é `onlyOwner` e único; depois disso o owner não tem poderes sobre fundos (sem rug óbvio), mas o contrato **não é imutável quanto ao Ownable** (renunciar ownership pós-seed é boa prática a considerar no nosso).
- `pokeFees()` é público e chamado em mints — custo de gás recai no comprador que cruza um limiar de unidade.
- Aritmética do acumulador satura em uint128 com `ACC_SCALE = 1e12` (documentado no código; suficiente na prática).
- A posição LP nunca é removida — liquidez efetivamente travada para sempre (feature, não bug: é o pitch).
