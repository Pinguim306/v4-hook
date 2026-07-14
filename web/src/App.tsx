import {useEffect, useState} from "react";
import {ArrowMark} from "./ArrowMark";
import {usePoolStats, useHoldings} from "./useQuiver";
import {connect, currentAccount, walletClient} from "./wallet";
import {hookAbi} from "./chain";
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
          <div className="v">{stats.liveArrows ?? (isLaunched ? "…" : "—")}</div>
        </div>
        <div className="stat">
          <div className="k">Pool fee</div>
          <div className="v">1%</div>
        </div>
        <div className="stat">
          <div className="k">Status</div>
          <div className="v">{isLaunched ? (stats.seeded ? "Live" : "Deployed") : "Pre-launch"}</div>
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

      <section id="faq" className="faq">
        <div className="sec-head">
          <span className="idx">03</span>
          <h2>FAQ</h2>
        </div>
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
          <span className="idx">04</span>
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
  const {balance, arrows, pendingEth, pendingQuiver, loading, reload} = useHoldings(account);
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
      setMsg(`Submitted: ${short(hash)}`);
      setTimeout(reload, 4000);
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
              <div style={{fontSize: 22, fontWeight: 600}}>{arrows.length}</div>
            </div>
            <div className="spacer" />
            <div style={{textAlign: "right"}}>
              <div className="muted" style={{fontSize: 12}}>
                Pending: {Number(pendingEth).toFixed(4)} ETH · {Number(pendingQuiver).toFixed(2)}{" "}
                {TOKEN_SYMBOL}
              </div>
              <div className="row" style={{justifyContent: "flex-end", marginTop: 8}}>
                <button
                  className="btn"
                  disabled={busy || arrows.length === 0}
                  onClick={() => send("claimMany", arrows.map((a) => a.id))}
                >
                  Claim all fees
                </button>
                <button
                  className="btn"
                  disabled={busy || (Number(pendingEth) === 0 && Number(pendingQuiver) === 0)}
                  onClick={() => send("withdrawPending")}
                >
                  Withdraw pending
                </button>
              </div>
            </div>
          </div>

          {msg && <p className="notice" style={{marginTop: 16}}>{msg}</p>}
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
          {!loading && arrows.length === 0 && (
            <p className="muted" style={{marginTop: 16}}>
              No arrows yet — hold at least one whole {TOKEN_SYMBOL} to mint your first.
            </p>
          )}
        </div>
      )}
    </section>
  );
}
