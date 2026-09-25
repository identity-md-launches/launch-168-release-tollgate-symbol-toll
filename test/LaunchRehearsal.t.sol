// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {TollToken} from "../src/TollToken.sol";
import {TollgateHook} from "../src/TollgateHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {TestRouter} from "./helpers/TestRouter.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/// @notice Rehearses what the LaunchFactory does, offline: deploy the token (supply to the factory),
/// CREATE2 the hook at a mined salt, initialize the pool as the deployer, seed 80% of the supply as
/// one-sided token liquidity below the opening price, take the first buy into a pool that holds no
/// ETH, sell after a buy, then pay the creator and burn.
contract LaunchRehearsalTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /// @dev Opening price: 1 ETH = 1,000,000 TOLL, i.e. sqrt(1e6) * 2^96.
    uint160 internal constant OPEN_SQRT_PRICE = 1000 * 79228162514264337593543950336;
    uint256 internal constant SUPPLY = 1e27;
    uint256 internal constant SEED = SUPPLY * 80 / 100;
    int24 internal constant TICK_SPACING = 60;
    uint24 internal constant LP_FEE = 3000;
    address internal constant CREATOR = 0x70c6C4fcaAb11151FCEDb32eaaC3431547193A0a;
    address internal constant SINK = 0x000000000000000000000000000000000000dEaD;

    PoolManager internal manager;
    TestRouter internal router;
    TollToken internal token;
    TollgateHook internal hook;
    PoolKey internal key;
    int24 internal seedLower;
    int24 internal seedUpper;

    address internal trader = makeAddr("trader");

    receive() external payable {}

    function setUp() public {
        manager = new PoolManager(address(this));
        router = new TestRouter(manager);
        vm.deal(address(this), 1_000 ether);
        vm.deal(trader, 1_000 ether);
    }

    // ------------------------------------------------------------------------------------------
    // Factory steps.
    // ------------------------------------------------------------------------------------------

    function deployTokenAsFactory() internal {
        token = new TollToken();
        assertEq(token.balanceOf(address(this)), SUPPLY, "the factory holds the whole supply");
        assertEq(token.totalSupply(), SUPPLY);
    }

    function deployHookAtMinedSalt() internal {
        bytes memory creationCode = abi.encodePacked(type(TollgateHook).creationCode, abi.encode(manager));
        bytes32 initCodeHash = keccak256(creationCode);
        bytes32 salt;
        address predicted;
        for (uint256 i;; ++i) {
            predicted = address(
                uint160(
                    uint256(
                        keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(i), initCodeHash))
                    )
                )
            );
            if (HookFlags.matches(predicted, HookFlags.TOLLGATE)) {
                salt = bytes32(i);
                break;
            }
        }
        address at;
        assembly ("memory-safe") {
            at := create2(0, add(creationCode, 0x20), mload(creationCode), salt)
        }
        require(at != address(0), "hook deployment reverted");
        assertEq(at, predicted);
        assertEq(HookFlags.flagsOf(at), 0x00CC);
        hook = TollgateHook(payable(at));
    }

    function initializePoolAsDeployer() internal {
        key = PoolKey(
            CurrencyLibrary.ADDRESS_ZERO,
            Currency.wrap(address(token)),
            LP_FEE,
            TICK_SPACING,
            IHooks(address(hook))
        );
        int24 tick = manager.initialize(key, OPEN_SQRT_PRICE);
        (uint160 price, int24 tickAfter,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(price, OPEN_SQRT_PRICE);
        assertEq(tickAfter, tick);
    }

    /// @dev A range entirely at or below the current tick holds only currency1 (the token), so the
    /// seed needs no ETH. Buys (ETH in, token out) push the price down into the range.
    function seedEightyPercentBelowOpeningPrice() internal returns (uint256 seeded) {
        (, int24 tick,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        seedUpper = (tick / TICK_SPACING) * TICK_SPACING; // <= tick, aligned
        seedLower = seedUpper - TICK_SPACING * 2_000; // ~2000 spacings below: 1e6 TOLL/ETH -> ~6 TOLL/ETH
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(seedUpper);
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(seedLower);
        uint256 liquidity = FullMath.mulDiv(SEED, FixedPoint96.Q96, sqrtUpper - sqrtLower);

        token.approve(address(router), type(uint256).max);
        BalanceDelta d = router.modify(key, ModifyLiquidityParams(seedLower, seedUpper, int256(liquidity), 0));
        assertEq(d.amount0(), 0, "no ETH went into the seed");
        seeded = uint256(-int256(d.amount1()));
        assertLe(seeded, SEED, "never more than 80% of the supply");
        assertGe(seeded, SEED - 1e12, "80% up to rounding");
        assertEq(token.balanceOf(address(this)), SUPPLY - seeded, "the factory keeps the other 20%");
        assertEq(address(manager).balance, 0, "the pool holds no ETH before the first buy");
    }

    function swapParams(bool zeroForOne, int256 amount) internal pure returns (SwapParams memory) {
        return SwapParams(
            zeroForOne, amount, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
    }

    function launch() internal returns (uint256 seeded) {
        deployTokenAsFactory();
        deployHookAtMinedSalt();
        initializePoolAsDeployer();
        seeded = seedEightyPercentBelowOpeningPrice();
    }

    // ------------------------------------------------------------------------------------------
    // Rehearsal.
    // ------------------------------------------------------------------------------------------

    function test_seedRangeSitsBelowTheOpeningTick() public {
        launch();
        (, int24 tick,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertLe(seedUpper, tick);
        assertLt(seedLower, seedUpper);
        assertEq(
            IPoolManager(address(manager)).getLiquidity(key.toId()),
            0,
            "no liquidity in range at the opening price"
        );
    }

    function test_firstExactInBuyIntoEthlessPoolPaysTwoPercent() public {
        launch();
        uint256 tokensBefore = token.balanceOf(trader);
        vm.prank(trader);
        BalanceDelta d = router.swap{value: 1 ether}(key, swapParams(true, -1 ether));
        assertEq(d.amount0(), -1 ether);
        assertGt(d.amount1(), 0);
        assertEq(token.balanceOf(trader) - tokensBefore, uint256(int256(d.amount1())));
        assertEq(trader.balance, 999 ether);
        assertEq(address(manager).balance, 1 ether, "the whole ETH leg, fee included, sits in the manager");
        assertEq(manager.balanceOf(address(hook), 0), 0.02 ether);
        assertEq(hook.totalFees(), 0.02 ether);
        assertEq(hook.creatorDue(), 0.02 ether);
        assertEq(hook.burnable(), 0);
        // the raw pool leg was 0.98 ETH at ~1e6 TOLL/ETH minus the 0.30% LP fee and slippage
        assertLt(uint256(int256(d.amount1())), 980_000 ether);
        assertGt(uint256(int256(d.amount1())), 950_000 ether);
    }

    function test_firstExactOutBuyIntoEthlessPoolPaysTwoPercent() public {
        launch();
        vm.prank(trader);
        BalanceDelta d = router.swap{value: 10 ether}(key, swapParams(true, 500_000 ether));
        assertEq(d.amount1(), 500_000 ether);
        uint256 paid = uint256(-int256(d.amount0()));
        uint256 fee = hook.totalFees();
        assertEq(fee, (paid - fee) * 200 / 10_000, "fee is 2% of the raw ETH leg");
        assertEq(manager.balanceOf(address(hook), 0), fee);
        assertEq(trader.balance, 1_000 ether - paid);
        assertEq(address(manager).balance, paid);
    }

    function test_sellAfterABuyPaysTwoPercentOfTheEthOut() public {
        launch();
        vm.startPrank(trader);
        BalanceDelta buy = router.swap{value: 2 ether}(key, swapParams(true, -2 ether));
        uint256 bought = uint256(int256(buy.amount1()));
        token.approve(address(router), type(uint256).max);

        uint256 feesBefore = hook.totalFees();
        uint256 ethBefore = trader.balance;
        BalanceDelta sell = router.swap(key, swapParams(false, -int256(bought / 2)));
        vm.stopPrank();

        assertEq(sell.amount1(), -int256(bought / 2));
        uint256 received = uint256(int256(sell.amount0()));
        uint256 fee = hook.totalFees() - feesBefore;
        assertEq(trader.balance - ethBefore, received);
        assertEq(fee, (received + fee) * 200 / 10_000, "fee is 2% of the raw ETH out");
        assertGt(received, 0.9 ether, "half the tokens come back as roughly half the ETH");
        assertLt(received, 1 ether);

        // exact-out sell: the trader names the ETH it wants and pays 2% on top in tokens' worth of ETH
        feesBefore = hook.totalFees();
        vm.prank(trader);
        BalanceDelta exactOut = router.swap(key, swapParams(false, 0.1 ether));
        assertEq(exactOut.amount0(), 0.1 ether);
        assertEq(hook.totalFees() - feesBefore, 0.002 ether);
    }

    function test_fullRehearsalThroughCapPayoutAndBurn() public {
        uint256 seeded = launch();

        // First buy, then a series of buys until 1 ETH of fees has accrued.
        vm.startPrank(trader);
        vm.recordLogs();
        uint256 buys;
        while (hook.totalFees() < 1 ether) {
            router.swap{value: 10 ether}(key, swapParams(true, -10 ether));
            ++buys;
        }
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 capEvents;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == TollgateHook.CapReached.selector) {
                ++capEvents;
            }
        }
        vm.stopPrank();
        assertEq(buys, 5, "5 buys of 10 ETH at 2% = 1 ETH");
        assertEq(capEvents, 1, "CapReached fired exactly once");
        assertEq(hook.totalFees(), 1 ether);
        assertEq(hook.capReachedBlock(), block.number);

        // Anyone pays the creator; the creator can never get more than 1 ETH.
        hook.payCreator();
        assertEq(CREATOR.balance, 1 ether);
        vm.expectRevert(TollgateHook.NothingDue.selector);
        hook.payCreator();

        // Nothing is burnable yet; a sell after the buys makes some.
        vm.roll(block.number + 5);
        vm.expectRevert(TollgateHook.NothingToBurn.selector);
        hook.burnEth();

        vm.startPrank(trader);
        token.approve(address(router), type(uint256).max);
        router.swap(key, swapParams(false, -int256(token.balanceOf(trader) / 2)));
        vm.stopPrank();
        uint256 burnable = hook.burnable();
        assertGt(burnable, 0.01 ether);
        hook.burnEth();
        assertEq(SINK.balance, burnable);
        assertEq(hook.burnable(), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0, "everything charged has been paid or burned");
        assertEq(hook.creatorPaid(), 1 ether);

        // The factory still holds what it did not seed, and the seed is where the pool is.
        assertEq(token.balanceOf(address(this)), SUPPLY - seeded);
        assertGe(address(manager).balance, 0);
    }
}
