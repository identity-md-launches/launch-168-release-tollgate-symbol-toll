# TOLLGATE (TOLL): a Uniswap v4 token + fee hook rehearsal

`univ4_hook` launch: a fixed-supply ERC-20 (`TollToken`, symbol **TOLL**) and a Uniswap v4 hook
(`TollgateHook`) that charges **2% in native ETH on every buy and every sell** of its pool, pays the
**first 1 ETH of fees to a fixed creator wallet**, and lets **anyone burn every fee after that**.

This is a technical rehearsal of the fee-and-cap mechanics ahead of a later production launch by the
same requester. It is not a consumer product and makes no claims beyond what the code does.

## Creator fee, disclosed

- **Rate:** 200 bps on the ETH leg of every buy (ETH -> TOLL) and every sell (TOLL -> ETH).
- **Recipient:** `0x70c6C4fcaAb11151FCEDb32eaaC3431547193A0a` (`CREATOR`), a compile-time constant.
- **Cap:** exactly **1 ETH in total, ever** (`CREATOR_CAP`). `creatorPaid` cannot exceed it.
- **After the cap:** every further fee is burnable to `0x000000000000000000000000000000000000dEaD`.
- **Immutability:** no owner, admin, pause, upgrade, fee setter, recipient setter or sweep. The
  PoolManager address is the hook's only constructor argument.

Full disclosure, including what is not covered: [`docs/DISCLOSURE.md`](docs/DISCLOSURE.md).

## Layout

| Path | What |
| --- | --- |
| `src/TollToken.sol` | self-contained ERC-20, zero-argument constructor, mints exactly 1e27 to `msg.sender`, 18 decimals, `burn`/`burnFrom` |
| `src/TollgateHook.sol` | the hook: flags `0x00CC`, ETH fee via ERC-6909 claims, capped creator payout, permissionless burn |
| `src/HookFlags.sol` | permission-bit helpers used for salt mining and by the admission floor |
| `test/TollToken.t.sol` | token supply, metadata, transfers, burns, absent admin selectors, opcode walk |
| `test/TollgateHook.t.sol` | permissions, access, all four swap directions, partial fills, foreign pool, cap, `payCreator`, `burnEth`, donated claims, reentrancy |
| `test/TollgateInvariant.t.sol` | stateful invariants with a trading, paying, burning and claim-donating actor |
| `test/LaunchRehearsal.t.sol` | factory rehearsal: CREATE2 at a mined salt, deployer-initialised pool, 80% one-sided seed, first buy into an ETH-less pool, sell after a buy, cap, payout, burn |
| `test/helpers/`, `test/mocks/` | local PoolManager router, fixture, opcode walk, `MockERC20` for the foreign pool |
| `docs/` | disclosure, deployment handoff, dependency provenance |
| `launch.json` | manifest for the launch node |
| `lib/` | vendored v4-core 1.0.2, forge-std, solmate `Owned` (plain files, no submodules) |

## Build and test (offline)

Needs Foundry with solc 0.8.26 in its compiler cache; nothing else. `foundry.toml` pins solc
0.8.26, EVM cancun, optimizer 200 runs, `via_ir = false`, `bytecode_hash = "none"`,
`cbor_metadata = false`, `ffi = false`, no filesystem permissions, `offline = true`.

```sh
forge build
forge test
forge fmt --check
```

54 tests: 11 token, 37 hook unit/fuzz, 5 launch rehearsal, 1 invariant suite with 7 invariants.

## How the fee works

The pool is `currency0 = native ETH`, `currency1 = TOLL`. The fee is always taken in ETH.

| Swap | Specified leg | Where the fee is taken | User sees |
| --- | --- | --- | --- |
| exact-in buy (`zeroForOne`, `amountSpecified < 0`) | ETH in | `beforeSwap`, positive specified `BeforeSwapDelta` | pays exactly `amountSpecified`; pool trades 98% of it |
| exact-out sell (`!zeroForOne`, `amountSpecified > 0`) | ETH out | `beforeSwap`, positive specified `BeforeSwapDelta` | receives exactly `amountSpecified`; pool produces 102% of it |
| exact-out buy (`zeroForOne`, `amountSpecified > 0`) | TOLL out | `afterSwap`, positive unspecified `int128` | receives exactly the tokens; pays raw ETH + 2% |
| exact-in sell (`!zeroForOne`, `amountSpecified < 0`) | TOLL in | `afterSwap`, positive unspecified `int128` | pays exactly the tokens; receives raw ETH - 2% |

In every case `afterSwap` checks that the raw pool delta on the specified side equals
`amountSpecified + specifiedFee` and reverts `PartialFill` otherwise, then collects the fee with
`poolManager.mint(address(this), 0, fee)`: an ERC-6909 claim on native ETH, minted inside the swap's
own settlement. No ETH is pushed and no contract other than the PoolManager is called from a swap
callback, which is also why the very first buy into a pool that holds no ETH works.

Pools on this hook whose `currency0` is not native ETH (the admission floor's `MockERC20` pools, for
example) are charged nothing and get zero deltas. Fees below 50 wei of ETH round to zero.

## Ledger

The swap path only increments `totalFees`. Everything else is derived:

```text
creatorEntitlement = min(CREATOR_CAP, totalFees)
creatorDue         = creatorEntitlement - creatorPaid
burnable           = totalFees - creatorEntitlement - burned
invariant          PoolManager.balanceOf(hook, 0) >= totalFees - creatorPaid - burned
```

`CapReached(totalFees, block.number)` is emitted exactly once, in the swap that crosses the cap.
Anyone may transfer ERC-6909 claims to the hook; they are not counted and stay stuck.

- `payCreator()`: permissionless, non-reentrant, pays `creatorDue` to `CREATOR` through
  `unlock -> burn claims -> take`; reverts `NothingDue` when nothing is owed.
- `burnEth()`: permissionless, non-reentrant, its own unlock (never inside a swap), 5-block cooldown
  counted from deployment (`TooSoon`), burns the whole `burnable` amount, reverts `NothingToBurn`
  below 0.01 ETH; sends to `BURN_SINK` through `unlock -> burn claims -> take`.

The reentrancy lock lives in transient slot `1` (a literal, so no hashed constant lands in a data
section). A linear opcode walk of every compiled contract, PUSH immediates skipped, finds no `F2`,
`F4` or `FF` byte; `test_runtimeCodeHasNoEscapeHatch` repeats it on the deployed runtime.

## Assumptions and limits

- The hook is not bound to the TOLL token. Any pool with native ETH as `currency0` and this hook
  pays the fee; only the pool in `launch.json` is the launch pool.
- The creator wallet must accept plain ETH. A contract there that reverts or re-enters makes
  `payCreator()` revert; the creator's share then stays as claims and never becomes burnable.
- Partial fills revert rather than charging on a partial amount. Routers must quote with the fee.
- Tests passing is not an audit. Before any production launch, an independent adversarial review
  and a fork rehearsal against the target chain's live PoolManager are required.

Deployment details, salt mining and operational responsibilities: [`docs/deployment.md`](docs/deployment.md).
Dependency provenance: [`docs/dependencies.md`](docs/dependencies.md).
