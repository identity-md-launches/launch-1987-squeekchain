// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "./support/Vm.sol";
import {TestBase} from "./support/TestBase.sol";
import {SqueekchainToken} from "../src/SqueekchainToken.sol";

/// @notice Behaviour of the Squeekchain token: metadata, the one-time mint to the deployer, every
/// ERC-20 success and failure path, the absence of privileged entry points, and conservation of
/// the supply under fuzzed transfers.
contract SqueekchainTokenTest is TestBase {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;

    /// @dev Stands in for the launch factory: whoever deploys receives the supply.
    address internal constant DEPLOYER = address(0xFAC7);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA201);

    SqueekchainToken internal token;

    function setUp() public {
        vm.label(DEPLOYER, "deployer");
        vm.label(ALICE, "alice");
        vm.label(BOB, "bob");
        vm.label(CAROL, "carol");
        vm.prank(DEPLOYER);
        token = new SqueekchainToken();
    }

    // ---------------------------------------------------------------------------------------------
    // Metadata and the constructor mint
    // ---------------------------------------------------------------------------------------------

    function test_metadata() public view {
        vm.assertEq(token.name(), "Squeekchain", "name");
        vm.assertEq(token.symbol(), "SQK", "symbol");
        vm.assertEq(uint256(token.decimals()), 18, "decimals");
    }

    function test_constructorMintsTheWholeSupplyToTheDeployer() public view {
        vm.assertEq(token.TOTAL_SUPPLY(), SUPPLY, "TOTAL_SUPPLY constant");
        vm.assertEq(token.totalSupply(), SUPPLY, "totalSupply");
        vm.assertEq(token.balanceOf(DEPLOYER), SUPPLY, "the deployer holds everything");
        vm.assertEq(token.balanceOf(ALICE), 0, "nobody else holds anything");
        vm.assertEq(token.balanceOf(address(0)), 0, "nothing sits at the zero address");
    }

    function test_constructorEmitsASingleMintTransfer() public {
        vm.recordLogs();
        vm.prank(CAROL);
        SqueekchainToken fresh = new SqueekchainToken();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        vm.assertEq(logs.length, 1, "exactly one event at construction");
        vm.assertEq(logs[0].emitter, address(fresh), "emitted by the token");
        vm.assertEq(logs[0].topics.length, 3, "Transfer has two indexed topics");
        vm.assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"), "Transfer signature");
        vm.assertEq(logs[0].topics[1], bytes32(0), "minted from the zero address");
        vm.assertEq(logs[0].topics[2], bytes32(uint256(uint160(CAROL))), "minted to the deployer");
        vm.assertEq(abi.decode(logs[0].data, (uint256)), SUPPLY, "minted the whole supply");
        vm.assertEq(fresh.balanceOf(CAROL), SUPPLY, "a second deployment mints to its own deployer");
    }

    // ---------------------------------------------------------------------------------------------
    // transfer
    // ---------------------------------------------------------------------------------------------

    function test_transferMovesTheBalanceAndEmits() public {
        uint256 amount = 1_234 * 10 ** 18;

        vm.expectEmit(true, true, false, true);
        emit Transfer(DEPLOYER, ALICE, amount);
        vm.prank(DEPLOYER);
        bool ok = token.transfer(ALICE, amount);

        vm.assertTrue(ok, "transfer returns true");
        vm.assertEq(token.balanceOf(ALICE), amount, "alice received the amount");
        vm.assertEq(token.balanceOf(DEPLOYER), SUPPLY - amount, "the deployer paid the amount");
        vm.assertEq(token.totalSupply(), SUPPLY, "the supply is unchanged");
    }

    function test_transferOfTheWholeBalanceSucceeds() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, SUPPLY);
        vm.assertEq(token.balanceOf(ALICE), SUPPLY, "alice holds everything");
        vm.assertEq(token.balanceOf(DEPLOYER), 0, "the deployer holds nothing");

        vm.prank(ALICE);
        token.transfer(BOB, SUPPLY);
        vm.assertEq(token.balanceOf(BOB), SUPPLY, "bob holds everything");
        vm.assertEq(token.balanceOf(ALICE), 0, "alice holds nothing");
    }

    function test_zeroValueTransferSucceedsAndEmits() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(ALICE, BOB, 0);
        vm.prank(ALICE);
        vm.assertTrue(token.transfer(BOB, 0), "a zero transfer from an empty account succeeds");
        vm.assertEq(token.balanceOf(BOB), 0, "nothing moved");
    }

    function test_selfTransferKeepsTheBalance() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 100);

        vm.prank(ALICE);
        vm.assertTrue(token.transfer(ALICE, 60), "self transfer succeeds");
        vm.assertEq(token.balanceOf(ALICE), 100, "a self transfer neither creates nor destroys");
    }

    function test_transferRevertsWhenTheBalanceIsInsufficient() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 10);

        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(SqueekchainToken.ERC20InsufficientBalance.selector, ALICE, uint256(10), uint256(11))
        );
        token.transfer(BOB, 11);

        vm.assertEq(token.balanceOf(ALICE), 10, "alice keeps her balance");
        vm.assertEq(token.balanceOf(BOB), 0, "bob received nothing");
    }

    function test_transferFromAnEmptyAccountReverts() public {
        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(SqueekchainToken.ERC20InsufficientBalance.selector, BOB, uint256(0), uint256(1))
        );
        token.transfer(ALICE, 1);
    }

    function test_transferToTheZeroAddressReverts() public {
        vm.prank(DEPLOYER);
        vm.expectRevert(abi.encodeWithSelector(SqueekchainToken.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);

        vm.assertEq(token.balanceOf(DEPLOYER), SUPPLY, "nothing was burned");
        vm.assertEq(token.totalSupply(), SUPPLY, "the supply cannot shrink");
    }

    // ---------------------------------------------------------------------------------------------
    // approve and transferFrom
    // ---------------------------------------------------------------------------------------------

    function test_approveSetsTheAllowanceAndEmits() public {
        vm.expectEmit(true, true, false, true);
        emit Approval(DEPLOYER, ALICE, 500);
        vm.prank(DEPLOYER);
        vm.assertTrue(token.approve(ALICE, 500), "approve returns true");
        vm.assertEq(token.allowance(DEPLOYER, ALICE), 500, "allowance is set");

        // A later approval overwrites rather than accumulates.
        vm.prank(DEPLOYER);
        token.approve(ALICE, 20);
        vm.assertEq(token.allowance(DEPLOYER, ALICE), 20, "allowance is overwritten");

        // Approving zero clears it.
        vm.prank(DEPLOYER);
        token.approve(ALICE, 0);
        vm.assertEq(token.allowance(DEPLOYER, ALICE), 0, "allowance is cleared");
    }

    function test_approveDoesNotNeedABalance() public {
        vm.prank(ALICE);
        vm.assertTrue(token.approve(BOB, SUPPLY), "an empty account may still approve");
        vm.assertEq(token.allowance(ALICE, BOB), SUPPLY, "allowance recorded");
    }

    function test_approveTheZeroSpenderReverts() public {
        vm.prank(DEPLOYER);
        vm.expectRevert(abi.encodeWithSelector(SqueekchainToken.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    function test_transferFromSpendsTheAllowanceAndEmits() public {
        vm.prank(DEPLOYER);
        token.approve(ALICE, 300);

        vm.expectEmit(true, true, false, true);
        emit Transfer(DEPLOYER, BOB, 200);
        vm.prank(ALICE);
        bool ok = token.transferFrom(DEPLOYER, BOB, 200);

        vm.assertTrue(ok, "transferFrom returns true");
        vm.assertEq(token.balanceOf(BOB), 200, "bob received the amount");
        vm.assertEq(token.balanceOf(DEPLOYER), SUPPLY - 200, "the deployer paid the amount");
        vm.assertEq(token.balanceOf(ALICE), 0, "the spender holds nothing itself");
        vm.assertEq(token.allowance(DEPLOYER, ALICE), 100, "the allowance was reduced by the amount");
        vm.assertEq(token.totalSupply(), SUPPLY, "the supply is unchanged");
    }

    function test_transferFromCanSpendTheExactAllowance() public {
        vm.prank(DEPLOYER);
        token.approve(ALICE, 300);
        vm.prank(ALICE);
        token.transferFrom(DEPLOYER, BOB, 300);
        vm.assertEq(token.allowance(DEPLOYER, ALICE), 0, "the allowance is used up");

        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(SqueekchainToken.ERC20InsufficientAllowance.selector, ALICE, uint256(0), uint256(1))
        );
        token.transferFrom(DEPLOYER, BOB, 1);
    }

    function test_transferFromRevertsWithoutAnAllowance() public {
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(SqueekchainToken.ERC20InsufficientAllowance.selector, ALICE, uint256(0), uint256(1))
        );
        token.transferFrom(DEPLOYER, BOB, 1);
        vm.assertEq(token.balanceOf(DEPLOYER), SUPPLY, "nothing moved");
    }

    function test_transferFromRevertsAboveTheAllowance() public {
        vm.prank(DEPLOYER);
        token.approve(ALICE, 99);

        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                SqueekchainToken.ERC20InsufficientAllowance.selector, ALICE, uint256(99), uint256(100)
            )
        );
        token.transferFrom(DEPLOYER, BOB, 100);
        vm.assertEq(token.allowance(DEPLOYER, ALICE), 99, "a failed spend leaves the allowance intact");
    }

    function test_transferFromRevertsWhenTheOwnerBalanceIsInsufficientDespiteAllowance() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 10);
        vm.prank(ALICE);
        token.approve(BOB, 1_000);

        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(SqueekchainToken.ERC20InsufficientBalance.selector, ALICE, uint256(10), uint256(11))
        );
        token.transferFrom(ALICE, CAROL, 11);
        vm.assertEq(token.allowance(ALICE, BOB), 1_000, "the revert rolled the allowance back");
    }

    function test_transferFromToTheZeroAddressReverts() public {
        vm.prank(DEPLOYER);
        token.approve(ALICE, 5);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(SqueekchainToken.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(DEPLOYER, address(0), 5);
    }

    function test_unlimitedAllowanceIsNotDecremented() public {
        vm.prank(DEPLOYER);
        token.approve(ALICE, type(uint256).max);

        vm.prank(ALICE);
        token.transferFrom(DEPLOYER, BOB, 1_000);
        vm.assertEq(token.allowance(DEPLOYER, ALICE), type(uint256).max, "an unlimited allowance stays unlimited");
        vm.assertEq(token.balanceOf(BOB), 1_000, "the transfer still happened");
    }

    function test_transferFromOfOwnTokensStillNeedsSelfAllowance() public {
        vm.prank(DEPLOYER);
        vm.expectRevert(
            abi.encodeWithSelector(
                SqueekchainToken.ERC20InsufficientAllowance.selector, DEPLOYER, uint256(0), uint256(1)
            )
        );
        token.transferFrom(DEPLOYER, ALICE, 1);
    }

    // ---------------------------------------------------------------------------------------------
    // No privileged surface: nothing mints, burns, pauses, blocks or seizes
    // ---------------------------------------------------------------------------------------------

    function test_noEntryPointIncreasesTheSupply() public {
        address attacker = address(0xBEEF);
        string[10] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], attacker, type(uint128).max);
            vm.prank(attacker);
            (bool ok,) = address(token).call(data);
            vm.assertFalse(ok, signatures[i]);
            vm.prank(DEPLOYER);
            (ok,) = address(token).call(data);
            vm.assertFalse(ok, signatures[i]);
            vm.assertEq(token.totalSupply(), SUPPLY, signatures[i]);
            vm.assertEq(token.balanceOf(attacker), 0, signatures[i]);
        }
    }

    function test_noPrivilegedCallMovesOrFreezesAHolder() public {
        uint256 held = SUPPLY / 1_000;
        vm.prank(DEPLOYER);
        token.transfer(ALICE, held);

        string[13] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "burn(uint256)",
            "seize(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], ALICE, true);
            vm.prank(DEPLOYER);
            (bool ok,) = address(token).call(data);
            vm.assertFalse(ok, signatures[i]);
        }

        // The deployer has no allowance from the holder, so it cannot pull either.
        vm.prank(DEPLOYER);
        (bool moved,) =
            address(token).call(abi.encodeWithSelector(SqueekchainToken.transferFrom.selector, ALICE, DEPLOYER, 1));
        vm.assertFalse(moved, "the deployer cannot pull from a holder");

        vm.assertEq(token.balanceOf(ALICE), held, "the holder still holds what it held");
        vm.prank(ALICE);
        vm.assertTrue(token.transfer(BOB, held / 2), "the holder can still transfer");
        vm.assertEq(token.balanceOf(BOB), held / 2, "the holder's transfer delivered");
        vm.assertEq(token.totalSupply(), SUPPLY, "the supply is unchanged");
    }

    function test_plainEtherAndUnknownCallsRevert() public {
        (bool ok,) = address(token).call{value: 0}("");
        vm.assertFalse(ok, "no receive function");
        (ok,) = address(token).call(hex"deadbeef");
        vm.assertFalse(ok, "no fallback function");
    }

    function test_runtimeCodeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        vm.assertGt(runtime.length, 0, "the token has runtime code");
        vm.assertLe(runtime.length, 24_576, "runtime fits EIP-170");
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            vm.assertTrue(op != 0xF4, "runtime code contains DELEGATECALL");
            vm.assertTrue(op != 0xF2, "runtime code contains CALLCODE");
            vm.assertTrue(op != 0xFF, "runtime code contains SELFDESTRUCT");
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzz: conservation and bounds
    // ---------------------------------------------------------------------------------------------

    function testFuzz_transferConservesTheSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != DEPLOYER);
        amount = amount % (SUPPLY + 1);

        vm.prank(DEPLOYER);
        vm.assertTrue(token.transfer(to, amount), "transfer succeeds within the balance");

        vm.assertEq(token.balanceOf(to), amount, "receiver credited exactly");
        vm.assertEq(token.balanceOf(DEPLOYER), SUPPLY - amount, "sender debited exactly");
        vm.assertEq(token.balanceOf(to) + token.balanceOf(DEPLOYER), SUPPLY, "balances sum to the supply");
        vm.assertEq(token.totalSupply(), SUPPLY, "the supply is fixed");
    }

    function testFuzz_transferAboveTheBalanceReverts(uint256 excess) public {
        // Any amount strictly greater than the whole supply.
        uint256 amount = SUPPLY + 1 + (excess % (type(uint256).max - SUPPLY));

        vm.prank(DEPLOYER);
        vm.expectRevert(
            abi.encodeWithSelector(SqueekchainToken.ERC20InsufficientBalance.selector, DEPLOYER, SUPPLY, amount)
        );
        token.transfer(ALICE, amount);
    }

    function testFuzz_chainedTransfersConserveTheSupply(uint256 a, uint256 b, uint256 c) public {
        a = a % (SUPPLY + 1);
        b = b % (a + 1);
        c = c % (b + 1);

        vm.prank(DEPLOYER);
        token.transfer(ALICE, a);
        vm.prank(ALICE);
        token.transfer(BOB, b);
        vm.prank(BOB);
        token.transfer(CAROL, c);

        vm.assertEq(token.balanceOf(DEPLOYER), SUPPLY - a, "deployer");
        vm.assertEq(token.balanceOf(ALICE), a - b, "alice");
        vm.assertEq(token.balanceOf(BOB), b - c, "bob");
        vm.assertEq(token.balanceOf(CAROL), c, "carol");
        vm.assertEq(
            token.balanceOf(DEPLOYER) + token.balanceOf(ALICE) + token.balanceOf(BOB) + token.balanceOf(CAROL),
            SUPPLY,
            "balances sum to the supply"
        );
    }

    function testFuzz_transferFromRespectsTheAllowance(uint256 allowed, uint256 amount) public {
        allowed = allowed % SUPPLY; // strictly below the supply, so the balance is never the limit
        amount = amount % (SUPPLY + 1);

        vm.prank(DEPLOYER);
        token.approve(ALICE, allowed);

        if (amount > allowed) {
            vm.prank(ALICE);
            vm.expectRevert(
                abi.encodeWithSelector(SqueekchainToken.ERC20InsufficientAllowance.selector, ALICE, allowed, amount)
            );
            token.transferFrom(DEPLOYER, BOB, amount);
            vm.assertEq(token.allowance(DEPLOYER, ALICE), allowed, "allowance untouched after a revert");
            vm.assertEq(token.balanceOf(BOB), 0, "nothing moved");
        } else {
            vm.prank(ALICE);
            vm.assertTrue(token.transferFrom(DEPLOYER, BOB, amount), "spend within the allowance");
            vm.assertEq(token.allowance(DEPLOYER, ALICE), allowed - amount, "allowance reduced by the amount");
            vm.assertEq(token.balanceOf(BOB), amount, "receiver credited");
            vm.assertEq(token.balanceOf(DEPLOYER), SUPPLY - amount, "owner debited");
        }
        vm.assertEq(token.totalSupply(), SUPPLY, "the supply is fixed");
    }

    function testFuzz_approveOverwrites(address spender, uint256 first, uint256 second) public {
        vm.assume(spender != address(0));

        vm.prank(ALICE);
        token.approve(spender, first);
        vm.assertEq(token.allowance(ALICE, spender), first, "first allowance");

        vm.prank(ALICE);
        token.approve(spender, second);
        vm.assertEq(token.allowance(ALICE, spender), second, "second allowance replaces the first");
    }
}
