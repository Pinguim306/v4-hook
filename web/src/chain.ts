import {createPublicClient, http, defineChain} from "viem";
import {ROBINHOOD_CHAIN} from "./config";

// Canonical Multicall3 address (same on 200+ chains). Used to simulate a `pokeFees()`
// harvest and read the resulting `pendingFees` in a single eth_call, so the fee counter
// reflects unharvested fees live. If it is not deployed here, the reads fall back to plain
// (unpoked) values — see useHoldings.
const MULTICALL3 = "0xcA11bde05977b3631167028862bE2a173976CA11" as const;

export const robinhoodChain = defineChain({
  ...ROBINHOOD_CHAIN,
  contracts: {multicall3: {address: MULTICALL3}},
});

// batch:true coalesces concurrent reads into JSON-RPC batch requests (no multicall
// contract dependency) — the holdings panel fires ~2 calls per arrow, which would
// otherwise hit public-RPC rate limits as a burst of individual HTTP requests.
export const publicClient = createPublicClient({
  chain: robinhoodChain,
  transport: http(undefined, {batch: {batchSize: 50, wait: 16}}),
});

// Minimal ABI — only the reads/writes the site needs.
export const hookAbi = [
  {type: "function", name: "name", stateMutability: "pure", inputs: [], outputs: [{type: "string"}]},
  {type: "function", name: "symbol", stateMutability: "pure", inputs: [], outputs: [{type: "string"}]},
  {type: "function", name: "seeded", stateMutability: "view", inputs: [], outputs: [{type: "bool"}]},
  {type: "function", name: "totalShares", stateMutability: "view", inputs: [], outputs: [{type: "uint256"}]},
  {type: "function", name: "SUPPLY", stateMutability: "view", inputs: [], outputs: [{type: "uint256"}]},
  {
    type: "function",
    name: "accFeesPerShareETH",
    stateMutability: "view",
    inputs: [],
    outputs: [{type: "uint256"}],
  },
  {
    type: "function",
    name: "balanceOf",
    stateMutability: "view",
    inputs: [{type: "address"}],
    outputs: [{type: "uint256"}],
  },
  {
    type: "function",
    name: "nftBalanceOf",
    stateMutability: "view",
    inputs: [{type: "address"}],
    outputs: [{type: "uint256"}],
  },
  {
    type: "function",
    name: "ownedTokensOf",
    stateMutability: "view",
    inputs: [{type: "address"}],
    outputs: [{type: "uint256[]"}],
  },
  {
    type: "function",
    name: "nftTokenURI",
    stateMutability: "view",
    inputs: [{type: "uint256"}],
    outputs: [{type: "string"}],
  },
  {
    type: "function",
    name: "pendingFees",
    stateMutability: "view",
    inputs: [{type: "uint256"}],
    outputs: [
      {name: "owedETH", type: "uint256"},
      {name: "owedQUIVER", type: "uint256"},
    ],
  },
  {
    type: "function",
    name: "pendingETH",
    stateMutability: "view",
    inputs: [{type: "address"}],
    outputs: [{type: "uint256"}],
  },
  {
    type: "function",
    name: "pendingQUIVER",
    stateMutability: "view",
    inputs: [{type: "address"}],
    outputs: [{type: "uint256"}],
  },
  {type: "function", name: "pokeFees", stateMutability: "nonpayable", inputs: [], outputs: []},
  {type: "function", name: "claim", stateMutability: "nonpayable", inputs: [{type: "uint256"}], outputs: []},
  {
    type: "function",
    name: "claimMany",
    stateMutability: "nonpayable",
    inputs: [{type: "uint256[]"}],
    outputs: [],
  },
  {type: "function", name: "withdrawPending", stateMutability: "nonpayable", inputs: [], outputs: []},
] as const;
