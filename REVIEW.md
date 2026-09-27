# Review handoff

This is the implementation author's adversarial check record, **not an independent review or audit**.
The workflow assigns independent review and manifest approval to separate contributors. They must
inspect the final accepted source, constructor arguments, CREATE2 address, and generated manifest.
No manifest or deployment attestation is fabricated here.

## Findings requiring explicit handoff

**R1 — Literal universal claim equality is not enforceable with standard v4 claims.**
Sequence: swap 1 ETH exact-in at 500 bps to recipient R, so R is owed 0.05 ETH; another account unlocks
the manager, settles 1 wei ETH, and calls `manager.mint(hook, 0, 1)`; hook claims become 0.05 ETH + 1 wei
while R remains owed 0.05 ETH. Equivalently, transfer preexisting ERC-6909 id-0 claims to the hook.
Neither path calls the hook, so it cannot refuse the gift. R still claims exactly 0.05 ETH, leaving
the extra wei backed and unallocated. Reproducer: `test_unsolicitedClaimsCreateSurplusWithoutNewDebt`.
Disposition: disclosed specification qualification; no fund loss or undercollateralization. The
required equality invariant covers hook-generated transitions with no unsolicited claims. The fully
general property is claims ≥ recipient liabilities. This remains a concrete requirement conflict for
the independent reviewer if “always” includes arbitrary third-party claim gifts. Adding a sweep or
inventing a recipient for such gifts would change the approved interface and economics.

**R2 — Exact final-manifest rehearsal cannot yet be asserted.**
The provided workflow fixes token supply, manager, fee, tick spacing, and token-only seeding but omits
numeric initial price, seed allocation/range, actual factory code, and manifest. The supplied floor
does not supply them either. Reproducer: compare `docs/rehearsal.json` with the manifest when available.
Disposition: proposed parameters are explicit and tested; final manifest producer/reviewer must
reconcile these values and rerun if different. This is not a dependency on a later deployment result.

**R3 — Ambiguous invalid-data precedence resolved explicitly.**
Sequence: swap with `abi.encode(uint256(501), type(uint256).max)` (64 bytes). The first word exceeds
the explicit cap and reverts with `TipTooHigh`, even though the second word is also malformed.
For a first word ≤500, the same malformed address means no tip and no revert caused by decoding.
Disposition: follows the explicit “above 500 reverts” rule; fixed regression test and README state
precedence. Non-ETH pools ignore even that excessive rate, consistent with “no other effect.”

## Attack sequences exercised

| Surface | Concrete sequence and result | Regression |
|---|---|---|
| Length decoding | Swap with empty, short, 32-, 96-byte, and fuzzed non-64-byte data; compare to untipped swaps | `test_invalidTipsChargeNothing`, `testFuzz_badLengthsCannotDecodeRevert` |
| Address padding | Swap with rate 500 and second word `2^160`/max uint256/fuzzed dirty word; no fee | `testFuzz_dirtyRecipientWordIgnored` |
| Rate truncation | Swap in all four modes with first word 501, 65536, 65537, max uint256; each returns wrapped `TipTooHigh` | `test_501AndOversizedRateRevertWithoutTruncation` |
| Fee signs and specified amount | Execute equivalent untipped pool operation from a snapshot, restore, tip at 1/500 bps or fuzzed rate, compare both wallet legs and events | `test_allFourModesAtOneAndFiveHundredBps`, `testFuzz_exactSpecifiedAndFee` |
| Rounding | One-wei specified amounts in every mode at 1/500 bps; fee rounds to zero | `test_dustAllModes` |
| No-op/partial fill | Set the price limit one sqrt-price unit from the initial price and request 100 ETH/STIP in every mode, with and without a tip; revert `PartialFill` and roll back mint/state/price | `test_partialFillAllModesWithAndWithoutTipRollsBack` |
| First-buy settlement | Factory seeds only STIP into an ETH-empty real manager; exact-in and exact-out first buys mint claims successfully | `LaunchRehearsalTest` |
| Callback spoofing | Call beforeSwap, afterSwap, and unlockCallback directly; all reject non-manager callers | `test_callbacksRejectNonManager` |
| Unsolicited unlock callback | Manager-address call to hook unlockCallback without claim state; `NoClaimInProgress` | `test_callbacksRejectNonManager` |
| Claim theft/double payout | Non-recipient claims; rightful recipient claims then repeats; only first rightful claim pays | `test_onlyRecipientCanClaimNoRouterCredit`, `test_claimPaysOnceAndKeepsLifetimeViews` |
| Claim reentry | Recipient calls claim from receive; observes zero balance and burned claims; reentry fails and original claim pays once | `test_reentrantClaimObservesZeroDebtAndCannotDoublePay` |
| Rejecting recipient | Receive reverts, then recipient enables receipt and retries; initial debt/claims survive and retry succeeds | `test_rejectedPayoutRollsBackAndCanRetry` |
| Existing manager unlock | Recipient opens manager unlock, calls claim from callback; nested unlock rejects and all debt survives | `test_claimInsideExistingUnlockRevertsAndPreservesDebt` |
| Failed token settlement | Revoke swap-router allowance; exact-out sell tentatively mints tip but settlement fails; mint/debt/price roll back | `test_failedSwapSettlementRollsBackTip` |
| Non-ETH pool | Initialize/add liquidity and swap both directions/modes with oversized rate; behavior identical to no tip | `test_nonNativePoolIgnoresEvenOversizedRate` |
| Cross-pool accounting | Alternate fees/pool IDs, multiple recipients, and claims; pool totals stay isolated and debt aggregates correctly | `AccountingInvariantTest` |
| Mutable authority | Probe common admin/mint selectors from deployer and outsider; none exists; scan token and hook opcode streams | `STIPTest`, `DeploymentTest` |

## Checks recorded by implementer

Solidity 0.8.26, optimizer 200, Cancun, metadata hash none; all imports local. `forge build --offline`,
`forge test --offline`, `forge fmt --check`, and the key-free `EXPECTED_CHAIN_ID=0 forge script
script/Deploy.s.sol:Deploy --offline` are the final verification commands. The completed suite contains
34 tests, with 256 fuzz cases per fuzz test and a 128 × 64 stateful invariant. The invariant requires
zero unexpected handler reverts. Results are self-checks and carry no independent review authority.

The protected suites were read as supplied; their environment-driven artifact tests are left to the
independent verifier. Local equivalents test supply, permissions, callback refusal, administrator
absence, exact transfers, opcode exclusions, and a real-manager lifecycle without `vm.etch`.
No mainnet/Sepolia fork, live factory, live router code check, Slither, formal verification, independent
audit, or deployment was run. These are not claimed as passing. The script accepts the specified
Sepolia manager address but a live code/chain check remains the deployment service's responsibility.
