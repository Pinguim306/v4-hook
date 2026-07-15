import {useCallback, useEffect, useRef, useState} from "react";
import {formatEther} from "viem";
import {publicClient, hookAbi} from "./chain";
import {HOOK_ADDRESS, isLaunched} from "./config";

const hook = {address: HOOK_ADDRESS as `0x${string}`, abi: hookAbi} as const;

/** How many arrows get their art + per-arrow fees rendered (reads are 2 calls per arrow). */
export const ARROW_RENDER_CAP = 60;

export type PoolStats = {
  liveArrows: number | null;
  seeded: boolean | null;
  loading: boolean;
  error: string | null;
};

export function usePoolStats(refreshMs = 15000): PoolStats {
  const [stats, setStats] = useState<PoolStats>({
    liveArrows: null,
    seeded: null,
    loading: isLaunched,
    error: null,
  });

  const load = useCallback(async () => {
    if (!isLaunched) return;
    try {
      const [shares, seeded] = await Promise.all([
        publicClient.readContract({...hook, functionName: "totalShares"}),
        publicClient.readContract({...hook, functionName: "seeded"}),
      ]);
      setStats({liveArrows: Number(shares), seeded: Boolean(seeded), loading: false, error: null});
    } catch {
      // Keep any previously loaded numbers; surface that the feed is down.
      setStats((s) => ({...s, loading: false, error: "RPC unreachable — retrying"}));
    }
  }, []);

  useEffect(() => {
    load();
    if (!isLaunched) return;
    const t = setInterval(load, refreshMs);
    return () => clearInterval(t);
  }, [load, refreshMs]);

  return stats;
}

export type Arrow = {
  id: bigint;
  image: string | null;
  owedEth: string;
  owedQuiver: string;
};

export type Holdings = {
  balance: string;
  /** True total arrow count (nftBalanceOf) — may exceed arrows.length (render cap). */
  arrowCount: number;
  /** Every owned id — used for claimMany so claims are never capped. */
  allIds: bigint[];
  /** Detailed (art + fees) view of the first ARROW_RENDER_CAP arrows. */
  arrows: Arrow[];
  pendingEth: string;
  pendingQuiver: string;
  loading: boolean;
  error: string | null;
};

const EMPTY: Holdings = {
  balance: "0",
  arrowCount: 0,
  allIds: [],
  arrows: [],
  pendingEth: "0",
  pendingQuiver: "0",
  loading: false,
  error: null,
};

function decodeImage(tokenUri: string): string | null {
  try {
    const jsonB64 = tokenUri.split("base64,")[1];
    const json = JSON.parse(atob(jsonB64));
    return typeof json.image === "string" ? json.image : null;
  } catch {
    return null;
  }
}

export function useHoldings(account: `0x${string}` | null) {
  const [data, setData] = useState<Holdings>(EMPTY);
  // Monotonic sequence guards against a slow in-flight load for a previous account
  // overwriting the state of the current one.
  const seq = useRef(0);

  const load = useCallback(async () => {
    const mySeq = ++seq.current;
    if (!isLaunched || !account) {
      setData(EMPTY);
      return;
    }
    setData((d) => ({...d, loading: true, error: null}));
    try {
      const [balance, nftCount, ids, pendEth, pendQuiver] = await Promise.all([
        publicClient.readContract({...hook, functionName: "balanceOf", args: [account]}),
        publicClient.readContract({...hook, functionName: "nftBalanceOf", args: [account]}),
        publicClient.readContract({...hook, functionName: "ownedTokensOf", args: [account]}),
        publicClient.readContract({...hook, functionName: "pendingETH", args: [account]}),
        publicClient.readContract({...hook, functionName: "pendingQUIVER", args: [account]}),
      ]);
      const allIds = [...(ids as readonly bigint[])];
      const arrows = (
        await Promise.all(
          allIds.slice(0, ARROW_RENDER_CAP).map(async (id): Promise<Arrow | null> => {
            // Per-arrow reads are individually fault-tolerant: one reverted call
            // (e.g. the arrow burned mid-load) must not blank the whole panel.
            try {
              const [uri, fees] = await Promise.all([
                publicClient.readContract({...hook, functionName: "nftTokenURI", args: [id]}),
                publicClient.readContract({...hook, functionName: "pendingFees", args: [id]}),
              ]);
              const [owedEth, owedQuiver] = fees as [bigint, bigint];
              return {
                id,
                image: decodeImage(uri as string),
                owedEth: formatEther(owedEth),
                owedQuiver: formatEther(owedQuiver),
              };
            } catch {
              return null;
            }
          })
        )
      ).filter((a): a is Arrow => a !== null);

      if (seq.current !== mySeq) return; // a newer load superseded this one
      setData({
        balance: formatEther(balance as bigint),
        arrowCount: Number(nftCount),
        allIds,
        arrows,
        pendingEth: formatEther(pendEth as bigint),
        pendingQuiver: formatEther(pendQuiver as bigint),
        loading: false,
        error: null,
      });
    } catch {
      if (seq.current !== mySeq) return;
      setData((d) => ({...d, loading: false, error: "Could not load holdings — RPC unreachable. Retry shortly."}));
    }
  }, [account]);

  useEffect(() => {
    load();
  }, [load]);

  return {...data, reload: load};
}
