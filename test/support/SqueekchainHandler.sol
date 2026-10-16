// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "./Vm.sol";
import {SqueekchainToken} from "../../src/SqueekchainToken.sol";

/// @notice Drives the token with random call sequences for the invariant runner.
/// @dev Every entry point bounds its inputs so that the call it makes is well-formed, then asserts
/// the postcondition of that one call and mirrors the expected state in ghost variables. The
/// negative handlers build a call that must revert and assert that it did and that nothing moved.
/// Because the runner is configured to fail on any revert, the handler itself must never revert:
/// anything that may fail goes through a low-level call.
///
/// Actors: the deployer, four holders, a contract holder (this handler) and the token itself, which
/// is a valid ERC-20 receiver like any other address. Tokens only ever flow between actors, so the
/// actors' balances must always sum to the supply.
contract SqueekchainHandler {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;

    SqueekchainToken public immutable token;
    address[] public actors;

    /// @dev Expected balances and allowances, maintained independently of the token's storage.
    mapping(address => uint256) public ghostBalance;
    mapping(address => mapping(address => uint256)) public ghostAllowance;

    /// @dev Bookkeeping so a vacuous run (nothing ever succeeded) can be told apart from a real one.
    uint256 public ghostTransfers;
    uint256 public ghostTransferFroms;
    uint256 public ghostApprovals;
    uint256 public ghostUnlimitedSpends;
    uint256 public ghostRejectedCalls;
    uint256 public ghostValueMoved;

    constructor(SqueekchainToken token_, address deployer, address[] memory holders) {
        token = token_;
        actors.push(deployer);
        for (uint256 i; i < holders.length; ++i) {
            actors.push(holders[i]);
        }
        actors.push(address(this));
        actors.push(address(token_));
        ghostBalance[deployer] = SUPPLY;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    // ---------------------------------------------------------------------------------------------
    // Successful paths
    // ---------------------------------------------------------------------------------------------

    /// @notice An actor moves up to its whole balance to another actor (possibly itself).
    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _sender(fromSeed);
        address to = _actor(toSeed);
        amount = _bound(amount, 0, token.balanceOf(from));
        _transfer(from, to, amount);
    }

    /// @notice An actor moves exactly its whole balance: the edge the bound above rarely picks.
    function transferAll(uint256 fromSeed, uint256 toSeed) external {
        address from = _sender(fromSeed);
        _transfer(from, _actor(toSeed), token.balanceOf(from));
    }

    /// @notice An actor moves one minor unit, or zero.
    function transferDust(uint256 fromSeed, uint256 toSeed, bool one) external {
        address from = _sender(fromSeed);
        uint256 amount = one && token.balanceOf(from) > 0 ? 1 : 0;
        _transfer(from, _actor(toSeed), amount);
    }

    /// @notice An actor sets a spender's allowance to any value, including zero and the maximum.
    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = _sender(ownerSeed);
        address spender = _sender(spenderSeed);
        _approve(owner, spender, amount);
    }

    /// @notice An actor grants an unlimited allowance.
    function approveMax(uint256 ownerSeed, uint256 spenderSeed) external {
        _approve(_sender(ownerSeed), _sender(spenderSeed), type(uint256).max);
    }

    /// @notice A spender pulls, within both the owner's balance and its allowance.
    function transferFrom(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amount) external {
        address spender = _sender(spenderSeed);
        address owner = _sender(ownerSeed);
        address to = _actor(toSeed);
        uint256 allowed = token.allowance(owner, spender);
        uint256 cap = token.balanceOf(owner);
        if (allowed < cap) cap = allowed;
        amount = _bound(amount, 0, cap);
        _transferFrom(spender, owner, to, amount);
    }

    /// @notice A spender first receives an allowance covering the pull, then pulls the whole of it.
    function approveThenTransferFromExact(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amount)
        external
    {
        address spender = _sender(spenderSeed);
        address owner = _sender(ownerSeed);
        amount = _bound(amount, 0, token.balanceOf(owner));
        _approve(owner, spender, amount);
        _transferFrom(spender, owner, _actor(toSeed), amount);
    }

    // ---------------------------------------------------------------------------------------------
    // Paths that must fail, and must leave nothing behind when they do
    // ---------------------------------------------------------------------------------------------

    /// @notice Moving more than the balance must revert with the typed error and change nothing.
    function transferAboveBalance(uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address from = _sender(fromSeed);
        address to = _actor(toSeed);
        uint256 balance = token.balanceOf(from);
        uint256 amount = balance + _bound(excess, 1, type(uint256).max - balance);
        _mustRevert(
            from,
            abi.encodeCall(token.transfer, (to, amount)),
            abi.encodeWithSelector(SqueekchainToken.ERC20InsufficientBalance.selector, from, balance, amount)
        );
    }

    /// @notice Pulling more than the allowance must revert even when the balance would cover it.
    function transferFromAboveAllowance(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 excess)
        external
    {
        address spender = _sender(spenderSeed);
        address owner = _sender(ownerSeed);
        uint256 allowed = token.allowance(owner, spender);
        if (allowed == type(uint256).max) {
            // Unlimited: the only way to be refused is the balance. Covered by the handler below.
            return;
        }
        uint256 amount = allowed + _bound(excess, 1, type(uint256).max - allowed);
        _mustRevert(
            spender,
            abi.encodeCall(token.transferFrom, (owner, _actor(toSeed), amount)),
            abi.encodeWithSelector(SqueekchainToken.ERC20InsufficientAllowance.selector, spender, allowed, amount)
        );
    }

    /// @notice Pulling more than the owner holds must revert even with an unlimited allowance.
    function transferFromAboveBalance(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 excess) external {
        address spender = _sender(spenderSeed);
        address owner = _sender(ownerSeed);
        _approve(owner, spender, type(uint256).max);
        uint256 balance = token.balanceOf(owner);
        uint256 amount = balance + _bound(excess, 1, type(uint256).max - balance);
        _mustRevert(
            spender,
            abi.encodeCall(token.transferFrom, (owner, _actor(toSeed), amount)),
            abi.encodeWithSelector(SqueekchainToken.ERC20InsufficientBalance.selector, owner, balance, amount)
        );
    }

    /// @notice The zero address can never receive, so nothing can be burned by sending there.
    function transferToZero(uint256 fromSeed, uint256 amount) external {
        address from = _sender(fromSeed);
        amount = _bound(amount, 0, token.balanceOf(from));
        _mustRevert(
            from,
            abi.encodeCall(token.transfer, (address(0), amount)),
            abi.encodeWithSelector(SqueekchainToken.ERC20InvalidReceiver.selector, address(0))
        );
    }

    /// @notice Nor can the zero address be approved.
    function approveZeroSpender(uint256 ownerSeed, uint256 amount) external {
        _mustRevert(
            _sender(ownerSeed),
            abi.encodeCall(token.approve, (address(0), amount)),
            abi.encodeWithSelector(SqueekchainToken.ERC20InvalidSpender.selector, address(0))
        );
    }

    /// @notice An address outside the actor set holds nothing, so it can never move anything.
    function strangerTransfers(address stranger, uint256 toSeed, uint256 amount) external {
        if (_isActor(stranger)) return;
        amount = _bound(amount, 1, type(uint256).max);
        _mustRevert(
            stranger,
            abi.encodeCall(token.transfer, (_actor(toSeed), amount)),
            abi.encodeWithSelector(SqueekchainToken.ERC20InsufficientBalance.selector, stranger, 0, amount)
        );
    }

    /// @notice A stranger with no allowance can never pull from a holder.
    function strangerPulls(address stranger, uint256 ownerSeed, uint256 amount) external {
        if (_isActor(stranger)) return;
        address owner = _sender(ownerSeed);
        amount = _bound(amount, 1, type(uint256).max);
        _mustRevert(
            stranger,
            abi.encodeCall(token.transferFrom, (owner, stranger, amount)),
            abi.encodeWithSelector(SqueekchainToken.ERC20InsufficientAllowance.selector, stranger, 0, amount)
        );
    }

    /// @notice No selector the token does not declare does anything, from anyone.
    function callUnknownSelector(uint256 callerSeed, bytes4 selector, bytes calldata args) external {
        if (_isDeclared(selector)) return;
        bytes memory data = abi.encodePacked(selector, args);
        _mustRevert(_sender(callerSeed), data, "");
    }

    /// @notice The token takes no ETH.
    function sendEther(uint256 callerSeed, uint256 amount) external {
        address caller = _sender(callerSeed);
        amount = _bound(amount, 0, 1_000 ether);
        vm.deal(caller, amount);
        vm.prank(caller);
        (bool ok,) = address(token).call{value: amount}("");
        vm.assertFalse(ok, "the token accepted ether");
        vm.assertEq(address(token).balance, 0, "the token holds ether");
        ghostRejectedCalls++;
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    function _transfer(address from, address to, uint256 amount) private {
        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);

        vm.prank(from);
        bool ok = token.transfer(to, amount);
        vm.assertTrue(ok, "transfer returned false");

        if (from == to) {
            vm.assertEq(token.balanceOf(from), fromBefore, "a self transfer changed the balance");
        } else {
            vm.assertEq(token.balanceOf(from), fromBefore - amount, "sender debited wrongly");
            vm.assertEq(token.balanceOf(to), toBefore + amount, "receiver credited wrongly");
            ghostBalance[from] -= amount;
            ghostBalance[to] += amount;
        }
        ghostTransfers++;
        ghostValueMoved += amount;
    }

    function _approve(address owner, address spender, uint256 amount) private {
        vm.prank(owner);
        bool ok = token.approve(spender, amount);
        vm.assertTrue(ok, "approve returned false");
        vm.assertEq(token.allowance(owner, spender), amount, "allowance not set outright");
        ghostAllowance[owner][spender] = amount;
        ghostApprovals++;
    }

    function _transferFrom(address spender, address owner, address to, uint256 amount) private {
        uint256 allowedBefore = token.allowance(owner, spender);
        uint256 ownerBefore = token.balanceOf(owner);
        uint256 toBefore = token.balanceOf(to);

        vm.prank(spender);
        bool ok = token.transferFrom(owner, to, amount);
        vm.assertTrue(ok, "transferFrom returned false");

        if (allowedBefore == type(uint256).max) {
            vm.assertEq(token.allowance(owner, spender), type(uint256).max, "unlimited allowance was decremented");
            ghostUnlimitedSpends++;
        } else {
            vm.assertEq(token.allowance(owner, spender), allowedBefore - amount, "allowance not reduced by the amount");
            ghostAllowance[owner][spender] = allowedBefore - amount;
        }
        if (owner == to) {
            vm.assertEq(token.balanceOf(owner), ownerBefore, "a self pull changed the balance");
        } else {
            vm.assertEq(token.balanceOf(owner), ownerBefore - amount, "owner debited wrongly");
            vm.assertEq(token.balanceOf(to), toBefore + amount, "receiver credited wrongly");
            ghostBalance[owner] -= amount;
            ghostBalance[to] += amount;
        }
        ghostTransferFroms++;
        ghostValueMoved += amount;
    }

    /// @dev Makes the call as `caller`, requires it to fail with exactly `expectedRevert` (or with
    /// anything, when `expectedRevert` is empty), and requires every actor's state to be as before.
    function _mustRevert(address caller, bytes memory data, bytes memory expectedRevert) private {
        bytes32 before = _stateDigest();
        vm.prank(caller);
        (bool ok, bytes memory ret) = address(token).call(data);
        vm.assertFalse(ok, "a call that must revert succeeded");
        if (expectedRevert.length > 0) {
            vm.assertEq(keccak256(ret), keccak256(expectedRevert), "wrong revert reason");
        }
        vm.assertEq(_stateDigest(), before, "a reverted call changed state");
        ghostRejectedCalls++;
    }

    /// @dev Every balance and every pairwise allowance among the actors, folded into one hash.
    function _stateDigest() private view returns (bytes32 digest) {
        uint256 n = actors.length;
        for (uint256 i; i < n; ++i) {
            digest = keccak256(abi.encode(digest, token.balanceOf(actors[i])));
            for (uint256 j; j < n; ++j) {
                digest = keccak256(abi.encode(digest, token.allowance(actors[i], actors[j])));
            }
        }
        digest = keccak256(abi.encode(digest, token.totalSupply()));
    }

    /// @dev Any actor, including the token itself, may receive.
    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev Only an account that can actually send a transaction acts: the token (the last actor)
    /// never calls itself, so whatever lands there is stuck.
    function _sender(uint256 seed) private view returns (address) {
        return actors[seed % (actors.length - 1)];
    }

    function _isActor(address a) private view returns (bool) {
        for (uint256 i; i < actors.length; ++i) {
            if (actors[i] == a) return true;
        }
        return a == address(0);
    }

    function _isDeclared(bytes4 selector) private pure returns (bool) {
        return selector == SqueekchainToken.name.selector || selector == SqueekchainToken.symbol.selector
            || selector == SqueekchainToken.decimals.selector || selector == SqueekchainToken.totalSupply.selector
            || selector == SqueekchainToken.balanceOf.selector || selector == SqueekchainToken.allowance.selector
            || selector == SqueekchainToken.approve.selector || selector == SqueekchainToken.transfer.selector
            || selector == SqueekchainToken.transferFrom.selector || selector == bytes4(keccak256("TOTAL_SUPPLY()"));
    }

    /// @dev Maps `x` into `[min, max]` inclusive. `max >= min` is the caller's responsibility.
    function _bound(uint256 x, uint256 min, uint256 max) private pure returns (uint256) {
        if (min >= max) return min;
        uint256 size = max - min;
        if (size == type(uint256).max) return x;
        return min + (x % (size + 1));
    }
}
