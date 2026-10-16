// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./IERC20.sol";

/// @title Squeekchain (SQK)
/// @notice A plain fixed-supply ERC-20. The whole supply of 1,000,000,000 SQK (18 decimals) is
/// minted once, in the constructor, to the deployer (`msg.sender`). Nothing can mint afterwards,
/// nothing can burn, and there is no owner, pause, blocklist, fee or any other privileged power.
/// @dev The contract has no constructor arguments: the launch factory deploys it and receives the
/// supply. Balances are plain storage; transfers to the zero address revert, so the supply can
/// neither grow nor shrink after construction. The contract has no fallback or receive function, so
/// calls to unknown selectors and plain ETH transfers revert.
contract SqueekchainToken is IERC20 {
    /// @dev The token name returned by `name()`.
    string private constant NAME = "Squeekchain";

    /// @dev The token symbol returned by `symbol()`.
    string private constant SYMBOL = "SQK";

    /// @dev The number of decimals returned by `decimals()`.
    uint8 private constant DECIMALS = 18;

    /// @notice The fixed total supply in minor units: 1,000,000,000 SQK with 18 decimals.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    mapping(address account => uint256) private _balances;
    mapping(address owner => mapping(address spender => uint256)) private _allowances;

    /// @notice `sender` tried to move `needed` but holds only `balance`.
    error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);

    /// @notice `spender` tried to move `needed` on behalf of a holder but is allowed only `allowance`.
    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);

    /// @notice The transfer target is the zero address.
    error ERC20InvalidReceiver(address receiver);

    /// @notice The approval target is the zero address.
    error ERC20InvalidSpender(address spender);

    /// @notice Mints the whole fixed supply to the deployer, once.
    constructor() {
        _balances[msg.sender] = TOTAL_SUPPLY;
        emit Transfer(address(0), msg.sender, TOTAL_SUPPLY);
    }

    /// @inheritdoc IERC20
    function name() external pure override returns (string memory) {
        return NAME;
    }

    /// @inheritdoc IERC20
    function symbol() external pure override returns (string memory) {
        return SYMBOL;
    }

    /// @inheritdoc IERC20
    function decimals() external pure override returns (uint8) {
        return DECIMALS;
    }

    /// @inheritdoc IERC20
    /// @dev Fixed for the life of the contract: there is no mint and no burn.
    function totalSupply() external pure override returns (uint256) {
        return TOTAL_SUPPLY;
    }

    /// @inheritdoc IERC20
    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    /// @inheritdoc IERC20
    function allowance(address owner, address spender) external view override returns (uint256) {
        return _allowances[owner][spender];
    }

    /// @inheritdoc IERC20
    /// @dev Sets the allowance outright. Reverts for the zero spender.
    function approve(address spender, uint256 value) external override returns (bool) {
        _approve(msg.sender, spender, value);
        return true;
    }

    /// @inheritdoc IERC20
    /// @dev Reverts, rather than returning false, when the caller holds less than `value` or `to` is
    /// the zero address. A zero-value transfer succeeds and emits.
    function transfer(address to, uint256 value) external override returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    /// @inheritdoc IERC20
    /// @dev Spends the caller's allowance from `from` before moving the balance. An allowance of
    /// `type(uint256).max` is treated as unlimited and is not decremented.
    function transferFrom(address from, address to, uint256 value) external override returns (bool) {
        _spendAllowance(from, msg.sender, value);
        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) private {
        if (to == address(0)) revert ERC20InvalidReceiver(address(0));
        uint256 fromBalance = _balances[from];
        if (fromBalance < value) revert ERC20InsufficientBalance(from, fromBalance, value);
        unchecked {
            // `value <= fromBalance` was checked above, and the balances always sum to
            // TOTAL_SUPPLY, so neither side of the move can wrap.
            _balances[from] = fromBalance - value;
            _balances[to] += value;
        }
        emit Transfer(from, to, value);
    }

    function _approve(address owner, address spender, uint256 value) private {
        if (spender == address(0)) revert ERC20InvalidSpender(address(0));
        _allowances[owner][spender] = value;
        emit Approval(owner, spender, value);
    }

    function _spendAllowance(address owner, address spender, uint256 value) private {
        uint256 current = _allowances[owner][spender];
        if (current != type(uint256).max) {
            if (current < value) revert ERC20InsufficientAllowance(spender, current, value);
            unchecked {
                _allowances[owner][spender] = current - value;
            }
        }
    }
}
