import {createPublicClient, http, defineChain} from "viem";
import {ROBINHOOD_CHAIN} from "./config";

export const robinhoodChain = defineChain(ROBINHOOD_CHAIN);

export const publicClient = createPublicClient({
  chain: robinhoodChain,
  transport: http(),
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
