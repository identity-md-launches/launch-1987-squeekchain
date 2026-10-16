// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "./Vm.sol";

/// @notice Shared scaffolding for the tests: the cheatcode handle and the ERC-20 events, redeclared
/// so `vm.expectEmit` has something to compare against.
abstract contract TestBase {
    /// @dev forge's cheatcode address: `address(uint160(uint256(keccak256("hevm cheat code"))))`.
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}
