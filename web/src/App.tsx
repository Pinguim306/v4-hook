import {useEffect, useState} from "react";
import {ArrowMark} from "./ArrowMark";
import {usePoolStats, useHoldings, ARROW_RENDER_CAP} from "./useQuiver";
import {connect, currentAccount, onWalletEvents, walletClient} from "./wallet";
import {hookAbi, publicClient} from "./chain";
import {
  HOOK_ADDRESS,
  MIRROR_ADDRESS,
  ROBINHOOD_CHAIN,
  SUPPLY,
  TOKEN_SYMBOL,
  UNISWAP_SWAP_URL,
  isLaunched,
} from "./config";

const short = (a: string) => (a.length > 12 ? `${a.slice(0, 6)}…${a.slice(-4)}` : a);
const explorer = ROBINHOOD_CHAIN.blockExplorers.default.url;

export function App() {
  const [account, setAccount] = useState<`0x${string}` | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const stats = usePoolStats();

  useEffect(() => {
    currentAccount().then(setAccount).catch(() => {});
    // Track wallet-side changes: switching accounts updates the panel; leaving the
    // chain is surfaced on the next action (writes re-assert the chain).
    return onWalletEvents({
      onAccountsChanged: (acc) => setAccount(acc),
    });
  }, []);

  const onConnect = async () => {
    setErr(null);
    try {
      setAccount(await connect());
    } catch (e) {
      setErr((e as Error).message);
    }
  };

  return (
    <div className="wrap">
      <nav className="nav">
        <a className="brand" href="#top">
          <ArrowMark /> QUIVER
        </a>
        <div className="nav-links">
          <a href="#how">Mechanics</a>
          <a href="#mine">My Quiver</a>
          <a href="#docs">Docs</a>
          <a href="#faq">FAQ</a>
          <button className="btn" onClick={onConnect}>
            {account ? short(account) : "Connect"}
          </button>
        </div>
      </nav>

      <header className="hero" id="top">
        <div className="eyebrow">one v4 pool · {SUPPLY} arrows · robinhood chain</div>
        <h1>
          Holding is <span className="tag">providing liquidity.</span>
        </h1>
        <p className="lede">
          Quiver is the first Robinhood Chain token where every whole {TOKEN_SYMBOL} you hold is one
          Arrow — a 1/{SUPPLY} share of the same Uniswap v4 liquidity position. Swap fees accrue to
          your arrows pro-rata. No staking, no wrapper, no router approval. Just hold.
        </p>
        <div className="hero-cta">
          <a className="btn btn-accent" href={UNISWAP_SWAP_URL} target="_blank" rel="noreferrer">
            Buy {TOKEN_SYMBOL} ↗
          </a>
          <a className="btn" href="#how">
            How it works
          </a>
        </div>
        {err && <p className="notice" style={{marginTop: 20}}>{err}</p>}
      </header>

      <div className="stats">
        <div className="stat">
          <div className="k">Supply ceiling</div>
          <div className="v accent">{SUPPLY}</div>
        </div>
        <div className="stat">
          <div className="k">Live arrows</div>
          <div className="v">{stats.liveArrows ?? (isLaunched ? (stats.error ? "—" : "…") : "—")}</div>
        </div>
        <div className="stat">
          <div className="k">Pool fee</div>
          <div className="v">1%</div>
        </div>
        <div className="stat">
          <div className="k">Status</div>
          <div className="v">
            {!isLaunched
              ? "Pre-launch"
              : stats.error && stats.seeded === null
                ? "RPC offline"
                : stats.seeded
                  ? "Live"
                  : "Deployed"}
          </div>
        </div>
      </div>

      <section id="how">
        <div className="sec-head">
          <span className="idx">01</span>
          <h2>How it works</h2>
        </div>
        <div className="steps">
          <div className="step">
            <div className="n">→ BUY</div>
            <h3>Acquire whole tokens</h3>
            <p>
              Buy {TOKEN_SYMBOL} on the Uniswap v4 pool. The pool is the token — one singleton hook
              is the ERC-20, the LP, and the fee router at once.
            </p>
          </div>
          <div className="step">
            <div className="n">◆ MINT</div>
            <h3>Each whole token mints an Arrow</h3>
            <p>
              Every 1.0 {TOKEN_SYMBOL} in your wallet auto-mints one Arrow NFT — a 1/{SUPPLY} claim on
              the single v4 position, with art rendered fully on-chain.
            </p>
          </div>
          <div className="step">
            <div className="n">$ EARN</div>
            <h3>Fees accrue to your arrows</h3>
            <p>
              Every swap pays a 1% fee in ETH and {TOKEN_SYMBOL}. It streams pro-rata to live arrows.
              Claim anytime — no staking, no lockup.
            </p>
          </div>
          <div className="step">
            <div className="n">✕ BURN</div>
            <h3>Selling a fraction burns an arrow</h3>
            <p>
              {SUPPLY} is a ceiling, not a floor. Every fractional sell permanently burns the
              underlying arrow — fewer arrows means a bigger fee slice for everyone still holding.
            </p>
          </div>
        </div>
      </section>

      <MyQuiver account={account} onConnect={onConnect} />

      <section id="docs">
        <div className="sec-head">
          <span className="idx">03</span>
          <h2>Docs</h2>
        </div>

        <div className="docs-grid">
          <div className="doc-block">
            <h3>The architecture</h3>
            <p>
              Quiver is a single Uniswap v4 hook that is, at once, the ERC-20 token, the owner of the
              one liquidity position, the fee router, and an ERC-721 ledger. There is no staking
              contract, no LP wrapper, no router to approve — the token <em>is</em> the pool.
            </p>
            <ul className="doc-list">
              <li>
                <b>{TOKEN_SYMBOL} (ERC-20)</b> — the hook itself. Fixed supply of {SUPPLY}, 18 decimals.
              </li>
              <li>
                <b>Arrow (ERC-721)</b> — a mirror contract exposing the NFTs. Every whole {TOKEN_SYMBOL}{" "}
                you hold is one Arrow; the mapping is enforced automatically on every transfer.
              </li>
              <li>
                <b>Art</b> — each Arrow renders a ballistics blueprint as SVG, generated fully on-chain
                from a seed derived from its token id. No IPFS, no server, nothing to go offline.
              </li>
            </ul>
          </div>

          <div className="doc-block">
            <h3>Fees — 1% per swap, 0% to anyone privileged</h3>
            <p>
              Every swap on the pool pays a <b>1% fee</b> (on buys and sells alike). That fee does not
              go to a team, a treasury, or the deployer. It accrues to the single liquidity position
              and is distributed <b>pro-rata to every live Arrow</b>.
            </p>
            <ul className="doc-list">
              <li>No dev tax, no team allocation, no privileged withdrawal — ownership is renounced.</li>
              <li>Fees stream in ETH and {TOKEN_SYMBOL}; claim anytime from “My Quiver”.</li>
              <li>
                The only way anyone earns fees — including the deployer — is by holding {TOKEN_SYMBOL}.
                100% of the supply went into the pool at launch; there is no reserved allocation.
              </li>
            </ul>
          </div>

          <div className="doc-block">
            <h3>The 4663 ceiling</h3>
            <p>
              {SUPPLY} is a ceiling, not a floor. Arrows mint as you accumulate whole tokens and{" "}
              <b>burn permanently</b> when you sell a fraction. Fees already earned by an arrow are
              credited to you as a withdrawable balance the moment it burns — you never lose earned
              fees, only future share. Fewer live arrows means a bigger slice for everyone still
              holding.
            </p>
          </div>

          <div className="doc-block">
            <h3>Pool parameters</h3>
            <ul className="mono-list">
              <li>
                <span>Pair</span>
                <span>ETH (native) / {TOKEN_SYMBOL}</span>
              </li>
              <li>
                <span>Swap fee</span>
                <span>1% (10000 pips)</span>
              </li>
              <li>
                <span>Tick spacing</span>
                <span>200</span>
              </li>
              <li>
                <span>Hook flags</span>
                <span>afterSwap</span>
              </li>
              <li>
                <span>Supply</span>
                <span>{SUPPLY} · 18 decimals</span>
              </li>
              <li>
                <span>Owner</span>
                <span>renounced (0x000…000)</span>
              </li>
            </ul>
          </div>
        </div>

        <p className="muted" style={{marginTop: 18}}>
          Contracts are verified on-chain — read every line on{" "}
          <a href={`${explorer}/address/${HOOK_ADDRESS}`} target="_blank" rel="noreferrer">
            Blockscout
          </a>
          . In the spirit of{" "}
          <a href="https://github.com/0xsolazy/prism" target="_blank" rel="noreferrer">
            Prism
          </a>
          .
        </p>
      </section>

      <section id="faq" className="faq">
        <div className="sec-head">
          <span className="idx">04</span>
          <h2>FAQ</h2>
        </div>
        <details>
          <summary>Is there a buy/sell tax that goes to the dev?</summary>
          <p>
            No. There is a 1% swap fee, but it goes entirely to Arrow holders pro-rata — never to the
            deployer or a treasury. Ownership is renounced, so no privileged fee extraction exists. The
            deployer holds zero {TOKEN_SYMBOL} and earns only by buying and holding like anyone else.
          </p>
        </details>
        <details>
          <summary>Why 4663?</summary>
          <p>
            4663 is the Robinhood Chain id — and “HOOD” on a T9 keypad. The supply is a fixed 4663,
            so there can never be more than 4663 arrows.
          </p>
        </details>
        <details>
          <summary>Is it a fair launch?</summary>
          <p>
            Yes. 100% of the supply is minted to the contract and deposited as one-sided liquidity in
            a single <code>seed()</code> call — no team allocation, no presale, no ETH from the
            deployer. Ownership is renounced in the same transaction, so the contract has no
            privileged control over funds afterward.
          </p>
        </details>
        <details>
          <summary>Do I need to stake or wrap anything?</summary>
          <p>
            No. Holding the token is the entire mechanism. Arrows mint and burn automatically as your
            whole-token balance changes; fees are claimed directly from the hook.
          </p>
        </details>
        <details>
          <summary>What happens to fees on a burned arrow?</summary>
          <p>
            Fees already accrued to an arrow are credited to you as a withdrawable pending balance the
            moment it burns or moves — you never lose earned fees, only future share.
          </p>
        </details>
        <details>
          <summary>Where does the art come from?</summary>
          <p>
            Each Arrow is a ballistics blueprint — launch angle, draw weight, range and fletching hue
            derived deterministically from the token id — rendered as SVG entirely on-chain. No IPFS,
            no server.
          </p>
        </details>
      </section>

      <section id="contracts">
        <div className="sec-head">
          <span className="idx">05</span>
          <h2>Contracts</h2>
        </div>
        <ul className="mono-list">
          <li>
            <span>Chain</span>
            <span>
              {ROBINHOOD_CHAIN.name} · id {ROBINHOOD_CHAIN.id}
            </span>
          </li>
          <li>
            <span>Hook / {TOKEN_SYMBOL} (ERC-20)</span>
            <span>
              {isLaunched ? (
                <a href={`${explorer}/address/${HOOK_ADDRESS}`} target="_blank" rel="noreferrer">
                  {HOOK_ADDRESS}
                </a>
              ) : (
                "to be published at launch"
              )}
            </span>
          </li>
          <li>
            <span>Arrow (ERC-721)</span>
            <span>
              {MIRROR_ADDRESS ? (
                <a href={`${explorer}/address/${MIRROR_ADDRESS}`} target="_blank" rel="noreferrer">
                  {MIRROR_ADDRESS}
                </a>
              ) : (
                "to be published at launch"
              )}
            </span>
          </li>
          <li>
            <span>Explorer</span>
            <span>
              <a href={explorer} target="_blank" rel="noreferrer">
                {explorer.replace("https://", "")}
              </a>
            </span>
          </li>
        </ul>
      </section>

      <footer>
        <div>QUIVER · one v4 pool. {SUPPLY} arrows.</div>
        <div>
          In the spirit of{" "}
          <a href="https://github.com/0xsolazy/prism" target="_blank" rel="noreferrer">
            Prism
          </a>
          . Not financial advice.
        </div>
      </footer>
    </div>
  );
}

function MyQuiver({account, onConnect}: {account: `0x${string}` | null; onConnect: () => void}) {
  const {balance, arrowCount, allIds, arrows, owedEth, owedQuiver, pendingEth, pendingQuiver, loading, error, reload} =
    useHoldings(account);
  const hasOwed = Number(owedEth) > 0 || Number(owedQuiver) > 0;
  const hasPending = Number(pendingEth) > 0 || Number(pendingQuiver) > 0;
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);

  const send = async (fn: "claimMany" | "withdrawPending", ids?: bigint[]) => {
    if (!account) return;
    setBusy(true);
    setMsg(null);
    try {
      const wc = walletClient();
      const hash = await wc.writeContract({
        account,
        chain: undefined,
        address: HOOK_ADDRESS as `0x${string}`,
        abi: hookAbi,
        functionName: fn,
        args: fn === "claimMany" ? [ids ?? []] : [],
      });
      setMsg(`Submitted ${short(hash)} — waiting for confirmation…`);
      try {
        await publicClient.waitForTransactionReceipt({hash, timeout: 60_000});
        setMsg(`Confirmed: ${short(hash)}`);
      } catch {
        setMsg(`Submitted ${short(hash)} — confirmation still pending, refresh in a moment.`);
      }
      reload();
    } catch (e) {
      setMsg((e as Error).message.split("\n")[0]);
    } finally {
      setBusy(false);
    }
  };

  return (
    <section id="mine">
      <div className="sec-head">
        <span className="idx">02</span>
        <h2>My Quiver</h2>
      </div>

      {!isLaunched && (
        <div className="notice">
          Quiver hasn’t launched yet. This panel goes live the moment the pool is seeded on Robinhood
          Chain.
        </div>
      )}

      {!account ? (
        <div className="panel">
          <div className="row">
            <span className="muted">Connect a wallet to see your arrows and claim fees.</span>
            <div className="spacer" />
            <button className="btn btn-accent" onClick={onConnect} disabled={!isLaunched}>
              Connect wallet
            </button>
          </div>
        </div>
      ) : (
        <div className="panel">
          <div className="row">
            <div>
              <div className="muted" style={{fontSize: 12, letterSpacing: "0.1em"}}>
                BALANCE
              </div>
              <div style={{fontSize: 22, fontWeight: 600}}>
                {Number(balance).toLocaleString(undefined, {maximumFractionDigits: 4})} {TOKEN_SYMBOL}
              </div>
            </div>
            <div>
              <div className="muted" style={{fontSize: 12, letterSpacing: "0.1em"}}>
                ARROWS
              </div>
              <div style={{fontSize: 22, fontWeight: 600}}>{arrowCount}</div>
            </div>
            <div>
              <div className="muted" style={{fontSize: 12, letterSpacing: "0.1em"}}>
                CLAIMABLE
              </div>
              <div style={{fontSize: 22, fontWeight: 600}} className={hasOwed ? "accent" : undefined}>
                {Number(owedEth).toFixed(5)} ETH
              </div>
              <div className="muted" style={{fontSize: 12}}>
                + {Number(owedQuiver).toFixed(2)} {TOKEN_SYMBOL}
              </div>
            </div>
            <div className="spacer" />
            <div style={{textAlign: "right"}}>
              {hasPending && (
                <div className="muted" style={{fontSize: 12}}>
                  Pending withdraw: {Number(pendingEth).toFixed(4)} ETH ·{" "}
                  {Number(pendingQuiver).toFixed(2)} {TOKEN_SYMBOL}
                </div>
              )}
              <div className="row" style={{justifyContent: "flex-end", marginTop: 8}}>
                <button
                  className="btn btn-accent"
                  disabled={busy || allIds.length === 0}
                  onClick={() => send("claimMany", allIds)}
                >
                  Claim fees
                </button>
                <button
                  className="btn"
                  disabled={busy || !hasPending}
                  onClick={() => send("withdrawPending")}
                >
                  Withdraw pending
                </button>
              </div>
            </div>
          </div>

          {msg && <p className="notice" style={{marginTop: 16}}>{msg}</p>}
          {error && <p className="notice" style={{marginTop: 16}}>{error}</p>}
          {loading && <p className="muted" style={{marginTop: 16}}>Loading arrows…</p>}

          <div className="arrow-grid">
            {arrows.map((a) => (
              <div className="arrow-card" key={a.id.toString()}>
                {a.image ? <img src={a.image} alt={`Arrow #${a.id}`} /> : <div className="ph" />}
                <div className="meta">
                  <span>#{a.id.toString()}</span>
                  <span className="owed">
                    {Number(a.owedEth) > 0 ? `${Number(a.owedEth).toFixed(4)} ETH` : "—"}
                  </span>
                </div>
              </div>
            ))}
          </div>
          {arrowCount > ARROW_RENDER_CAP && (
            <p className="muted" style={{marginTop: 12}}>
              Showing {Math.min(arrows.length, ARROW_RENDER_CAP)} of {arrowCount} arrows — “Claim all
              fees” always covers every arrow you own.
            </p>
          )}
          {!loading && !error && arrowCount === 0 && (
            <p className="muted" style={{marginTop: 16}}>
              No arrows yet — hold at least one whole {TOKEN_SYMBOL} to mint your first.
            </p>
          )}
        </div>
      )}
    </section>
  );
}
