# TOLLGATE (TOLL) creator-fee disclosure

This document exists so that nobody trading the TOLLGATE pool can say they were not told. It is a
technical rehearsal of a fee-and-cap mechanism, not a consumer product, and it makes no claim beyond
what the code in `src/TollgateHook.sol` and `src/TollToken.sol` does.

## What is charged

| Item | Value | Where it is fixed |
| --- | --- | --- |
| Fee on every buy (ETH -> TOLL) | 2% (200 bps) of the ETH leg | `BUY_FEE_BPS`, compile-time constant |
| Fee on every sell (TOLL -> ETH) | 2% (200 bps) of the ETH leg | `SELL_FEE_BPS`, compile-time constant |
| Currency of the fee | always native ETH (`currency0`) | `beforeSwap` / `afterSwap` |
| Creator wallet | `0x70c6C4fcaAb11151FCEDb32eaaC3431547193A0a` | `CREATOR`, compile-time constant |
| Creator cap | exactly 1 ETH in total, ever | `CREATOR_CAP`, compile-time constant |
| Burn sink | `0x000000000000000000000000000000000000dEaD` | `BURN_SINK`, compile-time constant |
| Smallest burn | 0.01 ETH | `MIN_BURN` |
| Burn cooldown | 5 blocks, first window starts at deployment | `MIN_BLOCKS_BETWEEN_BURNS` |

The pool's own LP fee (chosen at pool creation, 0.30% in the rehearsal) is separate and goes to
liquidity providers as in any Uniswap v4 pool. The hook never overrides it.

## Who gets the fee

1. **Until 1 ETH of fees has accrued, 100% belongs to the creator wallet.** `creatorEntitlement()` is
   `min(1 ETH, totalFees)`. Anyone can call `payCreator()`; it pays `creatorEntitlement() -
   creatorPaid` to `CREATOR` and reverts `NothingDue` when that is zero. `creatorPaid` can never
   exceed 1 ETH; this is enforced by arithmetic, not by policy, and is covered by unit, fuzz and
   invariant tests.
2. **After the cap, every fee is burnable.** `burnable()` is `totalFees - creatorEntitlement() -
   burned`. Anyone can call `burnEth()`; it sends the whole burnable amount to the sink address,
   at most once every 5 blocks and only when at least 0.01 ETH is burnable. The sink has no known
   private key. This is a transfer to an unspendable address, not a change to any token supply.
3. The swap that carries `totalFees` across 1 ETH emits `CapReached(totalFees, block.number)`
   exactly once. `capReachedBlock()` records it.

## What cannot change

- There is no owner, admin, pauser, upgrade path, fee setter, recipient setter or sweep function.
  The hook is a plain contract behind no proxy, with the PoolManager address as its only
  constructor argument. Everything else is a literal in the source.
- The recipient, cap, rates and sink can only change by deploying a different contract at a
  different address, which would be a different pool.
- The hook has no `beforeInitialize`, liquidity or donate callbacks: anyone may open pools with it,
  and liquidity providers can always add and remove liquidity without the hook's involvement.
- The token is a fixed-supply ERC-20: 1,000,000,000 TOLL (1e27 base units) minted once to the
  deploying factory, 18 decimals, no owner, no mint, no pause, no proxy. Holders may burn their own.

## What the hook does with the money in the meantime

Fees never leave the PoolManager during a swap. The hook mints itself ERC-6909 claims on id 0
(native ETH) for each fee. `payCreator()` and `burnEth()` each open their own unlock, burn claims,
and have the PoolManager transfer the ETH. The hook never holds ETH in its own balance and never
pushes ETH from a swap callback.

Invariant (tested with an actor that also donates claims to the hook):

    PoolManager.balanceOf(hook, 0) >= totalFees - creatorPaid - burned

Claims that third parties transfer to the hook are not counted by the ledger and are stuck: there
is no function that can move them. Do not send claims or ETH to the hook.

## What is NOT covered

- Swaps that specify fewer than 50 wei of ETH round the fee down to zero and trade fee-free.
- Pools using this hook whose `currency0` is not native ETH are never charged. Pools whose
  `currency0` is ETH but whose `currency1` is some other token *are* charged: the hook is not bound
  to the TOLL token. Only the TOLL pool listed in `launch.json` is the launch pool.
- A partial fill (price limit or empty liquidity) reverts the whole swap with `PartialFill` rather
  than charging a fee on a partial amount. Routers must quote with the fee in mind.
- If the creator wallet is ever a contract that reverts on receiving ETH, `payCreator()` reverts
  and the creator's share stays inside the PoolManager as claims. It never becomes burnable.
- Tests passing is not an audit. The contracts hold other people's fees and must get an
  independent adversarial review before any production launch.
