import {createWalletClient, custom, type WalletClient} from "viem";
import {robinhoodChain} from "./chain";
import {ROBINHOOD_CHAIN} from "./config";

// Lightweight injected-wallet (EIP-1193) integration — no wagmi/connectkit dependency tree.

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

/** Subscribe to wallet account/chain changes. Returns an unsubscribe function. */
export function onWalletEvents(handlers: {
  onAccountsChanged?: (account: `0x${string}` | null) => void;
  onChainChanged?: (chainIdHex: string) => void;
}): () => void {
  const eth = getInjected();
  if (!eth?.on) return () => {};
  const accountsHandler = (...args: unknown[]) => {
    const accounts = args[0] as string[];
    handlers.onAccountsChanged?.((accounts?.[0] as `0x${string}`) ?? null);
  };
  const chainHandler = (...args: unknown[]) => {
    handlers.onChainChanged?.(args[0] as string);
  };
  eth.on("accountsChanged", accountsHandler);
  eth.on("chainChanged", chainHandler);
  return () => {
    eth.removeListener?.("accountsChanged", accountsHandler);
    eth.removeListener?.("chainChanged", chainHandler);
  };
}

export function walletClient(): WalletClient {
  const eth = getInjected();
  if (!eth) throw new Error("No wallet found.");
  return createWalletClient({chain: robinhoodChain, transport: custom(eth)});
}

/** Error code may be top-level or nested (MetaMask mobile wraps it). */
function errCode(err: unknown): number | undefined {
  const e = err as {code?: number; data?: {originalError?: {code?: number}}};
  return e?.code ?? e?.data?.originalError?.code;
}

async function ensureChain(eth: Eip1193) {
  const hexId = "0x" + ROBINHOOD_CHAIN.id.toString(16);
  try {
    await eth.request({method: "wallet_switchEthereumChain", params: [{chainId: hexId}]});
  } catch (err: unknown) {
    // 4902 = chain unknown to the wallet → add it, then re-verify below.
    if (errCode(err) === 4902) {
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
    // Other errors (e.g. 4001 user rejection) fall through to the verification below,
    // which turns a silent wrong-network state into an explicit failure.
  }
  const current = (await eth.request({method: "eth_chainId"})) as string;
  if (parseInt(current, 16) !== ROBINHOOD_CHAIN.id) {
    throw new Error(`Wrong network — please switch your wallet to ${ROBINHOOD_CHAIN.name} (chain ${ROBINHOOD_CHAIN.id}).`);
  }
}
