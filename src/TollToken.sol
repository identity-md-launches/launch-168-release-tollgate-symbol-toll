// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title TollToken (TOLLGATE, symbol TOLL)
/// @notice Self-contained, fixed-supply ERC-20 for the TOLLGATE rehearsal launch.
/// @dev The zero-argument constructor mints exactly 1e27 base units (1,000,000,000 tokens at 18
/// decimals) to `msg.sender`, which is the LaunchFactory. There is no owner, no mint function, no
/// pause, no blocklist, no proxy and no transfer fee. Holders may destroy their own tokens with
/// `burn` and `burnFrom`; supply can only ever go down. The contract does not import anything, so
/// the deployed bytecode is exactly what this file describes.
contract TollToken {
    string public constant name = "TOLLGATE";
    string public constant symbol = "TOLL";
    uint8 public constant decimals = 18;

    /// @notice The whole supply, minted once in the constructor. Never 1e24: 1e27 exactly.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 ether;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error InsufficientBalance();
    error InsufficientAllowance();
    error ZeroAddress();

    constructor() {
        totalSupply = INITIAL_SUPPLY;
        balanceOf[msg.sender] = INITIAL_SUPPLY;
        emit Transfer(address(0), msg.sender, INITIAL_SUPPLY);
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        _spendAllowance(from, msg.sender, value);
        _transfer(from, to, value);
        return true;
    }

    /// @notice Destroys `value` of the caller's tokens and lowers `totalSupply`.
    function burn(uint256 value) external {
        _burn(msg.sender, value);
    }

    /// @notice Destroys `value` of `from`'s tokens using the caller's allowance.
    function burnFrom(address from, uint256 value) external {
        _spendAllowance(from, msg.sender, value);
        _burn(from, value);
    }

    function _transfer(address from, address to, uint256 value) private {
        if (to == address(0)) revert ZeroAddress();
        uint256 fromBalance = balanceOf[from];
        if (fromBalance < value) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = fromBalance - value;
            // Cannot overflow: the sum of all balances is bounded by totalSupply <= 1e27.
            balanceOf[to] += value;
        }
        emit Transfer(from, to, value);
    }

    function _burn(address from, uint256 value) private {
        uint256 fromBalance = balanceOf[from];
        if (fromBalance < value) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = fromBalance - value;
            totalSupply -= value;
        }
        emit Transfer(from, address(0), value);
    }

    function _spendAllowance(address owner, address spender, uint256 value) private {
        uint256 current = allowance[owner][spender];
        if (current == type(uint256).max) return;
        if (current < value) revert InsufficientAllowance();
        unchecked {
            allowance[owner][spender] = current - value;
        }
    }
}
