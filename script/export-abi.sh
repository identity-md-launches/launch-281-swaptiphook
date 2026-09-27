#!/usr/bin/env bash
set -euo pipefail

mkdir -p docs/abi
forge inspect --offline src/STIP.sol:STIP abi --json > docs/abi/STIP.json
forge inspect --offline src/SwapTipHook.sol:SwapTipHook abi --json > docs/abi/SwapTipHook.json
