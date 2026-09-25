// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

interface IERC20Minimal {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @dev Local test harness only. Settles every delta on behalf of `msg.sender` (ETH from the value
/// sent along, tokens via transferFrom) and refunds leftover ETH. No slippage or deadline checks.
contract TestRouter is IUnlockCallback {
    IPoolManager public immutable manager;

    uint8 private constant OP_SWAP = 0;
    uint8 private constant OP_MODIFY = 1;
    uint8 private constant OP_MINT_CLAIMS = 2;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    receive() external payable {}

    function modify(PoolKey memory key, ModifyLiquidityParams memory params)
        external
        payable
        returns (BalanceDelta)
    {
        return _unlock(abi.encode(OP_MODIFY, msg.sender, key, abi.encode(params)));
    }

    function swap(PoolKey memory key, SwapParams memory params) external payable returns (BalanceDelta) {
        return _unlock(abi.encode(OP_SWAP, msg.sender, key, abi.encode(params)));
    }

    /// @dev Deposits `msg.value` of native ETH and mints ERC-6909 claims (id 0) to the caller. Lets a
    /// test actor obtain claims it can then transfer to the hook ("claim donation").
    function mintEthClaims() external payable {
        PoolKey memory empty;
        _unlock(abi.encode(OP_MINT_CLAIMS, msg.sender, empty, abi.encode(msg.value)));
    }

    function _unlock(bytes memory data) private returns (BalanceDelta delta) {
        bytes memory result = manager.unlock(data);
        if (result.length != 0) delta = abi.decode(result, (BalanceDelta));
        if (address(this).balance != 0) {
            (bool ok,) = msg.sender.call{value: address(this).balance}("");
            require(ok, "refund failed");
        }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        (uint8 operation, address payer, PoolKey memory key, bytes memory args) =
            abi.decode(data, (uint8, address, PoolKey, bytes));
        if (operation == OP_MINT_CLAIMS) {
            uint256 amount = abi.decode(args, (uint256));
            manager.mint(payer, 0, amount);
            manager.settle{value: amount}();
            return "";
        }
        BalanceDelta delta;
        if (operation == OP_MODIFY) {
            (delta,) = manager.modifyLiquidity(key, abi.decode(args, (ModifyLiquidityParams)), "");
        } else {
            delta = manager.swap(key, abi.decode(args, (SwapParams)), "");
        }
        _settle(key.currency0, payer, delta.amount0());
        _settle(key.currency1, payer, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency currency, address payer, int128 delta) private {
        if (delta > 0) {
            manager.take(currency, payer, uint256(int256(delta)));
        } else if (delta < 0) {
            uint256 amount = uint256(-int256(delta));
            if (Currency.unwrap(currency) == address(0)) {
                manager.settle{value: amount}();
            } else {
                manager.sync(currency);
                require(
                    IERC20Minimal(Currency.unwrap(currency)).transferFrom(payer, address(manager), amount)
                );
                manager.settle();
            }
        }
    }
}
