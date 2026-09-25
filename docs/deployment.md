# Deployment handoff

This assignment authorises no transactions and controls no wallet. Everything below is what the
LaunchFactory / manifest node needs to reproduce the rehearsal in `test/LaunchRehearsal.t.sol`.

## Artifacts

| Contract | Source | Constructor | Notes |
| --- | --- | --- | --- |
| `TollToken` | `src/TollToken.sol` | none | mints 1e27 to `msg.sender` (the factory) |
| `TollgateHook` | `src/TollgateHook.sol` | `(address poolManager)` | literal PoolManager address, nothing else |
| `HookFlags` | `src/HookFlags.sol` | library, internal only | salt mining helper, no runtime code |

Toolchain, fixed in `foundry.toml`: solc 0.8.26, EVM `cancun`, optimizer on with 200 runs,
`via_ir = false`, `bytecode_hash = "none"`, `cbor_metadata = false`. Dependencies are vendored as
plain files under `lib/` (see `docs/dependencies.md`); the build needs no network.

```sh
forge build
forge test
forge fmt --check
```

## Hook address

The hook's permissions are encoded in its address. The low 14 bits must equal `0x00CC`:

| Bit | Permission |
| --- | --- |
| 7 | `beforeSwap` |
| 6 | `afterSwap` |
| 3 | `beforeSwapReturnDelta` |
| 2 | `afterSwapReturnDelta` |

Mine a CREATE2 salt from the deploying address with `HookFlags.matches(predicted, HookFlags.TOLLGATE)`
(about 16,000 tries on average) and deploy `type(TollgateHook).creationCode ++ abi.encode(poolManager)`
with that salt. The constructor calls `Hooks.validateHookPermissions`, so a wrong address reverts at
deployment rather than producing a broken pool. The salt depends on the deployer address and the
PoolManager literal; changing either means re-mining, not recompiling.

## PoolManager literal

`launch.json` names the canonical Uniswap v4 PoolManager on Ethereum mainnet
(`0x000000000004444c5dc75cB358380D2e3dE08A90`). If the manifest node retargets the rehearsal to
another chain, substitute that chain's canonical PoolManager from
https://docs.uniswap.org/contracts/v4/deployments and re-mine the salt. The constructor only rejects
the zero address; it does not check that code exists at the literal, so the fork rehearsal is where
a wrong literal is caught.

## Pool

| Parameter | Value |
| --- | --- |
| `currency0` | native ETH (`address(0)`) |
| `currency1` | `TollToken` |
| LP fee | 3000 (0.30%), static |
| tick spacing | 60 |
| opening price | `sqrtPriceX96 = 79228162514264337593543950336000` (1 ETH = 1,000,000 TOLL) |

The rehearsal opens the pool from the deployer with `PoolManager.initialize` (there is no
`beforeInitialize` gate), then adds 80% of the supply as one-sided token liquidity in a range whose
upper tick is at or below the opening tick, so the seed needs no ETH and buys push the price down
into the range. The remaining 20% stays with the factory for whatever the launch policy says.

The first buy works against a pool that holds no ETH because the fee is collected as ERC-6909
claims inside the swap's own settlement, never as an ETH transfer.

## Operational responsibilities

- **Nobody has to operate the hook.** `payCreator()` and `burnEth()` are permissionless; the
  creator, a keeper, or any trader can call them. Neither the requester nor IdentityMD holds a key
  that can change anything.
- `payCreator()` reverts `NothingDue` when nothing is owed. It sends ETH to
  `0x70c6C4fcaAb11151FCEDb32eaaC3431547193A0a` only, up to 1 ETH lifetime.
- `burnEth()` reverts `TooSoon` inside the 5-block cooldown (which starts at the deployment
  block) and `NothingToBurn` when less than 0.01 ETH is burnable. It sends the whole burnable amount
  to `0x000000000000000000000000000000000000dEaD`.
- Routers must handle the fee when quoting: the user-facing ETH leg is `amountSpecified` for
  exact-in buys and exact-out sells, and raw pool leg +/- 2% for the other two. A partial fill
  reverts (`PartialFill`), so price limits must allow the full amount.
- Do not transfer ERC-6909 claims or ETH to the hook. They cannot be recovered.

## Before a production launch

- Independent adversarial review of `src/` by a contributor who did not write it.
- Fork rehearsal against the target chain's live PoolManager at the literal address.
- Confirm the creator wallet can receive plain ETH transfers (an EOA, or a contract that does not
  revert and does not re-enter).
