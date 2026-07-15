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

## Arquivos

- `contracts/src/CoilHook.sol` — o hook (ERC-20 + LP owner + roteador de taxa).
- `contracts/test/CoilHookUnit.t.sol` — 15 testes de lógica (mocks v4): split, acumulador
  pro-rata, comprador tardio não divide taxa passada, primeiro buy roteia holder→treasury,
  claim, sweeps, invariante de `circulating`, guards de fee, fuzz anti-dust.
- `contracts/test/e2e/CoilHookE2E.t.sol` — prova end-to-end contra PoolManager/POSM reais
  (swaps de verdade): a taxa é skimmada no swap, holders acumulam, protocolo saca.
- `contracts/test/e2e/CoilHookFork.t.sol` — ciclo completo contra a Robinhood Chain real.
- `contracts/script/DeployCoil.s.sol` — deploy com mineração CREATE2 pras flags
  `BEFORE_SWAP | BEFORE_SWAP_RETURNS_DELTA` (`0x88`).

## Como rodar

**Unit (rápido, sem chain — compilador WASM do sandbox):**

```bash
cd contracts
FOUNDRY_PROFILE=sandbox forge test --use ./solc-wrapper.js --match-contract CoilHookUnitTest -vv
```

**E2E contra um stack v4 local (precisa de solc nativo):**

```bash
FOUNDRY_PROFILE=e2e forge test --match-contract CoilHookE2ETest -vv
```

**Fork contra a Robinhood Chain real (a prova definitiva antes de gastar gás):**

```bash
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

## Próximo (Fase B)

Fazer o `Launchpad.sol` do Coil gravar o `CoilHook` na graduação (no lugar do
`FeeLocker`), minerando o endereço com o `HookMiner`. O front-end lê os novos campos de fee e
remove o botão de harvest (agora automático). Detalhes em `COIL-V4-PLANO.md`.
