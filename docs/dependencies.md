# Vendored dependencies

Everything the build needs is committed as ordinary files under `lib/`. There are no git
submodules, no package manager step and no network access during `forge build` or `forge test`.
`foundry.toml` sets `offline = true` and maps the remappings explicitly.

| Package | Version | Vendored | Remapping | License |
| --- | --- | --- | --- | --- |
| [Uniswap v4-core](https://github.com/Uniswap/v4-core) | 1.0.2 (npm `@uniswap/v4-core@1.0.2`, git head `59d3ecf53afa9264a16bba0e38f4c5d2231f80bc`) | `src/` without `src/test/`, `licenses/` | `v4-core/=lib/v4-core/` | BUSL-1.1 (core), MIT (libraries, interfaces, types) |
| [forge-std](https://github.com/foundry-rs/forge-std) | v1.9.7 | `src/`, `LICENSE-APACHE`, `LICENSE-MIT` | `forge-std/=lib/forge-std/src/` | MIT OR Apache-2.0 |
| [solmate](https://github.com/transmissions11/solmate) | the pin inside v4-core 1.0.2 (`Owned.sol` only, needed by `ProtocolFees.sol`) | `src/auth/Owned.sol`, `LICENSE` | `solmate/=lib/solmate/` | AGPL-3.0-only |

The delivered contracts (`src/TollToken.sol`, `src/TollgateHook.sol`, `src/HookFlags.sol`) import
only from v4-core. The token imports nothing at all. forge-std and solmate are used by tests and by
the locally deployed PoolManager respectively.

`forge fmt` ignores `lib/**` so the upstream bytes are preserved as delivered.
