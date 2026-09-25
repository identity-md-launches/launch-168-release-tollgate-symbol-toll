// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "v4-core/src/types/BeforeSwapDelta.sol";

/// @title TollgateHook
/// @notice Uniswap v4 hook that charges a 2% fee in native ETH on every buy and every sell of a
/// pool whose currency0 is native ETH, keeps the fee inside the PoolManager as ERC-6909 claims,
/// pays the first 1 ETH of fees to a fixed CREATOR wallet and lets anyone burn everything after.
///
/// @dev DISCLOSURE (also in README.md, docs/DISCLOSURE.md and launch.json notes):
/// - Every buy (ETH -> token) and every sell (token -> ETH) pays 200 bps of its ETH leg to this hook.
/// - 100% of those fees are owed to `CREATOR` (0x70c6C4fcaAb11151FCEDb32eaaC3431547193A0a) until
///   exactly `CREATOR_CAP` (1 ETH) has accrued. `payCreator()` is permissionless and pays what is
///   owed; the creator can never receive more than 1 ETH in total from this contract.
/// - After the cap every further fee is burnable: `burnEth()` is permissionless and sends the whole
///   burnable amount to `BURN_SINK` (0x000000000000000000000000000000000000dEaD).
/// - Recipient, cap, rates and sink are compile-time constants. There is no owner, admin, pause,
///   upgrade, fee setter, recipient setter or sweep. ERC-6909 claims that third parties transfer to
///   the hook are stuck forever: the ledger only counts fees the hook charged itself.
///
/// Fee mechanics (fee is always in currency0 = native ETH):
/// - exact-in buy and exact-out sell specify the ETH leg: the fee is returned from `beforeSwap` as a
///   positive specified `BeforeSwapDelta`, so the pool trades `amountSpecified + fee`.
/// - exact-out buy and exact-in sell specify the token leg: the fee is 2% of the ETH the pool
///   actually moved and is returned from `afterSwap` as a positive unspecified `int128`.
/// - In both cases the fee is collected as `poolManager.mint(address(this), 0, fee)` inside the
///   swap's own unlock; the hook never pushes ETH or calls any contract other than the PoolManager
///   from a swap callback.
/// - A swap whose raw pool delta on the specified side is not exactly `amountSpecified + specifiedFee`
///   (a partial fill against a price limit or empty liquidity) reverts with `PartialFill`.
/// - Pools whose currency0 is not native ETH pay nothing and get zero deltas.
///
/// Reentrancy: a lock on transient slot 1 (a literal, not a hashed constant) guards the callbacks,
/// `payCreator`, `burnEth` and `unlockCallback`. The runtime contains no DELEGATECALL, CALLCODE or
/// SELFDESTRUCT.
contract TollgateHook is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;

    /// @notice The only trusted caller of the callbacks and the only external contract this hook calls.
    IPoolManager public immutable poolManager;

    /// @notice Fee on the ETH leg of a buy (ETH -> token), in basis points.
    uint256 public constant BUY_FEE_BPS = 200;
    /// @notice Fee on the ETH leg of a sell (token -> ETH), in basis points.
    uint256 public constant SELL_FEE_BPS = 200;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    /// @notice The most ETH the creator can ever receive from this contract, in total.
    uint256 public constant CREATOR_CAP = 1 ether;
    /// @notice The fixed creator wallet. Not changeable.
    address public constant CREATOR = 0x70c6C4fcaAb11151FCEDb32eaaC3431547193A0a;
    /// @notice Where post-cap fees are sent. Nobody holds a key for this address.
    address public constant BURN_SINK = 0x000000000000000000000000000000000000dEaD;
    /// @notice `burnEth()` refuses to burn less than this.
    uint256 public constant MIN_BURN = 0.01 ether;
    /// @notice Minimum blocks between two burns; the first window starts at deployment.
    uint256 public constant MIN_BLOCKS_BETWEEN_BURNS = 5;
    /// @notice ERC-6909 id of native ETH inside the PoolManager.
    uint256 public constant ETH_CLAIM_ID = 0;

    /// @notice Sum of every fee the hook has charged, in wei. Only the swap path increments it.
    uint256 public totalFees;
    /// @notice ETH already paid to `CREATOR`. Never exceeds `CREATOR_CAP`.
    uint256 public creatorPaid;
    /// @notice ETH already sent to `BURN_SINK`.
    uint256 public burned;
    /// @notice Block of the last burn, initialised to the deployment block.
    uint256 public lastBurnBlock;
    /// @notice Block in which `totalFees` first reached `CREATOR_CAP`; zero until then.
    uint256 public capReachedBlock;

    error InvalidPoolManager();
    error OnlyPoolManager();
    error Reentrancy();
    error UnexpectedCallback();
    error PartialFill();
    error NothingDue();
    error NothingToBurn();
    error TooSoon();

    /// @notice A fee was charged on a swap of the ETH pool.
    event FeeCharged(
        PoolId indexed poolId, address indexed sender, bool buy, uint256 fee, int256 amountSpecified
    );
    /// @notice Emitted exactly once, in the swap that makes `totalFees` reach `CREATOR_CAP`.
    event CapReached(uint256 totalFees, uint256 blockNumber);
    /// @notice ETH was paid to `CREATOR`.
    event CreatorPaid(uint256 amount, uint256 creatorPaidTotal);
    /// @notice ETH was sent to `BURN_SINK`.
    event EthBurned(uint256 amount, uint256 burnedTotal);

    /// @param manager The PoolManager. This is the only constructor argument; everything else is a
    /// compile-time constant. The address must be a literal in the deployment manifest. Only the
    /// zero address is rejected: the admission floor may deploy the hook before a manager exists at
    /// that address, and the fork rehearsal is where the literal is checked against live code.
    constructor(IPoolManager manager) {
        if (address(manager) == address(0)) revert InvalidPoolManager();
        poolManager = manager;
        lastBurnBlock = block.number;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    // ---------------------------------------------------------------------------------------------
    // Reentrancy lock on transient slot 1 (literal).
    // ---------------------------------------------------------------------------------------------

    modifier nonReentrant() {
        if (_locked()) revert Reentrancy();
        _setLock(true);
        _;
        _setLock(false);
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    function _locked() private view returns (bool locked) {
        assembly ("memory-safe") {
            locked := tload(1)
        }
    }

    function _setLock(bool locked) private {
        assembly ("memory-safe") {
            tstore(1, locked)
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Permissions: beforeSwap, afterSwap, beforeSwapReturnDelta, afterSwapReturnDelta = 0x00CC.
    // No initialize, liquidity or donate callbacks: pools open freely and LPs can always exit.
    // ---------------------------------------------------------------------------------------------

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    // ---------------------------------------------------------------------------------------------
    // Lazy ledger views.
    // ---------------------------------------------------------------------------------------------

    /// @notice How much of `totalFees` belongs to the creator: min(CREATOR_CAP, totalFees).
    function creatorEntitlement() public view returns (uint256) {
        uint256 fees = totalFees;
        return fees < CREATOR_CAP ? fees : CREATOR_CAP;
    }

    /// @notice What `payCreator()` would pay right now.
    function creatorDue() public view returns (uint256) {
        return creatorEntitlement() - creatorPaid;
    }

    /// @notice What `burnEth()` would burn right now (ignoring MIN_BURN and the cooldown).
    function burnable() public view returns (uint256) {
        return totalFees - creatorEntitlement() - burned;
    }

    /// @notice True while `burnEth()` is inside the cooldown window.
    function burnCoolingDown() public view returns (bool) {
        return block.number < lastBurnBlock + MIN_BLOCKS_BETWEEN_BURNS;
    }

    /// @notice Fee on a swap that specifies the ETH leg (exact-in buy, exact-out sell); 0 otherwise.
    function specifiedFee(SwapParams calldata params) public pure returns (uint256) {
        if (!_specifiesEth(params)) return 0;
        // Sign already handled by the branch, so the casts cannot truncate.
        // forge-lint: disable-next-item(unsafe-typecast)
        uint256 magnitude =
            params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        return _feeOn(magnitude, params.zeroForOne);
    }

    // ---------------------------------------------------------------------------------------------
    // Swap callbacks.
    // ---------------------------------------------------------------------------------------------

    /// @notice `IHooks.beforeSwap`.
    /// @dev Returns the fee as a positive specified delta when the ETH leg is specified. Charges
    /// nothing on pools whose currency0 is not native ETH. Does not touch storage: the ledger is
    /// updated in `afterSwap`, once the fill has been verified.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        nonReentrant
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (!key.currency0.isAddressZero()) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        uint256 fee = specifiedFee(params);
        if (fee == 0) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
    }

    /// @notice `IHooks.afterSwap`.
    /// @dev `delta` is the raw pool delta, before the hook's own deltas are subtracted. The specified
    /// side must equal `amountSpecified + specifiedFee` exactly, otherwise the fill was partial and
    /// the whole swap reverts. When the token leg is specified the fee is 2% of the ETH the pool
    /// moved and is returned as a positive unspecified delta. The fee is then minted to the hook as
    /// ERC-6909 claims on id 0 and `totalFees` grows.
    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external nonReentrant onlyPoolManager returns (bytes4, int128) {
        if (!key.currency0.isAddressZero()) return (IHooks.afterSwap.selector, 0);

        uint256 fee;
        int128 unspecifiedFee = 0;
        if (_specifiesEth(params)) {
            fee = specifiedFee(params);
            // fee < 2^127 here: beforeSwap already cast it to int128, otherwise the swap reverted.
            // forge-lint: disable-next-item(unsafe-typecast)
            if (int256(delta.amount0()) != params.amountSpecified + int256(fee)) revert PartialFill();
        } else {
            if (int256(delta.amount1()) != params.amountSpecified) revert PartialFill();
            int128 ethDelta = delta.amount0();
            // Sign already handled by the branch, so the casts cannot truncate.
            // forge-lint: disable-next-item(unsafe-typecast)
            uint256 ethMoved = ethDelta < 0 ? uint256(uint128(-ethDelta)) : uint256(uint128(ethDelta));
            fee = _feeOn(ethMoved, params.zeroForOne);
            unspecifiedFee = fee.toInt128();
        }

        if (fee != 0) _collect(key, sender, params, fee);
        return (IHooks.afterSwap.selector, unspecifiedFee);
    }

    /// @dev Mints the fee to the hook as claims and updates the ledger. `CapReached` fires exactly
    /// once, in the swap that carries `totalFees` from below the cap to at or above it.
    function _collect(PoolKey calldata key, address sender, SwapParams calldata params, uint256 fee) private {
        uint256 before = totalFees;
        uint256 after_ = before + fee;
        totalFees = after_;
        emit FeeCharged(key.toId(), sender, params.zeroForOne, fee, params.amountSpecified);
        if (before < CREATOR_CAP && after_ >= CREATOR_CAP) {
            capReachedBlock = block.number;
            emit CapReached(after_, block.number);
        }
        // The PoolManager is the only contract ever called from a swap callback. `mint` credits the
        // hook with ERC-6909 claims and debits its delta; the positive hook delta the manager books
        // after this callback cancels that debit.
        poolManager.mint(address(this), ETH_CLAIM_ID, fee);
    }

    /// @dev The ETH leg is the specified one exactly when `(amountSpecified < 0) == zeroForOne`.
    function _specifiesEth(SwapParams calldata params) private pure returns (bool) {
        return (params.amountSpecified < 0) == params.zeroForOne;
    }

    function _feeOn(uint256 ethAmount, bool buy) private pure returns (uint256) {
        return ethAmount * (buy ? BUY_FEE_BPS : SELL_FEE_BPS) / BPS_DENOMINATOR;
    }

    // ---------------------------------------------------------------------------------------------
    // Permissionless payouts. Each one is its own unlock: burn claims, then take ETH out.
    // ---------------------------------------------------------------------------------------------

    /// @notice Pays `CREATOR` everything it is owed: min(CREATOR_CAP, totalFees) - creatorPaid.
    /// @dev Anyone may call. Reverts `NothingDue` when nothing is owed. The lifetime total can never
    /// exceed `CREATOR_CAP`. Effects are written before the unlock.
    function payCreator() external nonReentrant {
        uint256 due = creatorEntitlement() - creatorPaid;
        if (due == 0) revert NothingDue();
        creatorPaid += due;
        emit CreatorPaid(due, creatorPaid);
        // forge-lint: disable-next-item(unused-return)
        poolManager.unlock(abi.encode(CREATOR, due));
    }

    /// @notice Sends every burnable wei (totalFees - creatorEntitlement - burned) to `BURN_SINK`.
    /// @dev Anyone may call, at most once every `MIN_BLOCKS_BETWEEN_BURNS` blocks counted from the
    /// deployment block (`TooSoon`), and only when at least `MIN_BURN` is burnable (`NothingToBurn`).
    /// Runs in its own unlock, so it cannot be called from inside a swap.
    function burnEth() external nonReentrant {
        if (block.number < lastBurnBlock + MIN_BLOCKS_BETWEEN_BURNS) revert TooSoon();
        uint256 amount = burnable();
        if (amount < MIN_BURN) revert NothingToBurn();
        burned += amount;
        lastBurnBlock = block.number;
        emit EthBurned(amount, burned);
        // forge-lint: disable-next-item(unused-return)
        poolManager.unlock(abi.encode(BURN_SINK, amount));
    }

    /// @inheritdoc IUnlockCallback
    /// @dev Only reachable from `payCreator` or `burnEth` (the lock must be held) and only from the
    /// PoolManager. Burns the hook's own claims, which credits its delta, then takes the same amount
    /// of native ETH to the recipient, which cancels it.
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        if (!_locked()) revert UnexpectedCallback();
        (address to, uint256 amount) = abi.decode(data, (address, uint256));
        poolManager.burn(address(this), ETH_CLAIM_ID, amount);
        poolManager.take(CurrencyLibrary.ADDRESS_ZERO, to, amount);
        return "";
    }
}
