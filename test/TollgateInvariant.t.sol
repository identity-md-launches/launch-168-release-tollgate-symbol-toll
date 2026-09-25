// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Fixture} from "./helpers/Fixture.sol";
import {TestRouter} from "./helpers/TestRouter.sol";
import {TollToken} from "../src/TollToken.sol";
import {TollgateHook} from "../src/TollgateHook.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

/// @dev Stateful actor: trades in all four directions, pays the creator, burns, donates claims to
/// the hook and moves blocks. Every action is guarded so the invariant runner never sees a revert
/// it did not expect; unexpected reverts fail the run (`fail_on_revert = true`).
contract Handler is Test {
    PoolManager internal manager;
    TestRouter internal router;
    TollgateHook internal hook;
    TollToken internal token;
    PoolKey internal key;

    uint256 public capEvents;
    uint256 public donated;
    uint256 public swaps;
    uint256 public payouts;
    uint256 public burns;
    uint256 public feesSeen;

    constructor(
        PoolManager manager_,
        TestRouter router_,
        TollgateHook hook_,
        TollToken token_,
        PoolKey memory key_
    ) {
        manager = manager_;
        router = router_;
        hook = hook_;
        token = token_;
        key = key_;
        token.approve(address(router), type(uint256).max);
    }

    receive() external payable {}

    function swap(uint96 seed, uint8 mode) external {
        uint256 amount = bound(uint256(seed), 0.001 ether, 20 ether);
        bool zeroForOne = mode % 2 == 0;
        bool exactIn = mode < 2;
        SwapParams memory params = SwapParams(
            zeroForOne,
            exactIn ? -int256(amount) : int256(amount),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        uint256 feesBefore = hook.totalFees();
        vm.recordLogs();
        router.swap{value: zeroForOne ? amount * 4 : 0}(key, params);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == TollgateHook.CapReached.selector) {
                ++capEvents;
            }
        }
        feesSeen += hook.totalFees() - feesBefore;
        ++swaps;
    }

    function pay() external {
        if (hook.creatorDue() == 0) {
            vm.expectRevert(TollgateHook.NothingDue.selector);
            hook.payCreator();
            return;
        }
        hook.payCreator();
        ++payouts;
    }

    function burn(uint8 rollBy) external {
        vm.roll(block.number + bound(uint256(rollBy), 0, 7));
        if (hook.burnCoolingDown()) {
            vm.expectRevert(TollgateHook.TooSoon.selector);
            hook.burnEth();
            return;
        }
        if (hook.burnable() < hook.MIN_BURN()) {
            vm.expectRevert(TollgateHook.NothingToBurn.selector);
            hook.burnEth();
            return;
        }
        hook.burnEth();
        ++burns;
    }

    function donate(uint96 seed) external {
        uint256 amount = bound(uint256(seed), 1, 1 ether);
        router.mintEthClaims{value: amount}();
        manager.transfer(address(hook), 0, amount);
        donated += amount;
    }

    function roll(uint8 by) external {
        vm.roll(block.number + bound(uint256(by), 1, 6));
    }
}

contract TollgateInvariantTest is Fixture {
    using TransientStateLibrary for IPoolManager;

    Handler internal handler;
    address internal constant CREATOR = 0x70c6C4fcaAb11151FCEDb32eaaC3431547193A0a;
    address internal constant SINK = 0x000000000000000000000000000000000000dEaD;

    function setUp() public override {
        super.setUp();
        handler = new Handler(manager, router, hook, token, ethKey);
        vm.deal(address(handler), 1_000_000 ether);
        token.transfer(address(handler), 1_000_000 ether);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = Handler.swap.selector;
        selectors[1] = Handler.pay.selector;
        selectors[2] = Handler.burn.selector;
        selectors[3] = Handler.donate.selector;
        selectors[4] = Handler.roll.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// @dev Coverage report for `-vv`: confirms the post-cap paths were really exercised.
    function afterInvariant() public view {
        console2.log("swaps", handler.swaps());
        console2.log("payouts", handler.payouts());
        console2.log("burns", handler.burns());
        console2.log("totalFees", hook.totalFees());
        console2.log("burned", hook.burned());
        console2.log("donated", handler.donated());
    }

    function invariant_creatorPaidNeverExceedsOneEther() public view {
        assertLe(hook.creatorPaid(), 1 ether);
        assertLe(hook.creatorPaid(), hook.totalFees());
        assertEq(CREATOR.balance, hook.creatorPaid(), "only payCreator moves ETH to the creator");
    }

    function invariant_claimsBackTheLedger() public view {
        uint256 owed = hook.totalFees() - hook.creatorPaid() - hook.burned();
        assertGe(manager.balanceOf(address(hook), 0), owed);
        assertEq(manager.balanceOf(address(hook), 0), owed + handler.donated(), "donations are stuck on top");
        assertGe(address(manager).balance, manager.balanceOf(address(hook), 0), "claims are backed by ETH");
    }

    function invariant_burnableIsZeroUntilTheCapAndExactAfterIt() public view {
        uint256 fees = hook.totalFees();
        if (fees < 1 ether) {
            assertEq(hook.burnable(), 0);
            assertEq(hook.burned(), 0);
            assertEq(hook.creatorEntitlement(), fees);
        } else {
            assertEq(hook.creatorEntitlement(), 1 ether);
            assertEq(hook.burnable(), fees - 1 ether - hook.burned());
        }
        assertEq(hook.creatorDue() + hook.burnable(), fees - hook.creatorPaid() - hook.burned());
    }

    function invariant_capReachedEmittedExactlyOnce() public view {
        bool reached = hook.totalFees() >= 1 ether;
        assertEq(handler.capEvents(), reached ? 1 : 0);
        assertEq(hook.capReachedBlock() != 0, reached);
    }

    function invariant_sinkHoldsExactlyWhatWasBurned() public view {
        assertEq(SINK.balance, hook.burned());
    }

    function invariant_feesOnlyGrowThroughSwaps() public view {
        assertEq(hook.totalFees(), handler.feesSeen());
    }

    function invariant_managerIsLockedBetweenCalls() public view {
        assertFalse(IPoolManager(address(manager)).isUnlocked());
    }
}
