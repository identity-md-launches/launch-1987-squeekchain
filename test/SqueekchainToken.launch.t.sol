// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TestBase} from "./support/TestBase.sol";
import {SqueekchainToken} from "../src/SqueekchainToken.sol";

/// @notice Stands in for the launch factory. It deploys the token with CREATE2 inside one call,
/// exactly as `launchCustom` does in one transaction, and then performs the launch's transfers
/// as the factory's own `msg.sender`. Only the test that built it may drive it.
contract FactoryProbe {
    address private immutable controller = msg.sender;

    modifier onlyController() {
        require(msg.sender == controller, "not the harness");
        _;
    }

    /// @dev Deploys the creation code at `salt` and checks, still inside the same call, that the
    /// constructor minted the expected supply to this contract and nothing else.
    function deploy(bytes memory code, bytes32 salt, uint256 expectedSupply)
        external
        onlyController
        returns (address deployed)
    {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0) && deployed.code.length > 0, "constructor failed");
        SqueekchainToken token = SqueekchainToken(deployed);
        require(token.totalSupply() == expectedSupply, "manifest supply mismatch");
        require(token.balanceOf(address(this)) == expectedSupply, "the constructor did not mint here");
    }

    /// @dev Deploys with plain CREATE, the other way a contract can be the deployer.
    function deployWithCreate() external onlyController returns (SqueekchainToken token) {
        token = new SqueekchainToken();
    }

    function move(SqueekchainToken token, address to, uint256 amount) external onlyController returns (bool) {
        return token.transfer(to, amount);
    }

    function approve(SqueekchainToken token, address spender, uint256 amount) external onlyController returns (bool) {
        return token.approve(spender, amount);
    }
}

/// @notice The launch as the factory performs it, without the pool: the token is deployed by a
/// contract in one call, the whole supply lands at that contract, ten percent goes to the
/// distributor and is claimable whole, eighty percent is pulled by a pool stand-in through an
/// allowance, and the remainder is forwarded. Every flow must move exactly what it says.
contract SqueekchainTokenLaunchTest is TestBase {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    uint256 internal constant SWARM_BPS = 1_000;
    uint256 internal constant POOL_BPS = 8_000;
    uint64 internal constant LAUNCH_NUMBER = 42;

    address internal constant DISTRIBUTOR = address(0xD157);
    address internal constant CLAIMANT = address(0xC1A1);
    address internal constant POOL = address(0x900C);
    address internal constant REQUESTER = address(0x5EC1);
    address internal constant HOLDER = address(0x401D);
    address internal constant OTHER = address(0x07E5);

    FactoryProbe internal factory;
    SqueekchainToken internal token;

    function setUp() public {
        factory = new FactoryProbe();
        bytes memory code = type(SqueekchainToken).creationCode;
        bytes32 salt = bytes32(uint256(LAUNCH_NUMBER));
        address predicted = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, keccak256(code)))))
        );
        address deployed = factory.deploy(code, salt, SUPPLY);
        vm.assertEq(deployed, predicted, "CREATE2 address prediction");
        token = SqueekchainToken(deployed);
        vm.label(address(factory), "factory");
        vm.label(address(token), "SQK");
    }

    // ---------------------------------------------------------------------------------------------
    // Deployment by a contract
    // ---------------------------------------------------------------------------------------------

    function test_constructorTakesNoArgumentsAndMintsToTheDeployingContract() public view {
        vm.assertEq(token.totalSupply(), SUPPLY, "manifest supply");
        vm.assertEq(token.balanceOf(address(factory)), SUPPLY, "the factory holds the whole supply");
        vm.assertEq(token.balanceOf(address(this)), 0, "the test, which called the factory, holds nothing");
        vm.assertEq(token.balanceOf(address(token)), 0, "the token holds nothing of itself");
    }

    function test_creationCodeHasNoConstructorArguments() public {
        // Appending arguments to the creation code must not change what is deployed: the
        // constructor ignores them, so the manifest's `constructorArgs: []` is the only valid form.
        bytes memory bare = type(SqueekchainToken).creationCode;
        address a = factory.deploy(bare, bytes32(uint256(1)), SUPPLY);
        address b = factory.deploy(abi.encodePacked(bare, abi.encode(address(0xBEEF))), bytes32(uint256(2)), SUPPLY);
        vm.assertEq(a.codehash, b.codehash, "runtime is independent of trailing arguments");
        vm.assertEq(SqueekchainToken(a).balanceOf(address(factory)), SUPPLY, "first deployment minted to the factory");
        vm.assertEq(SqueekchainToken(b).balanceOf(address(factory)), SUPPLY, "second deployment minted to the factory");
    }

    function test_deployingWithCreateAlsoMintsToTheDeployingContract() public {
        SqueekchainToken second = factory.deployWithCreate();
        vm.assertNotEq(address(second), address(token), "a fresh instance");
        vm.assertEq(second.balanceOf(address(factory)), SUPPLY, "minted to the factory");
        vm.assertEq(second.totalSupply(), SUPPLY, "its own fixed supply");
        // Instances are independent: the first token's balances are untouched.
        vm.assertEq(token.balanceOf(address(factory)), SUPPLY, "the first instance is unaffected");
    }

    function test_deployerThatExpectsADifferentSupplyIsRefused() public {
        vm.expectRevert("manifest supply mismatch");
        factory.deploy(type(SqueekchainToken).creationCode, bytes32(uint256(7)), SUPPLY + 1);
    }

    // ---------------------------------------------------------------------------------------------
    // The launch flows move exactly what they say
    // ---------------------------------------------------------------------------------------------

    function test_theSwarmShareArrivesWholeAndIsClaimableWhole() public {
        uint256 swarm = (SUPPLY * SWARM_BPS) / 10_000;
        vm.assertTrue(factory.move(token, DISTRIBUTOR, swarm), "transfer to the distributor returned false");
        vm.assertEq(token.balanceOf(DISTRIBUTOR), swarm, "the swarm's share arrived short");
        vm.assertEq(token.balanceOf(address(factory)), SUPPLY - swarm, "the factory paid exactly the share");

        vm.prank(DISTRIBUTOR);
        vm.assertTrue(token.transfer(CLAIMANT, swarm), "the claim returned false");
        vm.assertEq(token.balanceOf(CLAIMANT), swarm, "a claim arrived short");
        vm.assertEq(token.balanceOf(DISTRIBUTOR), 0, "the distributor kept something back");
        vm.assertEq(token.totalSupply(), SUPPLY, "the launch flows changed the supply");
    }

    function test_thePoolShareCanBePulledThroughAnAllowanceWhole() public {
        uint256 swarm = (SUPPLY * SWARM_BPS) / 10_000;
        uint256 pool = (SUPPLY * POOL_BPS) / 10_000;
        factory.move(token, DISTRIBUTOR, swarm);

        // The pool manager settles by pulling from the factory under an allowance.
        vm.assertTrue(factory.approve(token, POOL, pool), "approve returned false");
        vm.prank(POOL);
        vm.assertTrue(token.transferFrom(address(factory), POOL, pool), "the seed pull returned false");
        vm.assertEq(token.balanceOf(POOL), pool, "the seed arrived short");
        vm.assertEq(token.allowance(address(factory), POOL), 0, "the allowance was spent exactly");

        // The remainder goes to the requester and is exactly what is left.
        uint256 remainder = SUPPLY - swarm - pool;
        vm.assertEq(token.balanceOf(address(factory)), remainder, "the remainder is not what is left");
        vm.assertTrue(factory.move(token, REQUESTER, remainder), "forwarding the remainder returned false");
        vm.assertEq(token.balanceOf(REQUESTER), remainder, "the remainder arrived short");
        vm.assertEq(token.balanceOf(address(factory)), 0, "the factory kept something back");
        vm.assertEq(
            token.balanceOf(DISTRIBUTOR) + token.balanceOf(POOL) + token.balanceOf(REQUESTER),
            SUPPLY,
            "the three shares account for the whole supply"
        );
    }

    function test_thePoolCanSellBackToATraderAndBuyAgain() public {
        // A trader buys from the pool and sells back: both legs are ordinary transfers and move
        // exactly the amount, so a swap can never arrive short.
        uint256 pool = (SUPPLY * POOL_BPS) / 10_000;
        factory.move(token, POOL, pool);
        uint256 bought = 12_345 * 10 ** 18;

        vm.prank(POOL);
        token.transfer(HOLDER, bought);
        vm.assertEq(token.balanceOf(HOLDER), bought, "the buy arrived short");

        vm.prank(HOLDER);
        token.approve(POOL, bought);
        vm.prank(POOL);
        token.transferFrom(HOLDER, POOL, bought);
        vm.assertEq(token.balanceOf(HOLDER), 0, "the sell left dust");
        vm.assertEq(token.balanceOf(POOL), pool, "the pool is whole again");
    }

    function test_theFactoryHasNoHandOverAHolderAfterLaunch() public {
        uint256 held = SUPPLY / 1_000;
        factory.move(token, HOLDER, held);

        // The factory, the address a token would most plausibly trust, cannot pull without an allowance.
        vm.prank(address(factory));
        vm.expectRevert(
            abi.encodeWithSelector(
                SqueekchainToken.ERC20InsufficientAllowance.selector, address(factory), uint256(0), uint256(1)
            )
        );
        token.transferFrom(HOLDER, address(factory), 1);

        vm.assertEq(token.balanceOf(HOLDER), held, "the holder still holds what it held");
        vm.prank(HOLDER);
        vm.assertTrue(token.transfer(OTHER, held / 2), "the holder can still transfer");
        vm.assertEq(token.balanceOf(OTHER), held / 2, "the holder's transfer delivered");
    }

    function test_onlyTheHarnessDrivesTheProbe() public {
        vm.prank(OTHER);
        vm.expectRevert("not the harness");
        factory.move(token, OTHER, 1);
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzz: any split of the supply among the launch's three recipients is exact
    // ---------------------------------------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_anySplitOfTheSupplyIsExact(uint256 swarmBps, uint256 poolBps) public {
        swarmBps = swarmBps % 10_001;
        poolBps = poolBps % (10_001 - swarmBps);
        uint256 swarm = (SUPPLY * swarmBps) / 10_000;
        uint256 pool = (SUPPLY * poolBps) / 10_000;
        uint256 remainder = SUPPLY - swarm - pool;

        factory.move(token, DISTRIBUTOR, swarm);
        factory.move(token, POOL, pool);
        factory.move(token, REQUESTER, remainder);

        vm.assertEq(token.balanceOf(DISTRIBUTOR), swarm, "swarm share");
        vm.assertEq(token.balanceOf(POOL), pool, "pool share");
        vm.assertEq(token.balanceOf(REQUESTER), remainder, "remainder");
        vm.assertEq(token.balanceOf(address(factory)), 0, "nothing is left at the factory");
        vm.assertEq(token.totalSupply(), SUPPLY, "the supply is fixed");
    }
}
