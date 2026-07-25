# Coil multi-chain — Arc (Circle)

Plano para levar a launchpad Coil além da Robinhood Chain, começando pela **Arc**
(L1 da Circle para "programmable money"). Status em 2026-07: Arc está em
**testnet público** (mainnet prevista para o verão de 2026).

## O que é a Arc, na prática

| | Robinhood Chain | Arc (testnet) |
| --- | --- | --- |
| Chain ID | `4663` | `5042002` |
| RPC | `rpc.mainnet.chain.robinhood.com` | `rpc.testnet.arc.network` (e Alchemy/QuickNode/dRPC) |
| Explorer | Blockscout (`robinhoodchain.blockscout.com`) | Blockscout (`testnet.arcscan.app`) |
| Gás nativo | ETH (18 dec) | **USDC (6 dec)** |
| EVM | cancun | Reth, EVM-compatível (confirmar cancun no preflight) |
| Uniswap v4 | PoolManager/POSM/Permit2 já deployados | **não existe — nós deployamos** |

As três diferenças que importam:

1. **Gás nativo é USDC.** O CoilHook já trata a moeda nativa como `currency0`
   (address(0)) de forma agnóstica — o mecanismo todo funciona igual, mas tudo
   que era "ETH" vira "USDC": preço de launch, creation fee, fee waterfall,
   dividendos de holders. Preços ficam dólar-denominados (ótimo para UX, aliás).
2. **6 decimais, não 18.** `launchSqrtPriceX96`/`launchLiquidity` da launchpad
   são pré-computados para um par (supply 18-dec, nativo 18-dec) — na Arc é
   preciso recomputar para nativo 6-dec (a razão de preço muda 1e12x no raw).
   `creationFee` idem. No frontend, todo `formatEther` do lado nativo vira
   `formatUnits(x, 6)`. O preflight prova empiricamente a escala (ver abaixo).
3. **Não há stack v4 na Arc.** Deployamos nós mesmos com os scripts do
   upstream que já estão em `lib/`:
   - `lib/v4-periphery/script/01_PoolManager.s.sol` → PoolManager;
   - Permit2: se não existir, deploy keyless no endereço canônico
     (`0x…22D473…8BA3`) via o deterministic-deployment-proxy;
   - wrapped native ("WUSDC", estilo WETH9) — necessário pelo POSM;
   - `lib/v4-periphery/script/DeployPosm.s.sol` → PositionDescriptor + POSM
     (args: poolManager, permit2, unsubscribeGasLimit, wrappedNative, label).

   ⚠️ **Licença**: v4-core é BUSL-1.1. Uso em **testnet é livre** (non-production);
   deploy em **mainnet** antes da Change Date (jun/2027) formalmente requer o
   Additional Use Grant da governança Uniswap. Reavaliar quando a Arc mainnet
   sair — a Uniswap pode inclusive deployar oficialmente lá.

## O que NÃO muda

- `CoilHook`/`CoilLaunchpad`/`CoilSwapRouter`: código idêntico, um deploy por
  chain (todos os endereços de infra entram por constructor).
- Verificação: Arc usa Blockscout — `verify-tokens.sh` já é parametrizado
  (`RPC`, `LAUNCHPAD`, `VERIFIER_URL`); basta rodá-lo uma vez por chain e o
  cron do GitHub Actions vira um matrix de chains.
- Flags do hook (`0x2088` pós-correções H-01): iguais em qualquer chain.

## Decisão de design: o burn de $COIL nas outras chains

$COIL vive na Robinhood Chain. Na Arc, a fatia de burn (bps `burn`) acumula em
USDC no `platformTreasury` da Arc. Opções:

- **v1 (recomendada)**: treasury da Arc é uma wallet ops; periodicamente o USDC
  é trazido para a Robinhood Chain (CCTP da própria Circle até uma chain
  suportada + bridge), compra $COIL e manda para `0x…dEaD`. Manual/keeper,
  transparente on-chain dos dois lados.
- v2 (futuro): burner cross-chain automatizado via CCTP + mensagem.

## Fases

**Fase 1 — piloto no Arc testnet (contracts, este repo)**

Preflight já executado (2026-07-17): chain id ✔, cancun ✔, **Permit2 já está no
endereço canônico** ✔; PoolManager/POSM/wrapped-native não existem → deploy nosso.

1. Faucet de USDC de teste na wallet de deploy e **provar a escala do nativo**:
   `cast balance $WALLET --rpc-url https://rpc.testnet.arc.network`
   (1 USDC do faucet → `1000000` = 6-dec; `1e18` = escala 18-dec).
2. Deploy do stack v4 (`script/arc/DeployArcV4Stack.s.sol` — PoolManager +
   WrappedNative "WUSDC" + PositionDescriptor + POSM; Permit2 reaproveitado):
   ```bash
   POOL_MANAGER_OWNER=<sua wallet> NATIVE_DECIMALS=6 \
   FOUNDRY_PROFILE=e2e forge script script/arc/DeployArcV4Stack.s.sol:DeployArcV4Stack \
     --rpc-url https://rpc.testnet.arc.network --broadcast --private-key $PK
   ```
3. Escolher preço de launch em USDC (ticks) — depende da escala provada no
   passo 1; recomputar `TICK_LOWER/TICK_UPPER` para o alvo de market cap.
4. Deploy da CoilLaunchpad apontando para o stack novo:
   ```bash
   POOL_MANAGER=<do passo 2> POSITION_MANAGER=<do passo 2> \
   PERMIT2=0x000000000022D473030F116dDEE9F6B43aC78BA3 \
   LAUNCHPAD_OWNER=<wallet> FEE_RECIPIENT=<wallet> PLATFORM_TREASURY=<treasury Arc> \
   TOKEN_SUPPLY=1000000000000000000000000000 CREATION_FEE=<em unidades nativas> \
   TICK_LOWER=<passo 3> TICK_UPPER=<passo 3> \
   FOUNDRY_PROFILE=e2e forge script script/DeployCoilLaunchpad.s.sol:DeployCoilLaunchpad \
     --rpc-url https://rpc.testnet.arc.network --broadcast --private-key $PK
   ```
5. Deploy do CoilSwapRouter (fonte no repo do site) + launch de um token de
   teste ponta a ponta; registrar tudo em DEPLOYMENTS.md.
6. Verificação no Blockscout da Arc (`verify-tokens.sh` com
   `RPC=https://rpc.testnet.arc.network LAUNCHPAD=<novo> VERIFIER_URL=https://testnet.arcscan.app/api`).

**Fase 2 — frontend multi-chain (repo OuroborosRH)**
- wagmi com N chains; registry por chain (launchpads, router, poolManager,
  explorer, símbolo/decimais do nativo).
- Seletor de rede no create + badge de chain nos tokens; mercados agregados.
- `formatEther` → `formatUnits(chain.nativeDecimals)` em todo lado nativo.
- HookMiner por chain (endereço da launchpad muda o CREATE2).
- Announce/bot/API v1 e Coil Points: decidir agregação por chain vs global.

**Fase 3 — Arc mainnet (quando lançar, ~verão 2026)**
- Reavaliar licença/disponibilidade oficial do v4.
- Repetir Fase 1 na mainnet, ligar na UI.
