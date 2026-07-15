# Runbook de lançamento — Quiver

Passo a passo executável para colocar o Quiver de pé na Robinhood Chain. Cada etapa tem um
critério de saída; não avance com uma etapa vermelha.

## Pré-requisitos

- Foundry instalado (`forge`, `cast`) e acesso de rede à chain.
- Uma carteira de deploy com ETH na Robinhood Chain (gás é sub-centavo; ~0,01 ETH sobra para
  deploy + seed com folga).
- Repositório clonado, dependências instaladas:

```bash
cd contracts
./bootstrap.sh
forge build && forge test -vv        # unit + e2e local devem passar
```

## Etapa 0 — Pré-flight: validar a infraestrutura v4 (5 min)

Valida on-chain que os três endereços registrados em [DEPLOYMENTS.md](DEPLOYMENTS.md) têm código
e respondem às funções exatas de que `seed()`/`pokeFees()` dependem:

```bash
cd contracts
./preflight.sh
```

**Saída esperada:** `7 passed, 0 failed`. Qualquer ✘ = parar e investigar o endereço no
Blockscout antes de continuar.

## Etapa 1 — Fork test: ciclo de vida completo contra a chain real (10 min)

O validador definitivo. Executa deploy → seed → compra → acúmulo de fees → claim contra o
PoolManager/PositionManager/Permit2 **reais** (em fork local — nada é gasto):

```bash
forge test --match-contract QuiverForkTest \
  --fork-url https://rpc.mainnet.chain.robinhood.com -vv
```

**Saída esperada:** `test_Fork_FullLifecycle` PASS. Isso prova que as interfaces da infra da
chain batem com o que os contratos chamam. Se falhar aqui, o lançamento falharia — investigar
antes de gastar qualquer gás.

## Etapa 2 — Dry-run na testnet (opcional, recomendado)

Mesmo fluxo das etapas 3–5, apontando `RPC_URL` para a testnet da Robinhood Chain e usando os
endereços do v4 de lá (passar via env: `POOL_MANAGER=... POSITION_MANAGER=... PERMIT2=...`).
Serve para ensaiar o procedimento inteiro de ponta a ponta, incluindo o site.

## Etapa 3 — Deploy do hook (mainnet)

```bash
cd contracts
cp .env.example .env      # preencher HOOK_OWNER e PK; nunca commitar o .env
source .env

forge script script/Deploy.s.sol:DeployQuiver \
  --rpc-url $RPC_URL --broadcast --private-key $PK
```

O script minera um salt CREATE2 cujo endereço codifica a flag `AFTER_SWAP` e faz o deploy por
ele. **Anotar da saída:**

- `QuiverHook deployed:` → endereço do hook (o token QUIVER)
- `QuiverMirror (ERC721):` → endereço do mirror (coleção Arrow)

**Verificações imediatas (antes do seed):**

```bash
cast call $HOOK "name()(string)"   --rpc-url $RPC_URL   # → "Quiver"
cast call $HOOK "SUPPLY()(uint256)" --rpc-url $RPC_URL  # → 4663000000000000000000
cast call $HOOK "seeded()(bool)"   --rpc-url $RPC_URL   # → false
```

Verificar o código-fonte no Blockscout (verificação de contrato) **agora**, enquanto o pool
ainda não existe — transparência antes do primeiro trade.

## Etapa 4 — Seed: o lançamento propriamente dito

⚠️ **Irreversível.** O `seed()` inicializa o pool, deposita **100% do supply** como liquidez
unilateral e **renuncia a ownership** na mesma transação. Depois disso não há mais nenhum
controle privilegiado. Conferir `TICK_LOWER`/`TICK_UPPER` duas vezes.

Sobre o preço inicial: o lançamento acontece no tick superior. Com `currency0 = ETH` e
`currency1 = QUIVER`, o preço de 1 QUIVER em ETH é **`1,0001^(−TICK_UPPER)`** — tick maior =
lançamento mais barato. `TICK_LOWER` define o teto de valorização (preço quando todo o supply
tiver sido vendido): `1,0001^(−TICK_LOWER)`. Ambos múltiplos de 200. Tabela pronta de
preço↔tick no [GUIA-OPERADOR.md](GUIA-OPERADOR.md). Exemplo abaixo: lançamento a ≈0,001 ETH
por QUIVER (FDV ≈ 4,7 ETH), sem teto prático.

```bash
export HOOK=0x...        # do passo anterior
export TICK_LOWER=-887200
export TICK_UPPER=69000

forge script script/Seed.s.sol:SeedQuiver \
  --rpc-url $RPC_URL --broadcast --private-key $PK
```

**Verificações pós-seed:**

```bash
cast call $HOOK "seeded()(bool)" --rpc-url $RPC_URL   # → true
cast call $HOOK "owner()(address)" --rpc-url $RPC_URL # → 0x0000...0000 (renunciado)
```

Registrar em [DEPLOYMENTS.md](DEPLOYMENTS.md): endereços do hook e do mirror, tokenId da
posição no POSM, hash da tx de seed.

## Etapa 5 — Publicar o site

```bash
cd web
VITE_HOOK_ADDRESS=0x...   \
VITE_MIRROR_ADDRESS=0x... \
npm run build
```

O `dist/` é 100% estático com caminhos relativos — publicar em qualquer combinação de:

- **IPFS** (`ipfs add -r dist/`) + ENS/`eth.limo`, no espírito do Prism;
- Hosting convencional (Cloudflare Pages, Vercel, GitHub Pages).

Smoke test pós-publicação: contadores do hero mostram arrows vivos; conectar carteira na chain
4663 funciona; um Arrow comprado aparece em "My Quiver" com a arte renderizada.

## Etapa 6 — Pós-lançamento (primeiras 48h)

- [ ] Compra de teste pequena: confirmar que o swap minta o Arrow e o Blockscout indexa o
      `Transfer` do mirror.
- [ ] `pokeFees()` + `claim()` de teste: fees fluem.
- [ ] Submeter logo/metadata do token no Blockscout.
- [ ] Publicar o repositório (código legível é parte do marketing, como no Prism).
- [ ] Conta do projeto no X + thread de lançamento: a mecânica em uma frase, prova do fair
      launch (tx do seed, ownership renunciada), link do site e do pool.
- [ ] DEX Screener indexa sozinho; CoinGecko/CMC após tração.
- [ ] (Opcional) keeper/cron chamando `pokeFees()` periodicamente para suavizar o custo de gás
      do primeiro comprador após períodos parados.

## Rollback

Não existe rollback após a Etapa 4 — por design (imutabilidade é o pitch). Antes dela, nada é
irreversível: um deploy com parâmetro errado na Etapa 3 custa centavos; basta re-deployar e
descartar o endereço antigo (que nunca foi seedado nem divulgado).
