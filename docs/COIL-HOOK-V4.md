# CoilHook — o motor de lucro do Coil em v4 (Fase A)

Primeira peça da migração v3 → v4 do Coil (o plano completo está em
`COIL-V4-PLANO.md`). Aqui está o **núcleo do lucro**: um hook Uniswap v4 que cobra uma
taxa nativa em **todo swap** e a divide, on-chain, na cascata escolhida **0,50 / 0,30 / 0,20**.

Foi desenvolvido dentro deste repositório (o do Quiver) porque reaproveita todo o setup —
`BaseHook`, o seed de liquidez travada, a mineração CREATE2 e a infra de teste contra a
Robinhood Chain real. A portabilidade pro repositório do Coil (o `Launchpad` gravar este
hook no lugar do `FeeLocker`) é a **Fase B**.

## O que muda em relação ao v3

| v3 (hoje) | v4 (`CoilHook`) |
| --- | --- |
| Captura de volume via `FeeLocker.collect()` **manual** + `postGradTaxBps` (fee-on-transfer) | Taxa cobrada **dentro do swap** via `beforeSwap` + `beforeSwapReturnDelta` |
| Fee-on-transfer **quebra** em muitos routers/agregadores | Limpo — funciona com Uniswap, 1inch, agregadores, bots |
| Precisa de botão de harvest | **Automático** — a taxa sai a cada trade |
| `FeeLocker` guarda a posição | O **hook é dono** e trava a liquidez no `seed()`, e renuncia ownership |

## A cascata (1% do swap, dividido no próprio hook)

```
Swap  →  taxa 1% sobre o input (ETH nas compras, token nas vendas)  →  no hook:
    ├─ 0,50%  PROTOCOLO  → feeRecipient (sua carteira)          ← lucro por volume
    ├─ 0,30%  HOLDERS    → dividendos pro-rata por saldo (acumulador)
    └─ 0,20%  BURN       → platformTreasury (buy&burn do COIL)
```

- **`POOL_FEE = 0`**: toda a captura passa pelo hook, então o trader **nunca** paga taxa dupla
  (não há LP fee separada). O split é 100% controlável.
- **Taxa cobrada no *specified currency***: em swaps exact-input (o padrão de routers e
  agregadores) isso é o **input** — ETH na compra, token na venda —, então **as duas direções
  pagam**.
- **Config imutável**: `protocolBps`/`holderBps`/`burnBps`, `feeRecipient` e `platformTreasury`
  são fixados no construtor. Teto de segurança `MAX_TOTAL_FEE_BPS = 5%`.
- **Accrue-and-pull**: dentro do swap o hook só faz contabilidade (sem chamadas externas), então
  não há superfície de reentrância. `feeRecipient` e `platformTreasury` recebem via `sweep*()`
  permissionless; holders via `claim()`.
- **Sem NFT**: token ERC-20 puro. O acumulador de dividendos é o mesmo do Quiver, mas com as
  *shares* = saldo do token (não contagem de NFT). Endereços do protocolo (hook, pool,
  feeRecipient, treasury) são excluídos do `circulating` pra nunca diluir holders reais.
- **Dois modos de rewards** (fixado no launch, imutável): `creator == address(0)` → **Loop
  Rewards** (a fatia de holders vira dividendo pra todos os holders — o loop clássico "segurar é
  prover liquidez"); `creator != 0` → **Creator Rewards** (essa fatia vai pro criador, via
  `sweepCreator()`). Paridade com o modo do Ouroboros v3.

## Arquivos

**Fase A — o hook:**
- `contracts/src/CoilHook.sol` — o hook (ERC-20 + LP owner + roteador de taxa, Loop/Creator).
- `contracts/test/CoilHookUnit.t.sol` — 16 testes de lógica (mocks v4): split, acumulador
  pro-rata, comprador tardio não divide taxa passada, primeiro buy roteia holder→treasury,
  claim, sweeps, invariante de `circulating`, guards de fee, fuzz anti-dust, Creator Rewards.
- `contracts/test/e2e/CoilHookE2E.t.sol` — prova end-to-end contra PoolManager/POSM reais
  (swaps de verdade): a taxa é skimmada no swap, holders acumulam, protocolo saca.
- `contracts/test/e2e/CoilHookFork.t.sol` — ciclo completo contra a Robinhood Chain real.
- `contracts/script/DeployCoil.s.sol` — deploy avulso do hook com mineração CREATE2 (`0x88`).

**Fase B — o launchpad:**
- `contracts/src/CoilLaunchpad.sol` — a fábrica: `createTokenV4()` deploya o `CoilHook` num
  endereço CREATE2 minerado (salt vem do front-end), chama `seed()` e registra o market. Sem
  FeeLocker, sem harvest, sem postGradTax. `LAUNCHPAD_VERSION = 3`.
- `contracts/test/CoilLaunchpadUnit.t.sol` — 6 testes (mocks + `HookMiner`): launch Loop e
  Creator, endereço minerado bate, seed+renúncia, market, creation fee, refund, salt errado reverte.
- `contracts/test/e2e/CoilLaunchpadE2E.t.sol` — launch pela fábrica → seed real → swap real → taxa.
- `contracts/script/DeployCoilLaunchpad.s.sol` — deploy do launchpad (pricing computado no script).

## Como rodar

**Unit (rápido, sem chain — compilador WASM, perfil default com via-IR):**

```bash
cd contracts
forge test --use ./solc-wrapper.js            # 44 testes: CoilHook + CoilLaunchpad + Quiver
```

O launchpad embute `new CoilHook{salt}(...)` numa função grande e exige via-IR; por isso roda no
perfil **default** (via-IR), não no `sandbox` legacy. O `sandbox` cobre o resto:
`FOUNDRY_PROFILE=sandbox forge test --use ./solc-wrapper.js`.

**E2E / Fork contra v4 real (precisa de solc nativo):**

```bash
FOUNDRY_PROFILE=e2e forge test --match-contract CoilHookE2ETest -vv
FOUNDRY_PROFILE=e2e forge test --match-contract CoilLaunchpadE2ETest -vv
FOUNDRY_PROFILE=e2e forge test --match-contract CoilHookForkTest \
  --fork-url https://rpc.mainnet.chain.robinhood.com -vv
```

## Como deployar

```bash
export POOL_MANAGER=0x8366a39CC670B4001A1121B8F6A443A643e40951
export POSITION_MANAGER=0x58daec3116aae6D93017bAAea7749052E8a04fA7
export PERMIT2=0x000000000022D473030F116dDEE9F6B43aC78BA3
export HOOK_OWNER=<carteira que chama seed()>
export FEE_RECIPIENT=<sua carteira de protocolo>
export PLATFORM_TREASURY=<tesouraria de buy&burn do COIL>
export TOKEN_SUPPLY=1000000000000000000000000   # 1.000.000 * 1e18
export TOKEN_NAME="Meu Token"
export TOKEN_SYMBOL="MEU"
# opcionais (default 50/30/20):
# export PROTOCOL_FEE_BPS=50 HOLDER_FEE_BPS=30 BURN_FEE_BPS=20

FOUNDRY_PROFILE=e2e forge script script/DeployCoil.s.sol:DeployCoil \
  --rpc-url "$RPC_URL" --broadcast --private-key "$PK"
```

Depois: `seed(sqrtPriceX96, tickLower, tickUpper, liquidity)` inicializa o pool, deposita a
liquidez de um lado só e renuncia ownership — igual ao Quiver.

### Deploy do launchpad (Fase B)

```bash
export POOL_MANAGER=0x8366a39CC670B4001A1121B8F6A443A643e40951
export POSITION_MANAGER=0x58daec3116aae6D93017bAAea7749052E8a04fA7
export PERMIT2=0x000000000022D473030F116dDEE9F6B43aC78BA3
export LAUNCHPAD_OWNER=<admin do launchpad>
export FEE_RECIPIENT=<sua carteira de protocolo>
export PLATFORM_TREASURY=<tesouraria de buy&burn do COIL>
export TOKEN_SUPPLY=1000000000000000000000000   # supply por launch
export CREATION_FEE=0                            # taxa nativa por launch (wei)
# opcionais: TICK_LOWER=-6000 TICK_UPPER=0 PROTOCOL_FEE_BPS=50 HOLDER_FEE_BPS=30 BURN_FEE_BPS=20

FOUNDRY_PROFILE=e2e forge script script/DeployCoilLaunchpad.s.sol:DeployCoilLaunchpad \
  --rpc-url "$RPC_URL" --broadcast --private-key "$PK"
```

## Fase B — como o front-end lança um token

O endereço do hook precisa carregar as flags `0x88`, então o **salt é minerado off-chain** e
passado pro launchpad:

1. O front-end lê `pad.hookInitCodeHash(name, symbol, creator)` (ou reconstrói os ctor args) e
   roda o `HookMiner` (deployer = endereço do launchpad) pra achar o `salt` cujo endereço bate as
   flags. `creator` = carteira do usuário se **Creator Rewards**, senão `address(0)`.
2. Chama `pad.createTokenV4{value: creationFee}(name, symbol, metadataURI, salt, creatorRewards)`.
3. O launchpad deploya o `CoilHook` naquele endereço (o construtor do hook valida as flags — salt
   errado reverte), chama `seed()`, registra o market e cobra o creation fee. O token está
   **tradável e cobrando taxa no mesmo bloco**.

Sem `FeeLocker`, sem botão de harvest, sem `postGradTaxBps` — a captura de taxa é nativa no swap.

## Port pro repositório do Coil (ex-Ouroboros)

Isto foi construído no repo do Quiver (v4-hook) porque reaproveita todo o stack v4 + a infra de
teste. Pra levar pro repo do Coil, é mecânico: copiar `CoilHook.sol`, `CoilLaunchpad.sol` e o
`base/BaseHook.sol`, adicionar as dependências v4 (`v4-core`, `v4-periphery`, `permit2`, `solady`)
e apontar o front-end (rota nova de launch v4) pro `CoilLaunchpad`. Os tokens v3 antigos
(bonding curve + `FeeLocker`) continuam funcionando lado a lado — o `LAUNCHPAD_VERSION = 3` deixa
o site detectar e mostrar a UI certa por token. Detalhes em `COIL-V4-PLANO.md`.
