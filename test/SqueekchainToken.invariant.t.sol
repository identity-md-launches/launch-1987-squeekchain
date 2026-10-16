// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TestBase} from "./support/TestBase.sol";
import {SqueekchainHandler} from "./support/SqueekchainHandler.sol";
import {SqueekchainToken} from "../src/SqueekchainToken.sol";

/// @notice Invariants of the token under random sequences of transfers, approvals, pulls and
/// calls that must be refused, driven through `SqueekchainHandler` with bounded inputs.
/// @dev The runner is told to fail on any revert: every call the handler makes is meant to
/// succeed, and the ones meant to fail are made through a low-level call and asserted inside the
/// handler. A revert reaching the runner is therefore a broken handler or a broken token, never
/// noise to be filtered.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 50
/// forge-config: default.invariant.fail-on-revert = true
contract SqueekchainTokenInvariantTest is TestBase {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;

    address internal constant DEPLOYER = address(0xFAC7);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA201);
    address internal constant DAVE = address(0xDA7E);

    SqueekchainToken internal token;
    SqueekchainHandler internal handler;
    bytes32 internal codeHashAtDeployment;

    struct FuzzSelector {
        address addr;
        bytes4[] selectors;
    }

    address[] private _targets;
    FuzzSelector[] private _selectors;

    function setUp() public {
        vm.prank(DEPLOYER);
        token = new SqueekchainToken();
        codeHashAtDeployment = address(token).codehash;

        address[] memory holders = new address[](4);
        holders[0] = ALICE;
        holders[1] = BOB;
        holders[2] = CAROL;
        holders[3] = DAVE;
        handler = new SqueekchainHandler(token, DEPLOYER, holders);

        vm.label(DEPLOYER, "deployer");
        vm.label(ALICE, "alice");
        vm.label(BOB, "bob");
        vm.label(CAROL, "carol");
        vm.label(DAVE, "dave");
        vm.label(address(handler), "handler");
        vm.label(address(token), "SQK");

        _targets.push(address(handler));

        bytes4[] memory selectors = new bytes4[](16);
        selectors[0] = SqueekchainHandler.transfer.selector;
        selectors[1] = SqueekchainHandler.transferAll.selector;
        selectors[2] = SqueekchainHandler.transferDust.selector;
        selectors[3] = SqueekchainHandler.approve.selector;
        selectors[4] = SqueekchainHandler.approveMax.selector;
        selectors[5] = SqueekchainHandler.transferFrom.selector;
        selectors[6] = SqueekchainHandler.approveThenTransferFromExact.selector;
        selectors[7] = SqueekchainHandler.transferAboveBalance.selector;
        selectors[8] = SqueekchainHandler.transferFromAboveAllowance.selector;
        selectors[9] = SqueekchainHandler.transferFromAboveBalance.selector;
        selectors[10] = SqueekchainHandler.transferToZero.selector;
        selectors[11] = SqueekchainHandler.approveZeroSpender.selector;
        selectors[12] = SqueekchainHandler.strangerTransfers.selector;
        selectors[13] = SqueekchainHandler.strangerPulls.selector;
        selectors[14] = SqueekchainHandler.callUnknownSelector.selector;
        selectors[15] = SqueekchainHandler.sendEther.selector;
        _selectors.push(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev Only the handler is called by the runner; the token is reached through it.
    function targetContracts() external view returns (address[] memory) {
        return _targets;
    }

    function targetSelectors() external view returns (FuzzSelector[] memory) {
        return _selectors;
    }

    // ---------------------------------------------------------------------------------------------
    // Conservation
    // ---------------------------------------------------------------------------------------------

    /// @notice The reported supply never changes, whatever anyone does.
    function invariant_totalSupplyIsFixed() public view {
        vm.assertEq(token.totalSupply(), SUPPLY, "the supply changed");
        vm.assertEq(token.TOTAL_SUPPLY(), SUPPLY, "the constant changed");
    }

    /// @notice Tokens only ever flow between the actors, so their balances always sum to the supply:
    /// nothing is created, nothing is destroyed, nothing leaks to an address nobody sent to.
    function invariant_actorBalancesSumToTheSupply() public view {
        uint256 sum;
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        vm.assertEq(sum, SUPPLY, "actor balances do not sum to the supply");
    }

    /// @notice No single balance can exceed the supply.
    function invariant_noBalanceExceedsTheSupply() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            vm.assertLe(token.balanceOf(handler.actors(i)), SUPPLY, "a balance exceeds the supply");
        }
    }

    /// @notice The zero address never holds anything: there is no burn and no mint after construction.
    function invariant_zeroAddressHoldsNothing() public view {
        vm.assertEq(token.balanceOf(address(0)), 0, "the zero address holds tokens");
    }

    // ---------------------------------------------------------------------------------------------
    // Internal accounting equals the handler's independent record
    // ---------------------------------------------------------------------------------------------

    /// @notice Every actor's balance is exactly what the sequence of successful moves implies.
    function invariant_balancesMatchTheGhostLedger() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address actor = handler.actors(i);
            vm.assertEq(token.balanceOf(actor), handler.ghostBalance(actor), "balance diverged from the ledger");
        }
    }

    /// @notice Every pairwise allowance is exactly what the approvals and spends imply, and an
    /// unlimited allowance is still unlimited after any number of pulls.
    function invariant_allowancesMatchTheGhostLedger() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address owner = handler.actors(i);
            for (uint256 j; j < n; ++j) {
                address spender = handler.actors(j);
                vm.assertEq(
                    token.allowance(owner, spender),
                    handler.ghostAllowance(owner, spender),
                    "allowance diverged from the ledger"
                );
            }
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Nothing else changes
    // ---------------------------------------------------------------------------------------------

    /// @notice The token's code is what was deployed: nothing upgrades or destroys it.
    function invariant_codeIsUnchanged() public view {
        vm.assertEq(address(token).codehash, codeHashAtDeployment, "the token's code changed");
        vm.assertGt(address(token).code.length, 0, "the token has no code");
    }

    /// @notice The token never holds ether.
    function invariant_tokenHoldsNoEther() public view {
        vm.assertEq(address(token).balance, 0, "the token holds ether");
    }

    /// @notice Metadata is constant.
    function invariant_metadataIsConstant() public view {
        vm.assertEq(token.name(), "Squeekchain", "name changed");
        vm.assertEq(token.symbol(), "SQK", "symbol changed");
        vm.assertEq(uint256(token.decimals()), 18, "decimals changed");
    }

    /// @notice Whatever reaches the token's own address stays there: nobody can make the token
    /// call itself, so its balance can only grow.
    function invariant_tokensSentToTheContractAreStuck() public view {
        vm.assertEq(
            token.balanceOf(address(token)),
            handler.ghostBalance(address(token)),
            "the token's own balance diverged from what was sent to it"
        );
    }
}
