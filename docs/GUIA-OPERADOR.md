# Guia do operador — colocando o Quiver no ar

Este é o guia de **tudo o que você precisa ter e fazer**, na ordem, para colocar os contratos e
o site em produção com tudo funcionando. Cada bloco diz o que fazer, o comando exato e como
saber que deu certo. Tempo total estimado: **~2 horas** (fora espera de bridge).

---

## Parte 0 — O que você precisa ter antes de começar

| # | Item | Detalhe |
| --- | --- | --- |
| 1 | **Máquina** com git, Node 20+ e Foundry | Foundry: `curl -L https://foundry.paradigm.xyz \| bash && foundryup` |
| 2 | **Carteira de deploy dedicada** | Crie uma carteira NOVA só para isso (`cast wallet new`). Nunca use sua carteira principal — a chave privada vai num `.env` local. |
| 3 | **ETH na Robinhood Chain** | ~0,05 ETH cobre deploy + seed + testes com folga (gás é sub-centavo). Como conseguir: bridge oficial em `docs.robinhood.com/chain` ou `portal.arbitrum.io` (Robinhood Chain é Arbitrum Orbit), enviando para o endereço da carteira de deploy. |
| 4 | **Onde publicar o site** (escolha 1) | a) Cloudflare Pages / Vercel / GitHub Pages (mais simples) · b) IPFS + ENS (`.eth.limo`, estilo Prism — precisa de um nome ENS e um serviço de pinning tipo Pinata/web3.storage) |
| 5 | **Repositório clonado** | `git clone <repo> && cd v4-hook` |
| 6 | (Opcional) Conta no X para o projeto | Para a thread de lançamento |

**Custo total on-chain estimado: < US$ 1 em gás** (blocos de 0,1s, gás sub-centavo) + o ETH que
ficar na carteira. O deployer **não coloca ETH na pool** — a liquidez é 100% em QUIVER.

---

## Parte 1 — Preparar e validar (sem gastar nada)

### 1.1 Instalar dependências e rodar a suíte completa

```bash
cd contracts
./bootstrap.sh          # instala as libs Solidity em commits pinados
forge build
forge test -vv                                          # suíte unitária (22 testes)
FOUNDRY_PROFILE=e2e forge test --match-path "test/e2e/**" -vv   # suíte e2e (PoolManager real)
```

✅ **Critério:** todos os testes passam nas duas suítes. A e2e usa o perfil `e2e` (configuração
de compilador do próprio Uniswap para o v4-core); é a primeira execução dela com solc nativo —
se algo falhar aqui, pare e me chame.

### 1.2 Pré-flight: validar a infra v4 da chain

```bash
./preflight.sh
```

✅ **Critério:** `7 passed, 0 failed`. Isso confirma on-chain que PoolManager, PositionManager
e Permit2 (endereços em [DEPLOYMENTS.md](DEPLOYMENTS.md)) existem e respondem às funções que o
Quiver chama.

### 1.3 Fork test: ensaio geral do lançamento

```bash
FOUNDRY_PROFILE=e2e forge test --match-contract QuiverForkTest \
  --fork-url https://rpc.mainnet.chain.robinhood.com -vv
```

✅ **Critério:** `test_Fork_FullLifecycle` PASS. Isso executa o lançamento inteiro (seed →
compra → mint de Arrow → fees → claim) contra os contratos reais da chain, em simulação local.
**Se este teste passa, o lançamento funciona.**

---

## Parte 2 — Decidir o preço de lançamento

O `seed()` é irreversível, então esta é a única decisão econômica que você precisa tomar antes.
O preço de 1 QUIVER em ETH no lançamento é `1,0001^(−TICK_UPPER)`:

| Preço inicial por QUIVER | FDV (4663 tokens) | `TICK_UPPER` |
| --- | --- | --- |
| ~0,0002 ETH | ~0,93 ETH | `85200` |
| ~0,0005 ETH | ~2,33 ETH | `76000` |
| **~0,001 ETH** | **~4,70 ETH** | **`69000`** ← recomendado |
| ~0,002 ETH | ~9,28 ETH | `62200` |
| ~0,005 ETH | ~23,3 ETH | `53000` |
| ~0,01 ETH | ~46,9 ETH | `46000` |

- `TICK_LOWER` define o **teto de valorização** (preço quando todo o supply for vendido).
  Use `-887200` (mínimo permitido) para não ter teto prático — recomendado.
- Ambos devem ser múltiplos de 200. O script valida.
- Referência: quanto MENOR o FDV inicial, mais espaço para a valorização inicial que
  recompensa os primeiros compradores (o Prism lançou com FDV baixo).

---

## Parte 3 — Deploy dos contratos (~10 min)

### 3.1 Configurar o ambiente

```bash
cd contracts
cp .env.example .env
```

Edite o `.env` e preencha:
- `HOOK_OWNER` = endereço da sua carteira de deploy
- `PK` = chave privada dela (nunca commite o `.env`)
- `TICK_UPPER` / `TICK_LOWER` = da Parte 2

```bash
source .env
```

### 3.2 Deploy

```bash
forge script script/Deploy.s.sol:DeployQuiver \
  --rpc-url $RPC_URL --broadcast --private-key $PK
```

**Anote da saída** (e cole no `.env` e em [DEPLOYMENTS.md](DEPLOYMENTS.md)):
- `QuiverHook deployed: 0x...`  → é o token QUIVER **e** o hook
- `QuiverMirror (ERC721): 0x...` → é a coleção Arrow

### 3.3 Conferir antes de prosseguir

```bash
export HOOK=0x...   # o endereço que saiu do deploy
cast call $HOOK "name()(string)"    --rpc-url $RPC_URL   # → "Quiver"
cast call $HOOK "SUPPLY()(uint256)" --rpc-url $RPC_URL   # → 4663000000000000000000
cast call $HOOK "seeded()(bool)"    --rpc-url $RPC_URL   # → false
```

### 3.4 Verificar o código-fonte no Blockscout (transparência antes do 1º trade)

```bash
forge verify-contract $HOOK src/QuiverHook.sol:QuiverHook \
  --verifier blockscout \
  --verifier-url https://robinhoodchain.blockscout.com/api \
  --constructor-args $(cast abi-encode "constructor(address,address,address,address)" \
      $POOL_MANAGER $HOOK_OWNER $POSITION_MANAGER $PERMIT2)

# e o mirror (constructor recebe só o hook):
forge verify-contract <MIRROR> src/QuiverMirror.sol:QuiverMirror \
  --verifier blockscout \
  --verifier-url https://robinhoodchain.blockscout.com/api \
  --constructor-args $(cast abi-encode "constructor(address)" $HOOK)
```

✅ **Critério:** ambos aparecem como "Verified" no Blockscout.

---

## Parte 4 — Seed: o lançamento (1 transação, irreversível)

⚠️ Confira `TICK_LOWER`/`TICK_UPPER` no `.env` **duas vezes**. Depois desta transação: pool
criada, 100% do supply depositado, ownership renunciada. Não existe desfazer.

```bash
source .env   # agora com HOOK preenchido
forge script script/Seed.s.sol:SeedQuiver \
  --rpc-url $RPC_URL --broadcast --private-key $PK
```

**Conferir:**

```bash
cast call $HOOK "seeded()(bool)"    --rpc-url $RPC_URL  # → true
cast call $HOOK "owner()(address)"  --rpc-url $RPC_URL  # → 0x0000...0000
```

**O Quiver está no ar.** Anote o hash da tx de seed e o tokenId da posição (saída do script)
em [DEPLOYMENTS.md](DEPLOYMENTS.md).

### 4.1 Compra de fumaça (prova de vida)

Compre uma fração pequena via interface do Uniswap na Robinhood Chain (ou via `cast` se
preferir) e confirme no Blockscout que o `Transfer` do Arrow aparece no endereço do mirror
quando alguém cruza 1,0 QUIVER inteiro.

---

## Parte 5 — Publicar o site (~20 min)

### 5.1 Build com os endereços reais

```bash
cd ../web
npm install
VITE_HOOK_ADDRESS=$HOOK \
VITE_MIRROR_ADDRESS=<MIRROR> \
npm run build
```

O `dist/` gerado é 100% estático (caminhos relativos) — funciona em qualquer host.

### 5.2 Publicar (escolha a opção da Parte 0)

**Opção A — Cloudflare Pages / Vercel / Netlify (mais simples):**
- Conecte o repositório, aponte o build para `web/`, comando `npm run build`, saída `dist/`.
- Configure as env vars `VITE_HOOK_ADDRESS` e `VITE_MIRROR_ADDRESS` no painel do host.

**Opção B — GitHub Pages:** publique o conteúdo de `web/dist/` no branch `gh-pages`.

**Opção C — IPFS + ENS (estilo Prism):**
```bash
# com pinning no Pinata/web3.storage, ou ipfs local:
ipfs add -r web/dist    # → anote o CID final
```
- No app do ENS, aponte o Content Hash do seu nome para `ipfs://<CID>`.
- O site fica acessível em `https://<nome>.eth.limo`.

### 5.3 Smoke test do site no ar

- [ ] Hero mostra contadores reais (arrows vivos > 0 após a compra de fumaça)
- [ ] "Connect" adiciona/troca para a Robinhood Chain (4663) na carteira
- [ ] "My Quiver" lista o Arrow comprado **com a arte renderizada**
- [ ] Links do Blockscout nos contratos funcionam
- [ ] Botão "Buy QUIVER" abre o Uniswap com o token pré-selecionado

---

## Parte 6 — Pós-lançamento (primeiras 48h)

- [ ] `pokeFees()` + `claim()` de teste: gere um pouco de volume e confirme que fees fluem
      (`cast send $HOOK "pokeFees()" ...` e depois `claim` de um Arrow seu)
- [ ] Logo/metadata do token no Blockscout (formulário do próprio explorer)
- [ ] Tornar o repositório público — código legível é parte do marketing, como no Prism
- [ ] Thread de lançamento no X: a mecânica em 1 frase, prova do fair launch (link da tx de
      seed + owner = 0x0), link do site e do pool
- [ ] DEX Screener indexa sozinho; CoinGecko/CMC depois de tração
- [ ] (Opcional) cron/keeper chamando `pokeFees()` a cada poucas horas

---

## Problemas comuns

| Sintoma | Causa provável | Solução |
| --- | --- | --- |
| `preflight.sh` falha em codesize | Endereço errado ou RPC de outra chain | Confira RPC e endereços em DEPLOYMENTS.md |
| Deploy reverte com `HookAddressNotValid` | Mineração CREATE2 não bateu | Rode de novo (o miner procura outro salt); confira que usou o script (não deploy manual) |
| `seed()` reverte com `spacing` | Ticks não múltiplos de 200 | Ajuste TICK_LOWER/TICK_UPPER |
| Site conecta mas não mostra Arrows | `VITE_HOOK_ADDRESS` ausente no build | Rebuild com as env vars corretas |
| Compra não minta Arrow | Comprou menos de 1,0 QUIVER inteiro | Comportamento esperado — NFT só para unidades inteiras |

## Referências

- [LANCAMENTO.md](LANCAMENTO.md) — runbook com critérios de saída por etapa
- [DEPLOYMENTS.md](DEPLOYMENTS.md) — endereços (infra v4 + os do Quiver quando deployados)
- [contracts/README.md](../contracts/README.md) e [web/README.md](../web/README.md)
