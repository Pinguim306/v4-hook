import {createWalletClient, custom, type WalletClient} from "viem";
import {robinhoodChain} from "./chain";
import {ROBINHOOD_CHAIN} from "./config";

// Lightweight injected-wallet (EIP-1193) integration — no wagni/connectkit dependency tree.

type Eip1193 = {
  request: (args: {method: string; params?: unknown[]}) => Promise<unknown>;
  on?: (event: string, handler: (...a: unknown[]) => void) => void;
  removeListener?: (event: string, handler: (...a: unknown[]) => void) => void;
};

export function getInjected(): Eip1193 | null {
  const eth = (window as unknown as {ethereum?: Eip1193}).ethereum;
  return eth ?? null;
}

export async function connect(): Promise<`0x${string}` | null> {
  const eth = getInjected();
  if (!eth) throw new Error("No wallet found. Install a browser wallet to connect.");
  const accounts = (await eth.request({method: "eth_requestAccounts"})) as string[];
  await ensureChain(eth);
  return (accounts?.[0] as `0x${string}`) ?? null;
}

export async function currentAccount(): Promise<`0x${string}` | null> {
  const eth = getInjected();
  if (!eth) return null;
  const accounts = (await eth.request({method: "eth_accounts"})) as string[];
  return (accounts?.[0] as `0x${string}`) ?? null;
}

export function walletClient(): WalletClient {
  const eth = getInjected();
  if (!eth) throw new Error("No wallet found.");
  return createWalletClient({chain: robinhoodChain, transport: custom(eth)});
}

async function ensureChain(eth: Eip1193) {
  const hexId = "0x" + ROBINHOOD_CHAIN.id.toString(16);
  try {
    await eth.request({method: "wallet_switchEthereumChain", params: [{chainId: hexId}]});
  } catch (err: unknown) {
    // 4902 = unknown chain → add it.
    if ((err as {code?: number})?.code === 4902) {
      await eth.request({
        method: "wallet_addEthereumChain",
        params: [
          {
            chainId: hexId,
            chainName: ROBINHOOD_CHAIN.name,
            nativeCurrency: ROBINHOOD_CHAIN.nativeCurrency,
            rpcUrls: [ROBINHOOD_CHAIN.rpcUrls.default.http[0]],
            blockExplorerUrls: [ROBINHOOD_CHAIN.blockExplorers.default.url],
          },
        ],
      });
    }
  }
}
