# Coil v4 — plano de migração + modelo de lucro

Documento de design. Dois entregáveis nesta pasta:

1. **Modelo de lucro dos tokens v4** — como o protocolo (você) ganha em cima do volume.
2. **Migração v3 → v4** — o que o hook do Quiver já resolve, o que muda em cada contrato.
3. **Aba de swap com interface fee** — o funil que agrega receita sem virar app separado.

O objetivo declarado: **lucrar em cima de cada token lançado e do volume dele**, por taxa
de transação ou outro mecanismo — de forma limpa, automática e compatível com todos os routers.

---

## 1. Modelo de lucro — a virada do v3 para o v4

### Como o Coil v3 lucra hoje

| Fonte | Quando | Limitação |
| --- | --- | --- |
| `creationFee` (nativo fixo) | 1× por lançamento | ok, mas é só no launch |
| `devFeeBps` na bonding curve | só na fase de curva | acaba na graduação |
| Split do harvest (FeeLocker) | pós-grad, **manual** (botão) | precisa alguém chamar `collect()` |
| `postGradTaxBps` (fee-on-transfer) | pós-grad, em cada trade DEX | **quebra em muitos routers/agregadores**, é bloqueado e mal visto |

O ponto fraco: para capturar receita **por volume** depois da graduação, o v3 depende do
harvest manual + um imposto de transferência (`postGradTaxBps`) que é frágil e antipático.

### Como o Coil v4 lucra — taxa nativa por swap

No Uniswap v4 o **hook cobra a taxa dentro da contabilidade do swap** (não como
fee-on-transfer). Com a flag `beforeSwapReturnDelta`, o hook desvia uma fatia de **todo swap**
— compra e venda — e manda pra onde você quiser. Vantagens:

- **Limpo:** não é imposto de transferência. Funciona com Uniswap, 1inch, agregadores, bots.
- **Automático:** sem botão de harvest. A taxa sai a cada trade.
- **Para sempre:** em cada swap do pool, não só na fase de curva.
- **Configurável na hora do launch e imutável depois** (igual ao Quiver renunciar ownership).

### A "cascata de taxas" (fee waterfall) — sugestão

Mantém o custo total pro trader competitivo (~1%) e divide na origem, on-chain:

```
Swap de 1000  →  taxa total 1% (10)  → dividida no próprio hook:
    ├─ 0,50%  PROTOCOLO  → sua carteira (feeRecipient)          ← seu lucro por volume
    ├─ 0,30%  HOLDERS    → dividendos, via acumulador (estilo Quiver, automático)
    └─ 0,20%  BUY&BURN   → recompra e queima do token da plataforma (COIL)
```

Os três valores são parâmetros por token (`protocolFeeBps`, `holderFeeBps`, `burnFeeBps`),
escolhidos no launch. Modos:

- **Loop Rewards:** holderFee vai pra todos os holders (o loop clássico).
- **Creator Rewards:** holderFee vai pro criador do token (você já tem esse modo no v3).
- **Protocol-max:** holderFee = 0, tudo pro protocolo (para os tokens *do próprio Coil*).

### As camadas de receita (todas somam pra você)

1. **`creationFee`** — nativo, por lançamento (mantém do v3).
2. **`protocolFeeBps`** — **fatia de todo swap, de todo token, pra sempre** ← o principal.
3. **Buy&burn do token da plataforma (COIL)** — parte das taxas recompra e queima COIL;
   se você segura COIL, o volume de *todos* os tokens vira valorização do *seu* token.
4. **Interface fee** — a aba de swap (item 3) cobra 0,15–0,25% em qualquer token roteado.
5. **Taxa de "features"** — limit-order, launch destacado/trending pago, etc.

### Economia de exemplo (só pra intuição)

Com `protocolFeeBps = 0,5%`:

| Volume agregado/dia (todos os tokens) | Sua receita de protocolo/dia |
| --- | --- |
| US$ 100 mil | US$ 500 |
| US$ 1 milhão | US$ 5 mil |
| US$ 10 milhões | US$ 50 mil |

E isso **sem** contar creationFee, interface fee e a valorização do COIL via buy&burn. É o
mesmo motor da pump.fun (fee por volume × muitos tokens), só que nativo no v4.

---

## 2. Migração v3 → v4 — o que muda contrato a contrato

O hook do Quiver **já resolve metade do trabalho**. Mapeamento:

| Peça do Coil v3 | O que o hook do Quiver já faz | Ação no v4 |
| --- | --- | --- |
| `FeeLocker` (trava a posição V3, harvest manual) | O hook **É** o dono da posição e trava a liquidez no `seed()` | **Elimina o FeeLocker.** Liquidez travada no hook, un-ruggable por construção |
| Harvest manual (`collect()` + botão) | O acumulador estilo MasterChef distribui fees **sem botão** | **Elimina o harvest.** Dividendos automáticos por swap |
| Dividendos do `OuroToken` | `accFeesPerShare` + `claim()` já implementados | Reusa o padrão do Quiver |
| `postGradTaxBps` (fee-on-transfer) | — | **Substitui** por taxa nativa no `beforeSwap` (limpa) |
| Graduação bonding curve → V3 | Quiver já faz `seed()` = init pool + deposita liquidez | Curve gradua criando o pool v4 com o hook já anexado |

### Novo contrato: `CoilHook` (por token lançado)

Adapta o `QuiverHook`, com estas mudanças-chave:

- **Permissões do hook:** habilita `beforeSwap` + `beforeSwapReturnDelta` (pra desviar a taxa)
  em vez de só `afterSwap`. Isso muda os bits do endereço → a mineração CREATE2 do
  `Deploy.s.sol` do Quiver já sabe fazer isso (é trocar a flag).
- **`_beforeSwap`:** calcula `feeTotal = amountIn * totalFeeBps / 1e6`, e reparte:
  `protocol` (transfere pro `feeRecipient`), `holders` (soma no `accFeesPerShare`),
  `burn` (acumula pra buy&burn). Retorna o `BeforeSwapDelta` que "cobra" essa fatia.
- **Sem NFT de "arrow":** o token do Coil é um ERC-20 comum (não precisa do mirror/NFT
  do Quiver, a não ser que você queira a camada colecionável). Simplifica.
- **Config imutável por token:** `protocolFeeBps`, `holderFeeBps`, `burnFeeBps`, `rewardsMode`,
  fixados no construtor. `feeRecipient` lido ao vivo do Launchpad (como o v3 faz no FeeLocker).

### `Launchpad.sol` (mudanças)

- No `graduate`/`launch`, em vez de mintar posição V3 + `FeeLocker`, faz o `seed()` do
  `CoilHook` (init do pool v4 + liquidez travada no hook).
- Mineração do endereço do hook (CREATE2) na criação do token — reusa o `HookMiner` do Quiver.
- Mantém `creationFee` e `feeRecipient` iguais.
- Novos parâmetros de launch: os três `*FeeBps` da cascata.

### `OuroToken.sol` (mudanças)

- Vira um ERC-20 simples (a lógica de dividendo migra pro hook, que é onde o v4 quer ela).
- Remove `postGradTaxBps` (substituído pela taxa nativa do hook).

### `BondingCurve.sol`

- Praticamente igual. Só muda o "destino" da graduação: cria o pool v4 com o hook.

### O que **não** muda

- Front-end (Discover, token page, Points, leaderboard, API de bots) — continua igual, só
  aponta pros novos contratos e lê os novos campos de fee.
- Filosofia un-ruggable: liquidez travada continua garantida (agora no hook).

---

## 3. Aba de swap com interface fee (o funil, dentro do Coil)

Não é app separado — é uma **aba "Swap / Trade any token"** no site do Coil que:

- Troca **qualquer** token da Robinhood Chain (não só lançamentos Coil), roteando pelo
  melhor preço (Uniswap v4 + outros DEXs da chain).
- Cobra **interface fee** de 0,15–0,25% em cada swap → sua carteira. (É o mesmo modelo do
  front-end da Uniswap, que fatura dezenas de milhões só com isso.)
- Coloca os **tokens Coil em destaque** (trending) — o swap vira o topo de funil que
  empurra gente pros seus lançamentos.

Tecnicamente é a parte mais simples (é front-end + um contrato fino de "swap router com fee"
que embrulha o router da chain e desvia a interface fee). Reusa o stack Next.js/wagmi que o
Coil já tem.

---

## 4. Plano de entrega (estilo Quiver — validado a cada passo)

**Fase A — `CoilHook` (o núcleo do lucro).**
- Adaptar o `QuiverHook` → hook com taxa nativa no `beforeSwap` + cascata protocol/holders/burn.
- Testes unitários (mock v4) da cascata: cada swap reparte certo, dividendos acumulam, buy&burn
  acumula, protocolo recebe.
- **Fork test** contra a Robinhood Chain real: launch → swaps → protocolo recebe fee → holder
  dá claim → buy&burn executa. (Igual fizemos no Quiver — prova antes de gastar.)

**Fase B — Launchpad v4.**
- `Launchpad.sol` grava o `CoilHook` no lugar do FeeLocker; mineração CREATE2 do endereço.
- Testes de integração: criar token → graduar → pool v4 vivo com o hook cobrando.

**Fase C — Front-end.**
- Token page lê os novos campos de fee; remove o botão de harvest (agora automático).
- Nova aba **Swap** com interface fee.

**Fase D — Migração/coexistência.**
- Tokens v3 antigos continuam funcionando (FeeLocker + harvest). Novos saem em v4.
- `LAUNCHPAD_VERSION` sobe pra 3; o site detecta e mostra a UI certa por token (você já tem
  esse padrão de versão no v3).

---

## Resumo do porquê isso responde ao requisito de lucro

- **Lucro por token lançado:** `creationFee` (no launch) + o token entra na sua máquina de fee.
- **Lucro por volume:** `protocolFeeBps` desvia uma fatia de **todo swap, de todo token, pra
  sempre**, nativo e limpo (sem fee-on-transfer, sem harvest manual).
- **Lucro composto:** buy&burn do COIL transforma o volume de *todos* os tokens em valorização
  do *seu* token; a aba de swap cobra interface fee em qualquer trade da chain.
- **Vantagem de execução:** você já tem o hook (Quiver), o launchpad (Coil) e o front-end.
  O v4 só **funde os dois** e troca o mecanismo frágil (harvest + tax) pelo nativo (fee no swap).
