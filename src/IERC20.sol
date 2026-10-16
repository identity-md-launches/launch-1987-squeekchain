// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title ERC-20 interface (EIP-20) including the optional metadata functions.
/// @notice Declared here so the token, its tests and any integrator share one definition without a
/// third-party dependency.
interface IERC20 {
    /// @notice Emitted when `value` tokens move from `from` to `to`. A mint has `from == address(0)`.
    event Transfer(address indexed from, address indexed to, uint256 value);

    /// @notice Emitted when `owner` sets the allowance of `spender` to `value`.
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}
