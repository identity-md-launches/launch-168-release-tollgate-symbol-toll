// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {Fixture} from "./helpers/Fixture.sol";
import {Opcodes} from "./helpers/Opcodes.sol";
import {TestRouter} from "./helpers/TestRouter.sol";
import {TollgateHook} from "../src/TollgateHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";

/// @dev Contract etched at CREATOR to probe reentrancy through the ETH payout.
contract ReentrantReceiver {
    TollgateHook internal immutable hook;
    uint256 internal immutable mode;

    constructor(TollgateHook hook_, uint256 mode_) {
        hook = hook_;
        mode = mode_;
    }

    receive() external payable {
        if (mode == 1) hook.payCreator();
        if (mode == 2) hook.burnEth();
    }
}

/// @dev A "router" that tries to burn from inside its own unlock, i.e. inside a swap transaction.
contract BurnInsideUnlock is IUnlockCallback {
    IPoolManager internal immutable manager;
    TollgateHook internal immutable hook;

    constructor(IPoolManager manager_, TollgateHook hook_) {
        manager = manager_;
        hook = hook_;
    }

    function run() external {
        manager.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        hook.burnEth();
        return "";
    }
}

contract TollgateHookTest is Fixture {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    address internal alice = makeAddr("alice");
    address internal constant CREATOR = 0x70c6C4fcaAb11151FCEDb32eaaC3431547193A0a;
    address internal constant SINK = 0x000000000000000000000000000000000000dEaD;

    // ------------------------------------------------------------------------------------------
    // Shape: permissions, constants, constructor.
    // ------------------------------------------------------------------------------------------

    function test_permissionsAreExactlyTheFourSwapFlags() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeSwap && p.afterSwap && p.beforeSwapReturnDelta && p.afterSwapReturnDelta);
        assertFalse(p.beforeInitialize, "no initialize gate");
        assertFalse(p.afterInitialize);
        assertFalse(p.beforeAddLiquidity);
        assertFalse(p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity);
        assertFalse(p.afterRemoveLiquidity);
        assertFalse(p.beforeDonate);
        assertFalse(p.afterDonate);
        assertFalse(p.afterAddLiquidityReturnDelta);
        assertFalse(p.afterRemoveLiquidityReturnDelta);
        assertEq(HookFlags.TOLLGATE, 0x00CC);
        assertEq(HookFlags.flagsOf(address(hook)), 0x00CC);
        Hooks.validateHookPermissions(IHooks(address(hook)), p);
    }

    function test_constantsAreTheSpecifiedOnes() public view {
        assertEq(hook.BUY_FEE_BPS(), 200);
        assertEq(hook.SELL_FEE_BPS(), 200);
        assertEq(hook.CREATOR_CAP(), 1 ether);
        assertEq(hook.CREATOR(), CREATOR);
        assertEq(hook.BURN_SINK(), SINK);
        assertEq(hook.MIN_BURN(), 0.01 ether);
        assertEq(hook.MIN_BLOCKS_BETWEEN_BURNS(), 5);
        assertEq(hook.ETH_CLAIM_ID(), 0);
        assertEq(address(hook.poolManager()), address(manager));
    }

    function test_ledgerStartsEmptyAndCoolingDown() public view {
        assertEq(hook.totalFees(), 0);
        assertEq(hook.creatorPaid(), 0);
        assertEq(hook.burned(), 0);
        assertEq(hook.capReachedBlock(), 0);
        assertEq(hook.lastBurnBlock(), block.number);
        assertEq(hook.creatorEntitlement(), 0);
        assertEq(hook.creatorDue(), 0);
        assertEq(hook.burnable(), 0);
        assertTrue(hook.burnCoolingDown());
        assertEq(hookClaims(), 0);
    }

    function test_constructorRejectsTheZeroManager() public {
        vm.expectRevert(TollgateHook.InvalidPoolManager.selector);
        new TollgateHook(IPoolManager(address(0)));
    }

    /// @dev The admission floor hands over creation code with the manager baked in and may deploy
    /// the hook before any code exists at that address, so the constructor must not require code.
    function test_constructorAcceptsAManagerAddressWithoutCodeYet() public {
        IPoolManager future = IPoolManager(address(0x000000000004444c5dc75cB358380D2e3dE08A90));
        (bytes32 salt,) = mineSalt(future, address(this));
        TollgateHook early = new TollgateHook{salt: salt}(future);
        assertEq(address(early.poolManager()), address(future));
        assertEq(HookFlags.flagsOf(address(early)), 0x00CC);
    }

    function test_constructorRejectsAddressWithoutTheFlags() public {
        bytes32 hash = keccak256(abi.encodePacked(type(TollgateHook).creationCode, abi.encode(manager)));
        for (uint256 i;; ++i) {
            address at = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(i), hash))))
            );
            if (HookFlags.matches(at, HookFlags.TOLLGATE)) continue;
            vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, at));
            new TollgateHook{salt: bytes32(i)}(manager);
            break;
        }
    }

    function test_runtimeCodeHasNoEscapeHatch() public view {
        Opcodes.assertNoEscapeHatch(address(hook).code);
        Opcodes.assertNoEscapeHatch(address(token).code);
    }

    // ------------------------------------------------------------------------------------------
    // Access.
    // ------------------------------------------------------------------------------------------

    function test_callbacksRefuseCallersOtherThanThePoolManager() public {
        SwapParams memory params = swapParams(true, -1 ether);
        vm.expectRevert(TollgateHook.OnlyPoolManager.selector);
        hook.beforeSwap(address(this), ethKey, params, "");
        vm.expectRevert(TollgateHook.OnlyPoolManager.selector);
        hook.afterSwap(address(this), ethKey, params, toBalanceDelta(-1 ether, 1 ether), "");
        vm.expectRevert(TollgateHook.OnlyPoolManager.selector);
        hook.unlockCallback(abi.encode(alice, 1 ether));
    }

    function test_unlockCallbackRefusesWhenNoPayoutIsInFlight() public {
        vm.prank(address(manager));
        vm.expectRevert(TollgateHook.UnexpectedCallback.selector);
        hook.unlockCallback(abi.encode(alice, 1 ether));
    }

    function test_beforeSwapReturnsTheFeeOnlyWhenEthIsSpecified() public {
        // exact-in buy: ETH specified
        vm.prank(address(manager));
        (bytes4 sel, BeforeSwapDelta d, uint24 lpFee) =
            hook.beforeSwap(alice, ethKey, swapParams(true, -1 ether), "");
        assertEq(sel, IHooks.beforeSwap.selector);
        assertEq(d.getSpecifiedDelta(), 0.02 ether);
        assertEq(d.getUnspecifiedDelta(), 0);
        assertEq(lpFee, 0);
        // exact-out sell: ETH specified
        vm.prank(address(manager));
        (, d,) = hook.beforeSwap(alice, ethKey, swapParams(false, 1 ether), "");
        assertEq(d.getSpecifiedDelta(), 0.02 ether);
        // exact-out buy and exact-in sell: token specified, fee comes later
        vm.prank(address(manager));
        (, d,) = hook.beforeSwap(alice, ethKey, swapParams(true, 1 ether), "");
        assertEq(BeforeSwapDelta.unwrap(d), 0);
        vm.prank(address(manager));
        (, d,) = hook.beforeSwap(alice, ethKey, swapParams(false, -1 ether), "");
        assertEq(BeforeSwapDelta.unwrap(d), 0);
        // foreign pool: never
        vm.prank(address(manager));
        (, d,) = hook.beforeSwap(alice, foreignKey, swapParams(true, -1 ether), "");
        assertEq(BeforeSwapDelta.unwrap(d), 0);
        assertEq(hook.totalFees(), 0, "beforeSwap never touches the ledger");
    }

    function test_afterSwapRejectsPartialFillBeforeTouchingTheLedger() public {
        SwapParams memory exactInBuy = swapParams(true, -1 ether);
        // raw delta must be amountSpecified + fee = -0.98 ether on the ETH side
        vm.prank(address(manager));
        vm.expectRevert(TollgateHook.PartialFill.selector);
        hook.afterSwap(alice, ethKey, exactInBuy, toBalanceDelta(-0.97 ether, 1 ether), "");
        SwapParams memory exactOutBuy = swapParams(true, 1 ether);
        vm.prank(address(manager));
        vm.expectRevert(TollgateHook.PartialFill.selector);
        hook.afterSwap(alice, ethKey, exactOutBuy, toBalanceDelta(-1 ether, 0.99 ether), "");
        assertEq(hook.totalFees(), 0);
    }

    // ------------------------------------------------------------------------------------------
    // The four directions. The foreign pool is an identical pool without the fee, so it quotes
    // the raw AMM leg the hook's numbers must be derived from.
    // ------------------------------------------------------------------------------------------

    function test_exactInBuyTakesTwoPercentOfEthInBeforeSwap() public {
        uint256 amount = 10 ether;
        uint256 fee = fee2pct(amount);
        uint256 ethBefore = address(this).balance;
        uint256 managerBefore = address(manager).balance;
        uint256 tokensBefore = token.balanceOf(address(this));

        (int128 a0, int128 a1) = ethSwap(true, -int256(amount));
        BalanceDelta raw = router.swap(foreignKey, swapParams(true, -int256(amount - fee)));

        assertEq(a0, -int256(amount), "user pays exactly the amount specified");
        assertEq(a1, raw.amount1(), "pool traded amount - fee");
        assertEq(ethBefore - address(this).balance, amount);
        assertEq(token.balanceOf(address(this)) - tokensBefore, uint256(int256(a1)));
        assertEq(address(manager).balance - managerBefore, amount, "fee stays inside the manager");
        assertEq(hookClaims(), fee, "fee held as ERC-6909 claims on id 0");
        assertEq(hook.totalFees(), fee);
        assertEq(hook.creatorDue(), fee);
        assertEq(hook.burnable(), 0);
    }

    function test_exactOutBuyTakesTwoPercentOfEthInAfterSwap() public {
        uint256 amount = 10 ether; // tokens out
        uint256 tokensBefore = token.balanceOf(address(this));

        (int128 a0, int128 a1) = ethSwap(true, int256(amount));
        BalanceDelta raw = router.swap(foreignKey, swapParams(true, int256(amount)));

        uint256 rawEth = uint256(-int256(raw.amount0()));
        uint256 fee = fee2pct(rawEth);
        assertEq(a1, int256(amount), "user receives exactly the tokens specified");
        assertEq(uint256(-int256(a0)), rawEth + fee, "user pays raw ETH input plus 2%");
        assertEq(token.balanceOf(address(this)) - tokensBefore, amount);
        assertEq(hookClaims(), fee);
        assertEq(hook.totalFees(), fee);
    }

    function test_exactInSellTakesTwoPercentOfEthInAfterSwap() public {
        uint256 amount = 10 ether; // tokens in
        uint256 ethBefore = address(this).balance;

        (int128 a0, int128 a1) = ethSwap(false, -int256(amount));
        BalanceDelta raw = router.swap(foreignKey, swapParams(false, -int256(amount)));

        uint256 rawEth = uint256(int256(raw.amount0()));
        uint256 fee = fee2pct(rawEth);
        assertEq(a1, -int256(amount), "user pays exactly the tokens specified");
        assertEq(uint256(int256(a0)), rawEth - fee, "user receives raw ETH output minus 2%");
        assertEq(address(this).balance - ethBefore, rawEth - fee);
        assertEq(hookClaims(), fee);
        assertEq(hook.totalFees(), fee);
    }

    function test_exactOutSellTakesTwoPercentOfEthInBeforeSwap() public {
        uint256 amount = 10 ether; // ETH out
        uint256 fee = fee2pct(amount);
        uint256 ethBefore = address(this).balance;

        (int128 a0, int128 a1) = ethSwap(false, int256(amount));
        BalanceDelta raw = router.swap(foreignKey, swapParams(false, int256(amount + fee)));

        assertEq(a0, int256(amount), "user receives exactly the ETH specified");
        assertEq(a1, raw.amount1(), "pool produced amount + fee, so the token cost matches");
        assertEq(address(this).balance - ethBefore, amount);
        assertEq(hookClaims(), fee);
        assertEq(hook.totalFees(), fee);
    }

    function testFuzz_feeIsTwoPercentOfTheEthLegInEveryDirection(uint96 size, bool zeroForOne, bool exactIn)
        public
    {
        uint256 amount = bound(uint256(size), 0.001 ether, 1_000 ether);
        int256 specified = exactIn ? -int256(amount) : int256(amount);
        uint256 claimsBefore = hookClaims();

        (int128 a0, int128 a1) = ethSwap(zeroForOne, specified);
        uint256 fee = hook.totalFees();
        assertEq(hookClaims() - claimsBefore, fee, "claims track totalFees");

        if (exactIn == zeroForOne) {
            // ETH specified: fee is 2% of amountSpecified, user side of ETH equals amountSpecified.
            assertEq(fee, fee2pct(amount));
            assertEq(a0, specified);
            int256 rawSpecified = exactIn ? -int256(amount - fee) : int256(amount + fee);
            BalanceDelta raw = router.swap(foreignKey, swapParams(zeroForOne, rawSpecified));
            assertEq(a1, raw.amount1(), "token leg equals the raw pool leg of amount -/+ fee");
        } else {
            // token specified: fee is 2% of the ETH the pool moved.
            assertEq(a1, specified);
            BalanceDelta raw = router.swap(foreignKey, swapParams(zeroForOne, specified));
            int256 rawEth = int256(raw.amount0());
            uint256 rawMagnitude = uint256(rawEth < 0 ? -rawEth : rawEth);
            assertEq(fee, fee2pct(rawMagnitude));
            assertEq(int256(a0), rawEth < 0 ? rawEth - int256(fee) : rawEth - int256(fee));
        }
        assertEq(address(this).balance + address(manager).balance, 10_000_000 ether, "ETH conserved");
    }

    function test_dustBelowFiftyWeiPaysNoFeeButStillTrades() public {
        (int128 a0,) = ethSwap(true, -49);
        assertEq(a0, -49);
        assertEq(hook.totalFees(), 0);
        (a0,) = ethSwap(true, -50);
        assertEq(a0, -50);
        assertEq(hook.totalFees(), 1);
    }

    function test_partialFillsRevertInAllFourModes() public {
        (uint160 price,,,) = IPoolManager(address(manager)).getSlot0(ethKey.toId());
        for (uint256 i; i < 4; ++i) {
            bool zeroForOne = i % 2 == 0;
            SwapParams memory params = SwapParams(
                zeroForOne, i < 2 ? int256(-1 ether) : int256(1 ether), zeroForOne ? price - 1 : price + 1
            );
            vm.expectRevert(wrappedHookError(IHooks.afterSwap.selector, TollgateHook.PartialFill.selector));
            router.swap{value: zeroForOne ? 2 ether : 0}(ethKey, params);
        }
        assertEq(hook.totalFees(), 0);
        assertEq(hookClaims(), 0);
    }

    function test_swapAgainstAnEmptyPoolRevertsPartialFill() public {
        router.modify(ethKey, ModifyLiquidityParams(FULL_LOWER, FULL_UPPER, -LIQUIDITY, 0));
        assertEq(IPoolManager(address(manager)).getLiquidity(ethKey.toId()), 0);
        vm.expectRevert(wrappedHookError(IHooks.afterSwap.selector, TollgateHook.PartialFill.selector));
        router.swap{value: 2 ether}(ethKey, swapParams(true, -1 ether));
    }

    function test_foreignPoolTradesFeeFreeInAllFourModes() public {
        uint256 hookF0 = foreign0.balanceOf(address(hook));
        for (uint256 i; i < 4; ++i) {
            bool zeroForOne = i % 2 == 0;
            int256 specified = i < 2 ? int256(-1 ether) : int256(1 ether);
            BalanceDelta d = router.swap(foreignKey, swapParams(zeroForOne, specified));
            int128 specifiedDelta = (specified < 0) == zeroForOne ? d.amount0() : d.amount1();
            assertEq(int256(specifiedDelta), specified, "specified leg untouched");
        }
        assertEq(hook.totalFees(), 0);
        assertEq(hookClaims(), 0);
        assertEq(manager.balanceOf(address(hook), uint160(address(foreign0))), 0);
        assertEq(manager.balanceOf(address(hook), uint160(address(foreign1))), 0);
        assertEq(foreign0.balanceOf(address(hook)), hookF0);
    }

    function test_liquidityCanAlwaysBeRemoved() public {
        ethSwap(true, -10 ether);
        ethSwap(false, -5 ether);
        BalanceDelta d = router.modify(ethKey, ModifyLiquidityParams(FULL_LOWER, FULL_UPPER, -LIQUIDITY, 0));
        assertGt(d.amount0(), 0);
        assertGt(d.amount1(), 0);
        assertEq(IPoolManager(address(manager)).getLiquidity(ethKey.toId()), 0);
        assertGe(address(manager).balance, hookClaims(), "the hook's claims are still backed");
    }

    // ------------------------------------------------------------------------------------------
    // Cap.
    // ------------------------------------------------------------------------------------------

    function accrue(uint256 fees) internal {
        // exact-in buys pay exactly 2% of the amount, so amount = fees * 50.
        ethSwap(true, -int256(fees * 50));
    }

    function test_capReachedEmittedExactlyOnceInTheCrossingSwap() public {
        accrue(0.8 ether);
        assertEq(hook.totalFees(), 0.8 ether);
        assertEq(hook.capReachedBlock(), 0);

        vm.expectEmit(true, true, true, true, address(hook));
        emit TollgateHook.CapReached(1 ether, block.number);
        accrue(0.2 ether);
        assertEq(hook.totalFees(), 1 ether);
        assertEq(hook.capReachedBlock(), block.number);
        assertEq(hook.creatorEntitlement(), 1 ether);
        assertEq(hook.burnable(), 0, "exactly at the cap nothing is burnable yet");

        vm.recordLogs();
        accrue(0.3 ether);
        accrue(0.3 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != TollgateHook.CapReached.selector, "CapReached fired twice");
        }
        assertEq(hook.totalFees(), 1.6 ether);
        assertEq(hook.creatorEntitlement(), 1 ether);
        assertEq(hook.burnable(), 0.6 ether);
    }

    function test_capReachedCarriesTheOvershootingTotal() public {
        accrue(0.8 ether);
        vm.roll(block.number + 3);
        vm.expectEmit(true, true, true, true, address(hook));
        emit TollgateHook.CapReached(1.2 ether, block.number);
        accrue(0.4 ether);
        assertEq(hook.capReachedBlock(), block.number);
        assertEq(hook.burnable(), 0.2 ether);
    }

    // ------------------------------------------------------------------------------------------
    // payCreator.
    // ------------------------------------------------------------------------------------------

    function test_payCreatorRevertsNothingDueWhenNothingAccrued() public {
        vm.expectRevert(TollgateHook.NothingDue.selector);
        hook.payCreator();
    }

    function test_payCreatorPaysExactlyWhatIsDueToTheCreatorOnly() public {
        accrue(0.2 ether);
        uint256 aliceBefore = alice.balance;
        vm.expectEmit(true, true, true, true, address(hook));
        emit TollgateHook.CreatorPaid(0.2 ether, 0.2 ether);
        vm.prank(alice);
        hook.payCreator();
        assertEq(CREATOR.balance, 0.2 ether);
        assertEq(alice.balance, aliceBefore, "the caller gets nothing");
        assertEq(hook.creatorPaid(), 0.2 ether);
        assertEq(hook.creatorDue(), 0);
        assertEq(hookClaims(), 0);
        vm.expectRevert(TollgateHook.NothingDue.selector);
        hook.payCreator();

        accrue(0.3 ether);
        hook.payCreator();
        assertEq(CREATOR.balance, 0.5 ether);
        assertEq(hook.creatorPaid(), 0.5 ether);
    }

    function test_payCreatorNeverPaysMoreThanOneEtherInTotal() public {
        accrue(0.4 ether);
        hook.payCreator();
        accrue(1.1 ether); // totalFees 1.5, cap crossed
        hook.payCreator();
        assertEq(CREATOR.balance, 1 ether);
        assertEq(hook.creatorPaid(), 1 ether);
        accrue(0.5 ether);
        vm.expectRevert(TollgateHook.NothingDue.selector);
        hook.payCreator();
        assertEq(hook.creatorPaid(), 1 ether);
        assertEq(hook.burnable(), 1 ether);
        assertEq(hookClaims(), 1 ether, "everything left is burnable");
    }

    function testFuzz_creatorPaidNeverExceedsCap(uint96[6] memory sizes) public {
        for (uint256 i; i < sizes.length; ++i) {
            uint256 amount = bound(uint256(sizes[i]), 0.01 ether, 40 ether);
            ethSwap(true, -int256(amount));
            if (hook.creatorDue() != 0) hook.payCreator();
            assertLe(hook.creatorPaid(), 1 ether);
            assertEq(CREATOR.balance, hook.creatorPaid());
            assertEq(hookClaims(), hook.totalFees() - hook.creatorPaid() - hook.burned());
        }
    }

    // ------------------------------------------------------------------------------------------
    // burnEth.
    // ------------------------------------------------------------------------------------------

    function test_burnEthCooldownStartsAtDeployment() public {
        uint256 deployBlock = hook.lastBurnBlock();
        vm.expectRevert(TollgateHook.TooSoon.selector);
        hook.burnEth();
        vm.roll(deployBlock + 4);
        vm.expectRevert(TollgateHook.TooSoon.selector);
        hook.burnEth();
        vm.roll(deployBlock + 5);
        assertFalse(hook.burnCoolingDown());
        vm.expectRevert(TollgateHook.NothingToBurn.selector);
        hook.burnEth();
    }

    function test_burnEthRevertsNothingToBurnBeforeTheCap() public {
        accrue(0.9 ether);
        vm.roll(block.number + 5);
        assertEq(hook.burnable(), 0);
        vm.expectRevert(TollgateHook.NothingToBurn.selector);
        hook.burnEth();
    }

    function test_burnEthRevertsNothingToBurnBelowMinBurn() public {
        accrue(1.005 ether);
        vm.roll(block.number + 5);
        assertEq(hook.burnable(), 0.005 ether);
        vm.expectRevert(TollgateHook.NothingToBurn.selector);
        hook.burnEth();
        accrue(0.005 ether);
        assertEq(hook.burnable(), 0.01 ether);
        hook.burnEth();
        assertEq(SINK.balance, 0.01 ether);
    }

    function test_burnEthSendsExactlyTheBurnableAmountToTheSink() public {
        accrue(1.5 ether);
        vm.roll(block.number + 5);
        uint256 aliceBefore = alice.balance;
        vm.expectEmit(true, true, true, true, address(hook));
        emit TollgateHook.EthBurned(0.5 ether, 0.5 ether);
        vm.prank(alice);
        hook.burnEth();
        assertEq(SINK.balance, 0.5 ether);
        assertEq(alice.balance, aliceBefore);
        assertEq(hook.burned(), 0.5 ether);
        assertEq(hook.burnable(), 0);
        assertEq(hook.lastBurnBlock(), block.number);
        assertEq(hookClaims(), 1 ether, "the creator's entitlement is untouched");
        assertEq(hook.creatorDue(), 1 ether);

        vm.expectRevert(TollgateHook.TooSoon.selector);
        hook.burnEth();
        vm.roll(block.number + 5);
        vm.expectRevert(TollgateHook.NothingToBurn.selector);
        hook.burnEth();

        accrue(0.2 ether);
        hook.burnEth();
        assertEq(SINK.balance, 0.7 ether);
        assertEq(hook.burned(), 0.7 ether);

        hook.payCreator();
        assertEq(CREATOR.balance, 1 ether);
        assertEq(hookClaims(), 0);
    }

    function test_burnEthCannotRunInsideAnotherUnlock() public {
        accrue(1.5 ether);
        vm.roll(block.number + 5);
        BurnInsideUnlock attacker = new BurnInsideUnlock(manager, hook);
        vm.expectRevert(IPoolManager.AlreadyUnlocked.selector);
        attacker.run();
        assertEq(hook.burned(), 0);
        assertEq(SINK.balance, 0);
    }

    // ------------------------------------------------------------------------------------------
    // Donated claims: they raise the hook's balance, never the ledger, and are stuck.
    // ------------------------------------------------------------------------------------------

    function donateClaims(address from, uint256 amount) internal {
        vm.deal(from, from.balance + amount);
        vm.startPrank(from);
        router.mintEthClaims{value: amount}();
        manager.transfer(address(hook), 0, amount);
        vm.stopPrank();
    }

    function test_donatedClaimsDoNotChangeTheLedgerAndStayStuck() public {
        donateClaims(alice, 1 ether);
        assertEq(hookClaims(), 1 ether);
        assertEq(hook.totalFees(), 0);
        assertEq(hook.creatorDue(), 0);
        assertEq(hook.burnable(), 0);
        vm.expectRevert(TollgateHook.NothingDue.selector);
        hook.payCreator();
        vm.roll(block.number + 5);
        vm.expectRevert(TollgateHook.NothingToBurn.selector);
        hook.burnEth();

        accrue(1.5 ether);
        hook.payCreator();
        hook.burnEth();
        assertEq(CREATOR.balance, 1 ether);
        assertEq(SINK.balance, 0.5 ether);
        assertEq(hookClaims(), 1 ether, "the donation is still there and nothing can move it");
        assertGe(hookClaims(), hook.totalFees() - hook.creatorPaid() - hook.burned());
    }

    // ------------------------------------------------------------------------------------------
    // Reentrancy through the ETH payout.
    // ------------------------------------------------------------------------------------------

    function etchCreator(uint256 mode) internal {
        vm.etch(CREATOR, address(new ReentrantReceiver(hook, mode)).code);
    }

    function test_creatorContractThatDoesNotReenterIsPaid() public {
        etchCreator(0);
        accrue(0.5 ether);
        hook.payCreator();
        assertEq(CREATOR.balance, 0.5 ether);
    }

    function test_reenteringPayCreatorFromTheCreatorReverts() public {
        etchCreator(1);
        accrue(0.5 ether);
        vm.expectRevert();
        hook.payCreator();
        assertEq(hook.creatorPaid(), 0);
        assertEq(CREATOR.balance, 0);
        assertEq(hookClaims(), 0.5 ether);
    }

    function test_reenteringBurnEthFromTheCreatorReverts() public {
        etchCreator(2);
        accrue(1.5 ether);
        vm.roll(block.number + 5);
        vm.expectRevert();
        hook.payCreator();
        assertEq(hook.creatorPaid(), 0);
        assertEq(hook.burned(), 0);
        assertEq(hookClaims(), 1.5 ether);
    }

    function test_directReentrancyProbeOnCallbacksIsRefused() public {
        // Simulate the lock being held: unlockCallback is the only path that observes it directly.
        etchCreator(1);
        accrue(0.5 ether);
        // The receive() above re-enters payCreator, which must see the lock and revert Reentrancy.
        // A revert inside the payout bubbles up as a wrapped NativeTransferFailed, so we only assert
        // the state stayed put; the explicit selector is checked by the wrapped reason below.
        (bool ok, bytes memory data) = address(hook).call(abi.encodeCall(hook.payCreator, ()));
        assertFalse(ok);
        assertTrue(contains(data, TollgateHook.Reentrancy.selector), "inner revert is Reentrancy");
    }

    function contains(bytes memory haystack, bytes4 needle) internal pure returns (bool) {
        for (uint256 i; i + 4 <= haystack.length; ++i) {
            if (
                bytes4(
                        uint32(uint8(haystack[i])) << 24 | uint32(uint8(haystack[i + 1])) << 16
                            | uint32(uint8(haystack[i + 2])) << 8 | uint32(uint8(haystack[i + 3]))
                    ) == needle
            ) return true;
        }
        return false;
    }

    // ------------------------------------------------------------------------------------------
    // Sender identity: the hook does not care who routes.
    // ------------------------------------------------------------------------------------------

    function test_anyRouterAndAnyCallerPaysTheSameFee() public {
        TestRouter other = new TestRouter(manager);
        vm.deal(alice, 100 ether);
        vm.prank(alice);
        BalanceDelta d = other.swap{value: 10 ether}(ethKey, swapParams(true, -10 ether));
        assertEq(d.amount0(), -10 ether);
        assertEq(hook.totalFees(), 0.2 ether);
        assertEq(alice.balance, 90 ether);
    }
}
