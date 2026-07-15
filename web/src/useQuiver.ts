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
  /** Claimable-now totals across the rendered arrows (harvest-simulated). */
  owedEth: string;
  owedQuiver: string;
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
  owedEth: "0",
  owedQuiver: "0",
  pendingEth: "0",
  pendingQuiver: "0",
  loading: false,
  error: null,
};

/**
 * Read each arrow's claimable fees AS IF `pokeFees()` had just run — because the on-chain
 * `pendingFees` view only reflects already-harvested fees. Multicall3 runs `pokeFees()` then
 * the `pendingFees` reads inside ONE eth_call, so the poke's state changes are visible to the
 * reads (no gas, no state written). Returns a map id -> [owedEth, owedQuiver]; empty on any
 * failure (Multicall3 absent, sim revert) so the caller falls back to plain reads.
 */
async function readOwedWithPoke(ids: bigint[]): Promise<Map<string, [bigint, bigint]>> {
  const map = new Map<string, [bigint, bigint]>();
  if (ids.length === 0) return map;
  try {
    // Heterogeneous call list (pokeFees + N pendingFees) — cast past viem's homogeneous-array
    // inference; shapes are correct at runtime.
    const contracts = [
      {...hook, functionName: "pokeFees"},
      ...ids.map((id) => ({...hook, functionName: "pendingFees", args: [id]})),
    ] as unknown as Parameters<typeof publicClient.multicall>[0]["contracts"];
    // batchSize: 0 forces ALL calls into a single aggregate3 eth_call, so pokeFees()'s state
    // changes are visible to the pendingFees() reads that follow it. Splitting would break that.
    const results = await publicClient.multicall({allowFailure: true, batchSize: 0, contracts});
    // results[0] is the pokeFees call; the pendingFees results follow in id order.
    ids.forEach((id, i) => {
      const r = results[i + 1];
      if (r?.status === "success") map.set(id.toString(), r.result as [bigint, bigint]);
    });
  } catch {
    // Multicall3 not available or simulation reverted — leave the map empty.
  }
  return map;
}

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
      const shown = allIds.slice(0, ARROW_RENDER_CAP);

      // Claimable fees as if freshly harvested (see readOwedWithPoke). Falls back per-arrow
      // to the plain (unpoked) pendingFees read if the simulated poke is unavailable.
      const owedMap = await readOwedWithPoke(shown);

      let totalOwedEth = 0n;
      let totalOwedQuiver = 0n;
      const arrows = (
        await Promise.all(
          shown.map(async (id): Promise<Arrow | null> => {
            try {
              const uri = await publicClient.readContract({
                ...hook,
                functionName: "nftTokenURI",
                args: [id],
              });
              let owed = owedMap.get(id.toString());
              if (!owed) {
                owed = (await publicClient.readContract({
                  ...hook,
                  functionName: "pendingFees",
                  args: [id],
                })) as [bigint, bigint];
              }
              const [owedEth, owedQuiver] = owed;
              totalOwedEth += owedEth;
              totalOwedQuiver += owedQuiver;
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
        owedEth: formatEther(totalOwedEth),
        owedQuiver: formatEther(totalOwedQuiver),
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
