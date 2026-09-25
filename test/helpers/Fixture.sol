// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TollToken} from "../../src/TollToken.sol";
import {TollgateHook} from "../../src/TollgateHook.sol";
import {HookFlags} from "../../src/HookFlags.sol";
import {TestRouter} from "./TestRouter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @dev Shared offline fixture: a fresh PoolManager, a settlement router, the TOLL token, the hook at
/// a mined CREATE2 address, an ETH/TOLL pool at price 1:1 with full-range liquidity, and a foreign
/// pool of two MockERC20s on the same hook.
abstract contract Fixture is Test {
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    int24 internal constant FULL_LOWER = -887_220;
    int24 internal constant FULL_UPPER = 887_220;
    int256 internal constant LIQUIDITY = 100_000 ether;
    uint256 internal constant BPS = 10_000;

    PoolManager internal manager;
    TestRouter internal router;
    TollToken internal token;
    TollgateHook internal hook;
    PoolKey internal ethKey;

    MockERC20 internal foreign0;
    MockERC20 internal foreign1;
    PoolKey internal foreignKey;

    receive() external payable {}

    function setUp() public virtual {
        manager = new PoolManager(address(this));
        router = new TestRouter(manager);
        token = new TollToken();
        hook = deployHook(manager, address(this));

        ethKey = PoolKey(
            CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(token)), 3000, 60, IHooks(address(hook))
        );
        manager.initialize(ethKey, SQRT_PRICE_1_1);
        token.approve(address(router), type(uint256).max);
        vm.deal(address(this), 10_000_000 ether);
        router.modify{value: 200_000 ether}(
            ethKey, ModifyLiquidityParams(FULL_LOWER, FULL_UPPER, LIQUIDITY, 0)
        );

        MockERC20 a = new MockERC20("A", "A", 1_000_000 ether);
        MockERC20 b = new MockERC20("B", "B", 1_000_000 ether);
        (foreign0, foreign1) = address(a) < address(b) ? (a, b) : (b, a);
        foreignKey = PoolKey(
            Currency.wrap(address(foreign0)),
            Currency.wrap(address(foreign1)),
            3000,
            60,
            IHooks(address(hook))
        );
        manager.initialize(foreignKey, SQRT_PRICE_1_1);
        foreign0.approve(address(router), type(uint256).max);
        foreign1.approve(address(router), type(uint256).max);
        router.modify(foreignKey, ModifyLiquidityParams(FULL_LOWER, FULL_UPPER, 100_000 ether, 0));
    }

    /// @dev Mines a CREATE2 salt from `deployer` until the address carries exactly 0x00CC.
    function mineSalt(IPoolManager atManager, address deployer)
        internal
        pure
        returns (bytes32 salt, address at)
    {
        bytes32 codeHash = keccak256(abi.encodePacked(type(TollgateHook).creationCode, abi.encode(atManager)));
        for (uint256 i; i < 500_000; ++i) {
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, bytes32(i), codeHash))))
            );
            if (HookFlags.matches(predicted, HookFlags.TOLLGATE)) return (bytes32(i), predicted);
        }
        revert("no salt");
    }

    function deployHook(IPoolManager atManager, address deployer) internal returns (TollgateHook deployed) {
        (bytes32 salt, address predicted) = mineSalt(atManager, deployer);
        deployed = new TollgateHook{salt: salt}(atManager);
        assertEq(address(deployed), predicted, "CREATE2 prediction");
    }

    function swapParams(bool zeroForOne, int256 amount) internal pure returns (SwapParams memory) {
        return SwapParams(
            zeroForOne, amount, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
    }

    /// @dev Swap on the ETH pool as `address(this)`, forwarding plenty of ETH; the router refunds.
    function ethSwap(bool zeroForOne, int256 amount) internal returns (int128 amount0, int128 amount1) {
        return ethSwap(swapParams(zeroForOne, amount));
    }

    function ethSwap(SwapParams memory params) internal returns (int128 amount0, int128 amount1) {
        uint256 value = params.zeroForOne ? 1_000_000 ether : 0;
        BalanceDelta delta = router.swap{value: value}(ethKey, params);
        return (delta.amount0(), delta.amount1());
    }

    /// @dev PoolManager wraps hook reverts: WrappedError(hook, callbackSelector, reason, HookCallFailed).
    function wrappedHookError(bytes4 callback, bytes4 reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            callback,
            abi.encodeWithSelector(reason),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function hookClaims() internal view returns (uint256) {
        return manager.balanceOf(address(hook), 0);
    }

    function fee2pct(uint256 amount) internal pure returns (uint256) {
        return amount * 200 / BPS;
    }
}
