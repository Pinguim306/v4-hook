// Network + contract configuration. Addresses are filled in at launch; they can be overridden
// at build time with VITE_* env vars so the same bundle can target testnet or mainnet.

export const ROBINHOOD_CHAIN = {
  id: 4663,
  name: "Robinhood Chain",
  nativeCurrency: {name: "Ether", symbol: "ETH", decimals: 18},
  rpcUrls: {
    default: {http: [import.meta.env.VITE_RPC_URL ?? "https://rpc.mainnet.chain.robinhood.com"]},
  },
  blockExplorers: {
    default: {name: "Blockscout", url: "https://robinhoodchain.blockscout.com"},
  },
} as const;

// The deployed contracts. Empty string = "not launched yet" → the UI shows a pre-launch state.
export const HOOK_ADDRESS = (import.meta.env.VITE_HOOK_ADDRESS ?? "") as `0x${string}` | "";
export const MIRROR_ADDRESS = (import.meta.env.VITE_MIRROR_ADDRESS ?? "") as `0x${string}` | "";

// Deep link to the Uniswap interface for buying QUIVER on Robinhood Chain.
export const UNISWAP_SWAP_URL = HOOK_ADDRESS
  ? `https://app.uniswap.org/swap?chain=robinhood&outputCurrency=${HOOK_ADDRESS}`
  : "https://app.uniswap.org/swap?chain=robinhood";

export const SUPPLY = 4663;
export const TOKEN_SYMBOL = "QUIVER";
export const NFT_NAME = "Arrow";

export const isLaunched = HOOK_ADDRESS.length > 0;
