# Vendored source inputs

Only the Solidity import closure needed by contracts, scripts, and tests is copied from the supplied
`/home/seat10/vendor` mirrors. Nothing downloads during compilation or testing; no dependency is a
submodule or symlink. Unused upstream tooling and remote test suites are omitted. Vendored Solidity
is unchanged. `dependencies.sha256` pins every delivered dependency file by content; verify it with
`sha256sum -c docs/dependencies.sha256` from the repository root.

| Dependency | Mirror package metadata | Included scope | License |
|---|---|---|---|
| Uniswap v4-core | 1.0.2 | PoolManager, interfaces/types/libraries, swap/liquidity test routers and CurrencySettler | Per-file MIT or BUSL-1.1, both texts in `lib/v4-core/licenses/` |
| OpenZeppelin Contracts | 5.7.0 | ERC20 and its dependencies | MIT, `lib/openzeppelin-contracts/LICENSE` |
| forge-std | 1.16.2 | Test/Script and imported support | MIT or Apache-2.0, `lib/forge-std/LICENSE-*` |
| Solmate | v4-core mirror dependency | Owned, used by the real test PoolManager | AGPL-3.0, `lib/v4-core/lib/solmate/LICENSE`; see the source's SPDX |

Package versions are mirror metadata, not claims that moving upstream branches match these bytes.
File digests are the reproducibility pin. No repository commit IDs were assumed or synthesized.
Application contracts are MIT licensed. Source dependencies retain their own notices and licenses.
