import {useCallback, useEffect, useState} from "react";
import {formatEther} from "viem";
import {publicClient, hookAbi} from "./chain";
import {HOOK_ADDRESS, isLaunched} from "./config";

const hook = {address: HOOK_ADDRESS as `0x${string}`, abi: hookAbi} as const;

export type PoolStats = {
  liveArrows: number | null;
  seeded: boolean | null;
  loading: boolean;
};

export function usePoolStats(refreshMs = 15000): PoolStats {
  const [stats, setStats] = useState<PoolStats>({liveArrows: null, seeded: null, loading: isLaunched});

  const load = useCallback(async () => {
    if (!isLaunched) return;
    try {
      const [shares, seeded] = await Promise.all([
        publicClient.readContract({...hook, functionName: "totalShares"}),
        publicClient.readContract({...hook, functionName: "seeded"}),
      ]);
      setStats({liveArrows: Number(shares), seeded: Boolean(seeded), loading: false});
    } catch {
      setStats((s) => ({...s, loading: false}));
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
  arrows: Arrow[];
  pendingEth: string;
  pendingQuiver: string;
  loading: boolean;
};

const EMPTY: Holdings = {balance: "0", arrows: [], pendingEth: "0", pendingQuiver: "0", loading: false};

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

  const load = useCallback(async () => {
    if (!isLaunched || !account) {
      setData(EMPTY);
      return;
    }
    setData((d) => ({...d, loading: true}));
    try {
      const [balance, ids, pendEth, pendQuiver] = await Promise.all([
        publicClient.readContract({...hook, functionName: "balanceOf", args: [account]}),
        publicClient.readContract({...hook, functionName: "ownedTokensOf", args: [account]}),
        publicClient.readContract({...hook, functionName: "pendingETH", args: [account]}),
        publicClient.readContract({...hook, functionName: "pendingQUIVER", args: [account]}),
      ]);
      const idList = ids as readonly bigint[];
      const arrows = await Promise.all(
        idList.slice(0, 60).map(async (id): Promise<Arrow> => {
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
        })
      );
      setData({
        balance: formatEther(balance as bigint),
        arrows,
        pendingEth: formatEther(pendEth as bigint),
        pendingQuiver: formatEther(pendQuiver as bigint),
        loading: false,
      });
    } catch {
      setData((d) => ({...d, loading: false}));
    }
  }, [account]);

  useEffect(() => {
    load();
  }, [load]);

  return {...data, reload: load};
}
