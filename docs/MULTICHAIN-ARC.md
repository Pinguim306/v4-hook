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
1. `./preflight-arc.sh` (na sua máquina) — valida RPC, chain id, cancun,
   escala de decimais do nativo, Permit2/CREATE2 proxy.
2. Faucet de USDC de teste na wallet de deploy.
3. Deploy do stack v4 (PoolManager → Permit2 se faltar → WUSDC → POSM).
4. Recomputar launch config (sqrtPrice/liquidity/creationFee) para nativo 6-dec.
5. Deploy CoilLaunchpad + CoilSwapRouter + (opcional) burner/treasury.
6. Launch de um token de teste ponta a ponta; registrar tudo em DEPLOYMENTS.md.
7. Verificação no Blockscout da Arc (`verify-tokens.sh` com
   `VERIFIER_URL=https://testnet.arcscan.app/api`).

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
