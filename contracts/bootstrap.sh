#!/usr/bin/env bash
# Reproducibly install the Solidity dependencies at pinned commits.
# `forge install` recurses into each repo's own submodules, so these five
# top-level pins fully determine the dependency tree. Run from contracts/.
set -euo pipefail

cd "$(dirname "$0")"

pin() {
  local repo="$1" commit="$2" name="${1##*/}"
  if [ -d "lib/$name" ]; then
    echo "lib/$name already present, skipping"
  else
    forge install "$repo@$commit" --no-git
  fi
}

pin foundry-rs/forge-std 5cf980eefbf8a54050628334163127ed35453558
pin vectorized/solady     ab96a830e705de13e0f58cfaefadab4ac8257655
pin Uniswap/v4-core       46c6834698c48bc4a463a86d8420f4eb1d7f3b75
pin Uniswap/v4-periphery  3245c3cb99c48fa1dc2459c3b60abc37d4294aba
pin Uniswap/permit2       cc56ad0f3439c502c246fc5cfcc3db92bb8b7219

echo "Dependencies installed."
