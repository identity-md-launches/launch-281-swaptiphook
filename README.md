# Swap Tip (STIP)

This contribution implements the fixed-supply token, optional ETH-tip hook, offline tests, ABI exports,
and deployment rehearsal. The network's separate assignments produce/review `launch.json`, publish,
attest, admit, deploy through the factory, and build the frontend. No transactions have been sent.

`src/STIP.sol:STIP` is a zero-argument ERC-20 named **Swap Tip**, symbol **STIP**, with 18 decimals.
It mints exactly `1_000_000_000 * 10^18` units to `msg.sender` once, including when the caller is a
factory. It has no owner, additional mint/burn entry point, fee, pause, upgrade, or administrative role.

`src/SwapTipHook.sol:SwapTipHook` takes exactly one argument, `IPoolManager`. Production configuration
is Sepolia, chain **11155111**, PoolManager **0xE03A1074c86CFeDd5C142C4F04F1a1536e203543**.
The token address is learned from the pool key; it is not a constructor argument. The hook applies
to any pool using this hook whose `currency0` is native ETH, and ignores other pools entirely.
The constructor validates precisely the four permission bits `0x00cc` through
`Hooks.validateHookPermissions`: beforeSwap, afterSwap, beforeSwapReturnDelta, afterSwapReturnDelta.
There are no initialization/liquidity callbacks, setters, sweep, admin, or upgrade paths.

## Swap rules

Send `hookData = abi.encode(uint16(tipBps), recipient)`, exactly 64 bytes. The contract decodes two
`uint256` words, so dirty address padding cannot cause an ABI decode revert. For native-ETH pools:

- A first word of 1–500 and a canonical nonzero recipient other than the hook or PoolManager enables tipping.
- A first word above 500 reverts with `TipTooHigh`, including oversized words that would truncate to a
  smaller uint16. This bound is checked before recipient validity.
- Zero bps, invalid recipients, an address word at least `2^160`, or any other data length charges zero.
- Dust tips round down to zero without reverting or emitting a zero-value tip event.
- All callbacks check that the caller is the immutable PoolManager. Non-ETH pools return zero without
  decoding tip data, recording tips, or imposing partial-fill checks.

The ordinary pool LP fee is independent of the optional tip. A swap without a valid tip pays no **hook** fee.
`hookData` is unauthenticated and routers can supply or modify it; wallets must inspect the recipient and
enforce their own input/output limits. The hook does not identify or authenticate the end user through a
router. `tx.origin` is only the public `tipper` leaderboard label. It grants no withdrawal rights and may
identify a relayer rather than an account-abstraction user. The recipient encoded in valid data is the
only account entitled to claim. A router receives no automatic credit.

Let `A = abs(amountSpecified)`, `b = tipBps`, and `F = floor(base * b / 10000)`.

| Swap mode | Fee base | Returned fee | Exact specified leg |
|---|---|---|---|
| Buy, exact ETH input | A | beforeSwap: positive specified F | User spends A ETH; pool consumes A − F |
| Sell, exact ETH output | A | beforeSwap: positive specified F | Pool produces A + F ETH; user receives A |
| Buy, exact STIP output | Actual pool ETH input | afterSwap: positive unspecified F | User receives exactly A STIP; pays pool ETH + F |
| Sell, exact STIP input | Actual pool ETH output | afterSwap: positive unspecified F | User spends exactly A STIP; receives pool ETH − F |

For native-ETH pools, `afterSwap` verifies the pool's specified delta, accounting for the beforeSwap
fee. A price-limit partial fill reverts with `PartialFill`, with or without valid tip data. The whole
swap, claims mint, events, and accounting roll back. PoolManager wraps hook errors inside `WrappedError`.
Swap sizes remain subject to v4's signed delta limits; no fee cast silently truncates.

## Settlement and interface

The swap callbacks call only `poolManager.mint(address(this), 0, fee)` for settlement. They never
`take` ETH or call a recipient. The returned positive hook delta cancels the negative mint delta.
This permits the first buy before the PoolManager holds any ETH. The swap router pays its final debt
before returning from the unlock.

`claim()` withdraws the caller's entire claimable ETH. It zeroes the balance, enters its own
PoolManager unlock, burns ETH claims (id 0), then calls `take(nativeETH, recipient, amount)`. The
claim guard rejects reentry. A rejecting recipient rolls back the entire claim and can retry. Empty
claims revert with `NothingToClaim`. Call claim outside any existing PoolManager unlock. Recipients
must be able to call the hook and receive ETH; no admin can redirect an inaccessible recipient's tip.

| View | Meaning |
|---|---|
| `balanceOf(address)` | ETH still payable to that recipient, in wei |
| `totalTipped(bytes32 poolId)` | Lifetime tips for that exact PoolKey |
| `tippedBy(address)` | Lifetime ETH tips attributed to the display-only tx.origin |
| `receivedBy(address)` | Lifetime ETH tips credited to that recipient |
| `poolManager()` | Immutable settlement manager |
| `getHookPermissions()` | Four enabled flags; all others false |

`Tipped(bytes32 indexed poolId, address indexed tipper, address indexed recipient, uint16 bps, uint256 amount)`
is emitted for each nonzero tip. `Claimed(address indexed recipient, uint256 amount)` is emitted after
successful payout. Claims do not reduce the lifetime counters. Pool totals are isolated by PoolId;
the address-based views aggregate across pools, as their specified interfaces require.

The stateful invariant checks `sum(balanceOf(recipient)) == manager.balanceOf(hook, 0)` after every
hook-driven tip/claim sequence, starting from zero claims. There is an unavoidable qualification to a
literal universal equality: v4 lets third parties mint or transfer claims directly to any address,
without a receiver callback. Such an unsolicited gift increases the hook's backing but creates no
recipient debt. `test_unsolicitedClaimsCreateSurplusWithoutNewDebt` reproduces this; the general
solvency relation is then `claims >= liabilities`. Surplus is inaccessible because the requested hook
has no sweep. See `REVIEW.md` for the exact sequence and review disposition.

ABI arrays are exported in `docs/abi/STIP.json` and `docs/abi/SwapTipHook.json`.

## Offline checks

All imported Solidity is vendored as ordinary files under `lib/`; no submodules, npm install, network,
compiler binary, FFI, or filesystem cheatcode permissions are needed. Solidity **0.8.26** is pinned,
optimizer runs are **200**, and metadata `bytecode_hash = "none"`. The EVM target is **Cancun** because
the real v4 PoolManager uses EIP-1153 transient storage; Paris cannot compile that dependency.
Dependency source digests and licenses are recorded under `docs/dependencies*` and `lib/`.

```sh
forge build --offline
forge test --offline
forge fmt --check
EXPECTED_CHAIN_ID=0 forge script script/Deploy.s.sol:Deploy --offline
```

Tests deploy a real PoolManager and CREATE2-mine the hook; they never replace hook code or bypass
constructor validation. Tests use no environment variables and run independently. The suite covers
all four modes, 1/500 bps, invalid data, oversized words, dust, partial fills, first buys, settlement
failure, separate pool totals, claims/reentry, token transfers/allowances, constructor flags, and
prohibited runtime opcodes. Stateful invariants use four recipients and two pools, 128 runs of
64 operations, with reverts treated as failures. A second fuzz test interleaves 32 swaps/claims and
finally empties every recipient balance in each of 256 runs.

## Factory rehearsal and operator handoff

The pool configuration is native ETH at currency0, STIP at currency1, fee **3000**, tickSpacing **60**,
and this hook. Mine the CREATE2 salt against the **actual factory's CREATE2 deployer address**, final
creation bytecode, and the ABI-encoded Sepolia manager constructor argument. The lower 14 address bits
must equal `0x00cc`; the constructor enforces this. No signer, RPC secret, or private key belongs here.

`test/LaunchRehearsal.t.sol` atomically deploys the zero-argument token into a factory, verifies receipt
of the entire supply, deploys the mined hook, initializes the pool, and seeds token-only liquidity via
an unlock callback with sync → token transfer → settle. It asserts zero ETH held by the manager before
the first buy. Both exact-in and exact-out first buys and subsequent selling/claiming are tested.

**Manifest input is missing:** the supplied workflow gives no numeric price, seed amount, seed range,
factory implementation, or final manifest. The checked fixture uses proposed values in
`docs/rehearsal.json`: price at tick 184200, lower tick −887220, upper tick 184200, and a 900 million STIP
seed budget. The position starts entirely in token1, at its upper boundary. Remaining tokens are
returned to the fixture caller for tests; that transfer is not a prescribed production allocation.
The separate manifest author must adopt these values or update and rerun this rehearsal with the
final parameters. This verifies the described factory sequence, not an unavailable deployed factory's
implementation or an unknown final manifest price.

The operator's key-free standalone hook simulation command is:

```sh
EXPECTED_CHAIN_ID=11155111 forge script script/Deploy.s.sol:Deploy --offline --chain-id 11155111
```

That script uses the standard deterministic deployment proxy, performs exactly one hook deployment
between broadcast markers, and does not broadcast without a CLI broadcast option. Its salt is for
that proxy, **not** for the network launch factory. The script reads only `EXPECTED_CHAIN_ID`, allows
only 31337/11155111, and accepts zero as an expected-chain wildcard for local verification. Production
token-and-hook deployment remains the network deployer's responsibility after manifest and independent
adversarial review. No frontend, live deployment, independent attestation, or signed policy is claimed
by this source contribution.

Maintainer references: the vendored [Uniswap Hooks implementation](https://github.com/Uniswap/v4-core/blob/main/src/libraries/Hooks.sol)
defines return-delta signs and address permissions; [PoolManager](https://github.com/Uniswap/v4-core/blob/main/src/PoolManager.sol)
defines mint/burn/take settlement. The vendored bytes, not the moving web branches, are the build inputs.
