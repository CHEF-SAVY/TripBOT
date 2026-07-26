// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SellerBond} from "../src/SellerBond.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockIdentityRegistry} from "./mocks/MockIdentityRegistry.sol";

/// @title SellerBondTest — unit tests for SellerBond against mocked externals
/// @notice Each function of SellerBond gets its own block of tests, added in the same
/// change that implements the function. Naming follows the Foundry convention:
/// `test_Description` for happy paths, `test_RevertWhen_Condition` for failure paths.
contract SellerBondTest is Test {
    // ------------------------------------------------------------------ fixtures

    MockUSDC internal usdc;
    MockIdentityRegistry internal registry;
    SellerBond internal bond;

    /// Stable, readable actor addresses. makeAddr derives a fresh address from a label
    /// and registers the label with forge's tracer, so failure logs show "seller"
    /// instead of 0x7fa9385b....
    address internal seller = makeAddr("seller");
    address internal operator = makeAddr("operator");
    address internal stranger = makeAddr("stranger");
    address internal jobEscrow = makeAddr("jobEscrow");

    /// Arbitrary agent id — the value itself is meaningless, only the registry mapping
    /// gives it meaning. Chosen non-tiny so it can't accidentally collide with defaults.
    uint256 internal constant AGENT_ID = 851_889;

    /// 100 USDC in 6-decimal units — a comfortable default stake for tests.
    uint256 internal constant STAKE = 100e6;

    /// Mirror of the events under test. Solidity events can't be imported standalone, so
    /// tests re-declare them to use with vm.expectEmit.
    event Deposited(uint256 indexed agentId, address indexed from, uint256 amount);

    /// Fresh state before every test: new token, new registry, new SellerBond wired to
    /// them, one registered agent owned by `seller`, who holds STAKE USDC and has already
    /// approved the bond contract (the approve step is a precondition of deposit, not the
    /// behaviour under test).
    function setUp() public {
        usdc = new MockUSDC();
        registry = new MockIdentityRegistry();
        bond = new SellerBond(address(usdc), address(registry), jobEscrow);

        registry.setAgentOwner(AGENT_ID, seller);
        usdc.mint(seller, STAKE);
        vm.prank(seller); // next call executes as `seller`
        usdc.approve(address(bond), type(uint256).max);
    }

    // ------------------------------------------------------------------ deposit

    /// The core happy path: money moves in, bookkeeping matches, event fires.
    function test_DepositCreditsBondAndPullsUSDC() public {
        // expectEmit arms a check that the *next* call emits exactly this event.
        vm.expectEmit(true, true, false, true);
        emit Deposited(AGENT_ID, seller, STAKE);

        vm.prank(seller);
        bond.deposit(AGENT_ID, STAKE);

        // Bookkeeping: the agent's gross bond reflects the deposit...
        assertEq(bond.bondBalance(AGENT_ID), STAKE, "bond not credited");
        // ...and with nothing reserved or pending, all of it is free.
        assertEq(bond.bondOf(AGENT_ID), STAKE, "free bond should equal gross");
        // Custody: the tokens physically moved from seller to the contract.
        assertEq(usdc.balanceOf(address(bond)), STAKE, "contract should hold the stake");
        assertEq(usdc.balanceOf(seller), 0, "seller should have paid the stake");
    }

    /// Deposits accumulate — a second deposit adds to, not replaces, the first.
    function test_DepositAccumulatesAcrossCalls() public {
        usdc.mint(seller, STAKE); // top the seller back up for a second deposit

        vm.startPrank(seller); // every call until stopPrank executes as `seller`
        bond.deposit(AGENT_ID, STAKE);
        bond.deposit(AGENT_ID, STAKE);
        vm.stopPrank();

        assertEq(bond.bondBalance(AGENT_ID), 2 * STAKE, "deposits should accumulate");
    }

    /// An approved operator (delegated via the registry) may fund the bond — "owner or
    /// operator" is exactly the authority the Identity Registry models.
    function test_DepositByApprovedOperator() public {
        registry.setOperator(AGENT_ID, operator, true);
        usdc.mint(operator, STAKE);
        vm.startPrank(operator);
        usdc.approve(address(bond), STAKE);
        bond.deposit(AGENT_ID, STAKE);
        vm.stopPrank();

        assertEq(bond.bondBalance(AGENT_ID), STAKE, "operator deposit should credit bond");
    }

    /// A wallet with no relationship to the agent must be rejected — the bond must be
    /// the seller's own stake (the project's core economic promise).
    function test_RevertWhen_DepositorIsNotOwnerOrOperator() public {
        usdc.mint(stranger, STAKE);
        vm.startPrank(stranger);
        usdc.approve(address(bond), STAKE);
        // expectRevert checks the *next* call reverts with exactly this custom error and
        // arguments — asserting the caller and agent are reported back correctly.
        vm.expectRevert(abi.encodeWithSelector(SellerBond.NotAgentOwnerOrOperator.selector, AGENT_ID, stranger));
        bond.deposit(AGENT_ID, STAKE);
        vm.stopPrank();
    }

    /// Depositing to an agent id that was never registered must revert — the registry's
    /// own revert doubles as SellerBond's existence check.
    function test_RevertWhen_DepositToNonexistentAgent() public {
        uint256 ghostAgent = 999_999;
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(MockIdentityRegistry.NonexistentAgent.selector, ghostAgent));
        bond.deposit(ghostAgent, STAKE);
    }

    /// Zero-amount deposits are rejected outright.
    function test_RevertWhen_DepositZero() public {
        vm.prank(seller);
        vm.expectRevert(SellerBond.ZeroAmount.selector);
        bond.deposit(AGENT_ID, 0);
    }

    /// Without an allowance the token itself aborts the pull — proving deposit cannot
    /// credit bond it never received.
    function test_RevertWhen_DepositWithoutAllowance() public {
        vm.prank(seller);
        usdc.approve(address(bond), 0); // cancel setUp's blanket approval

        vm.prank(seller);
        vm.expectRevert(); // exact error comes from OZ's ERC20; its shape isn't ours to pin
        bond.deposit(AGENT_ID, STAKE);

        assertEq(bond.bondBalance(AGENT_ID), 0, "failed pull must not credit bond");
    }

    // ------------------------------------------------------------------ bondOf

    /// bondOf on an agent nobody funded is simply zero — no revert, no magic.
    function test_BondOfUnfundedAgentIsZero() public view {
        assertEq(bond.bondOf(AGENT_ID), 0);
    }

    /// Fuzz: for any deposit amount, free bond equals gross while nothing is reserved
    /// or pending. (The interesting netting cases arrive with requestWithdrawal/reserve —
    /// tested alongside those functions.)
    function testFuzz_BondOfEqualsBalanceWhenNothingLocked(uint256 amount) public {
        // bound() constrains the fuzzed input to a sane range (1 wei .. 1B USDC) —
        // preferred over vm.assume per Foundry best practices.
        amount = bound(amount, 1, 1e15);
        usdc.mint(seller, amount);
        vm.prank(seller);
        bond.deposit(AGENT_ID, amount);
        assertEq(bond.bondOf(AGENT_ID), bond.bondBalance(AGENT_ID));
    }
}
