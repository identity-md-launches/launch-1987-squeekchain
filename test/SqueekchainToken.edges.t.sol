// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TestBase} from "./support/TestBase.sol";
import {SqueekchainToken} from "../src/SqueekchainToken.sol";

/// @notice The inputs an implementation tends not to think about: one minor unit, the maximum
/// value, the maximum allowance less one, the same call twice, a spender that is also the owner,
/// the token's own address as a receiver, and reverts that must roll back every side effect.
/// Pinned as plain unit tests beside the fuzzed ones, which bound rather than discard their inputs.
contract SqueekchainTokenEdgeTest is TestBase {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    uint256 internal constant MAX = type(uint256).max;

    address internal constant DEPLOYER = address(0xFAC7);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA201);

    SqueekchainToken internal token;

    function setUp() public {
        vm.prank(DEPLOYER);
        token = new SqueekchainToken();
    }

    // ---------------------------------------------------------------------------------------------
    // Amount edges
    // ---------------------------------------------------------------------------------------------

    function test_oneMinorUnitMoves() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 1);
        vm.assertEq(token.balanceOf(ALICE), 1, "one unit arrived");
        vm.assertEq(token.balanceOf(DEPLOYER), SUPPLY - 1, "one unit left");

        vm.prank(ALICE);
        token.transfer(BOB, 1);
        vm.assertEq(token.balanceOf(ALICE), 0, "alice is empty again");
        vm.assertEq(token.balanceOf(BOB), 1, "bob holds the unit");
    }

    function test_transferOfTheMaximumValueRevertsRatherThanWrapping() public {
        // The unchecked subtraction is guarded by the balance check: MAX cannot slip past it.
        vm.prank(DEPLOYER);
        vm.expectRevert(
            abi.encodeWithSelector(SqueekchainToken.ERC20InsufficientBalance.selector, DEPLOYER, SUPPLY, MAX)
        );
        token.transfer(ALICE, MAX);
        vm.assertEq(token.balanceOf(DEPLOYER), SUPPLY, "nothing moved");
    }

    function test_transferOfOneMoreThanTheBalanceReverts() public {
        vm.prank(DEPLOYER);
        vm.expectRevert(
            abi.encodeWithSelector(SqueekchainToken.ERC20InsufficientBalance.selector, DEPLOYER, SUPPLY, SUPPLY + 1)
        );
        token.transfer(ALICE, SUPPLY + 1);
    }

    function test_receiverCannotOverflowBecauseTheSupplyIsBounded() public {
        // Everything to Alice, then every remaining unit to Alice again: the unchecked addition
        // on the receiver side can never exceed the supply because the sender side is checked.
        vm.prank(DEPLOYER);
        token.transfer(ALICE, SUPPLY);
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 0);
        vm.prank(ALICE);
        token.transfer(ALICE, SUPPLY);
        vm.assertEq(token.balanceOf(ALICE), SUPPLY, "alice holds exactly the supply");
    }

    function test_transferToTheTokenItselfSucceedsAndIsStuck() public {
        // ERC-20 does not special-case the token's own address. What is sent there is conserved
        // but unreachable: the token never calls itself and has no rescue function.
        vm.prank(DEPLOYER);
        vm.assertTrue(token.transfer(address(token), 5), "the token is an ordinary receiver");
        vm.assertEq(token.balanceOf(address(token)), 5, "the token holds what was sent to it");

        (bool ok,) = address(token).call(abi.encodeWithSignature("rescue(address,uint256)", DEPLOYER, 5));
        vm.assertFalse(ok, "no rescue function");
        (ok,) = address(token).call(abi.encodeWithSignature("sweep(address)", DEPLOYER));
        vm.assertFalse(ok, "no sweep function");
        vm.assertEq(token.balanceOf(address(token)), 5, "still stuck");
        vm.assertEq(token.totalSupply(), SUPPLY, "still counted in the supply");
    }

    // ---------------------------------------------------------------------------------------------
    // Allowance edges
    // ---------------------------------------------------------------------------------------------

    function test_maximumAllowanceLessOneIsNotUnlimited() public {
        vm.prank(DEPLOYER);
        token.approve(ALICE, MAX - 1);
        vm.prank(ALICE);
        token.transferFrom(DEPLOYER, BOB, 1);
        vm.assertEq(token.allowance(DEPLOYER, ALICE), MAX - 2, "only the exact maximum is unlimited");
    }

    function test_unlimitedAllowanceSurvivesSpendingTheWholeBalance() public {
        vm.prank(DEPLOYER);
        token.approve(ALICE, MAX);
        vm.prank(ALICE);
        token.transferFrom(DEPLOYER, BOB, SUPPLY);
        vm.assertEq(token.balanceOf(DEPLOYER), 0, "the owner is empty");
        vm.assertEq(token.allowance(DEPLOYER, ALICE), MAX, "the allowance is still unlimited");

        // And it is still refused on the balance, not the allowance.
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(SqueekchainToken.ERC20InsufficientBalance.selector, DEPLOYER, uint256(0), uint256(1))
        );
        token.transferFrom(DEPLOYER, BOB, 1);
    }

    function test_zeroValueTransferFromNeedsNoAllowance() public {
        // ERC-20 requires zero-value transfers to be treated as normal; the allowance check is
        // `0 < 0`, which is false, so no approval is needed and no Approval event is emitted.
        vm.recordLogs();
        vm.prank(ALICE);
        vm.assertTrue(token.transferFrom(DEPLOYER, BOB, 0), "zero pull succeeds without an allowance");
        vm.assertEq(vm.getRecordedLogs().length, 1, "only the Transfer event");
        vm.assertEq(token.allowance(DEPLOYER, ALICE), 0, "allowance is still zero");
        vm.assertEq(token.balanceOf(BOB), 0, "nothing moved");
    }

    function test_allowancesAreIndependentPerSpenderAndPerOwner() public {
        vm.prank(DEPLOYER);
        token.approve(ALICE, 10);
        vm.prank(DEPLOYER);
        token.approve(BOB, 20);
        vm.prank(CAROL);
        token.approve(ALICE, 30);

        vm.assertEq(token.allowance(DEPLOYER, ALICE), 10, "deployer -> alice");
        vm.assertEq(token.allowance(DEPLOYER, BOB), 20, "deployer -> bob");
        vm.assertEq(token.allowance(CAROL, ALICE), 30, "carol -> alice");
        vm.assertEq(token.allowance(ALICE, DEPLOYER), 0, "the reverse direction is not implied");

        vm.prank(ALICE);
        token.transferFrom(DEPLOYER, CAROL, 10);
        vm.assertEq(token.allowance(DEPLOYER, ALICE), 0, "alice's allowance was spent");
        vm.assertEq(token.allowance(DEPLOYER, BOB), 20, "bob's allowance is untouched");
        vm.assertEq(token.allowance(CAROL, ALICE), 30, "carol's grant to alice is untouched");
    }

    function test_allowanceOutlivesTheOwnerBalance() public {
        // An allowance is a promise, not a reservation: it stays set when the balance goes away,
        // and the pull is refused on the balance.
        vm.prank(DEPLOYER);
        token.approve(ALICE, 100);
        vm.prank(DEPLOYER);
        token.transfer(BOB, SUPPLY);

        vm.assertEq(token.allowance(DEPLOYER, ALICE), 100, "allowance unchanged by the transfer");
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(SqueekchainToken.ERC20InsufficientBalance.selector, DEPLOYER, uint256(0), uint256(1))
        );
        token.transferFrom(DEPLOYER, CAROL, 1);
        vm.assertEq(token.allowance(DEPLOYER, ALICE), 100, "the failed pull did not spend the allowance");
    }

    function test_approvingTheSameValueTwiceEmitsTwice() public {
        vm.prank(DEPLOYER);
        token.approve(ALICE, 7);
        vm.expectEmit(true, true, false, true);
        emit Approval(DEPLOYER, ALICE, 7);
        vm.prank(DEPLOYER);
        token.approve(ALICE, 7);
        vm.assertEq(token.allowance(DEPLOYER, ALICE), 7, "idempotent");
    }

    function test_ownerCanBeItsOwnSpender() public {
        vm.prank(DEPLOYER);
        token.approve(DEPLOYER, 50);
        vm.prank(DEPLOYER);
        vm.assertTrue(token.transferFrom(DEPLOYER, ALICE, 50), "self-approved pull");
        vm.assertEq(token.balanceOf(ALICE), 50, "delivered");
        vm.assertEq(token.allowance(DEPLOYER, DEPLOYER), 0, "the self allowance was spent");
    }

    function test_transferFromWhereOwnerIsAlsoReceiverSpendsTheAllowance() public {
        vm.prank(DEPLOYER);
        token.approve(ALICE, 50);
        vm.prank(ALICE);
        vm.assertTrue(token.transferFrom(DEPLOYER, DEPLOYER, 50), "pull back to the owner");
        vm.assertEq(token.balanceOf(DEPLOYER), SUPPLY, "the owner's balance is unchanged");
        vm.assertEq(token.allowance(DEPLOYER, ALICE), 0, "the allowance is still consumed");
    }

    function test_transferFromEmitsOnlyTransfer() public {
        vm.prank(DEPLOYER);
        token.approve(ALICE, 50);
        vm.recordLogs();
        vm.prank(ALICE);
        token.transferFrom(DEPLOYER, BOB, 20);
        vm.assertEq(vm.getRecordedLogs().length, 1, "spending the allowance does not emit Approval");
    }

    // ---------------------------------------------------------------------------------------------
    // The same call twice
    // ---------------------------------------------------------------------------------------------

    function test_theSameTransferTwiceMovesTwice() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 3);
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 3);
        vm.assertEq(token.balanceOf(ALICE), 6, "no replay protection, as ERC-20 specifies");
    }

    function test_theSameExactPullTwiceFailsTheSecondTime() public {
        vm.prank(DEPLOYER);
        token.approve(ALICE, 3);
        vm.prank(ALICE);
        token.transferFrom(DEPLOYER, BOB, 3);
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(SqueekchainToken.ERC20InsufficientAllowance.selector, ALICE, uint256(0), uint256(3))
        );
        token.transferFrom(DEPLOYER, BOB, 3);
        vm.assertEq(token.balanceOf(BOB), 3, "only the first pull delivered");
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzz with bounded inputs
    // ---------------------------------------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_roundTripReturnsExactlyWhatWasSent(uint256 amount) public {
        amount = amount % (SUPPLY + 1);
        vm.prank(DEPLOYER);
        token.transfer(ALICE, amount);
        vm.prank(ALICE);
        token.transfer(DEPLOYER, amount);
        vm.assertEq(token.balanceOf(DEPLOYER), SUPPLY, "the round trip is exact");
        vm.assertEq(token.balanceOf(ALICE), 0, "nothing stays behind");
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_splitAndMergeIsExact(uint256 a, uint256 b) public {
        a = a % (SUPPLY + 1);
        b = b % (SUPPLY - a + 1);
        vm.prank(DEPLOYER);
        token.transfer(ALICE, a);
        vm.prank(DEPLOYER);
        token.transfer(BOB, b);
        vm.prank(ALICE);
        token.transfer(CAROL, a);
        vm.prank(BOB);
        token.transfer(CAROL, b);
        vm.assertEq(token.balanceOf(CAROL), a + b, "merge equals the split");
        vm.assertEq(token.balanceOf(DEPLOYER), SUPPLY - a - b, "the remainder is exact");
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_anyAllowanceBelowMaxIsDecrementedExactly(uint256 allowed, uint256 amount) public {
        allowed = allowed % MAX; // never the unlimited sentinel
        amount = amount % (SUPPLY + 1);
        if (amount > allowed) amount = allowed;
        vm.prank(DEPLOYER);
        token.approve(ALICE, allowed);
        vm.prank(ALICE);
        token.transferFrom(DEPLOYER, BOB, amount);
        vm.assertEq(token.allowance(DEPLOYER, ALICE), allowed - amount, "decremented by exactly the amount");
        vm.assertEq(token.balanceOf(BOB), amount, "delivered exactly the amount");
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_anyAmountAboveTheBalanceIsRefusedAndRollsBack(uint256 held, uint256 excess) public {
        held = held % SUPPLY; // strictly below the supply so an excess exists
        excess = 1 + (excess % (SUPPLY - held));
        vm.prank(DEPLOYER);
        token.transfer(ALICE, held);

        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(SqueekchainToken.ERC20InsufficientBalance.selector, ALICE, held, held + excess)
        );
        token.transfer(BOB, held + excess);
        vm.assertEq(token.balanceOf(ALICE), held, "alice keeps her balance");
        vm.assertEq(token.balanceOf(BOB), 0, "bob received nothing");
        vm.assertEq(token.balanceOf(DEPLOYER) + held, SUPPLY, "conserved");
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_anyReceiverButZeroIsAccepted(address to, uint256 amount) public {
        amount = amount % (SUPPLY + 1);
        if (to == address(0)) {
            vm.prank(DEPLOYER);
            vm.expectRevert(abi.encodeWithSelector(SqueekchainToken.ERC20InvalidReceiver.selector, address(0)));
            token.transfer(to, amount);
            vm.assertEq(token.balanceOf(DEPLOYER), SUPPLY, "nothing left the deployer");
            return;
        }
        vm.prank(DEPLOYER);
        vm.assertTrue(token.transfer(to, amount), "accepted");
        if (to == DEPLOYER) {
            vm.assertEq(token.balanceOf(DEPLOYER), SUPPLY, "self transfer is a no-op");
        } else {
            vm.assertEq(token.balanceOf(to), amount, "credited");
            vm.assertEq(token.balanceOf(DEPLOYER), SUPPLY - amount, "debited");
        }
    }
}
