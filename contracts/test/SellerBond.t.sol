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
    /// Receives the agent NFT in the mid-timelock transfer scenario.
    address internal newOwner = makeAddr("newOwner");

    /// Arbitrary agent id — the value itself is meaningless, only the registry mapping
    /// gives it meaning. Chosen non-tiny so it can't accidentally collide with defaults.
    uint256 internal constant AGENT_ID = 851_889;

    /// 100 USDC in 6-decimal units — a comfortable default stake for tests.
    uint256 internal constant STAKE = 100e6;

    /// 40 USDC — a partial withdrawal, deliberately smaller than STAKE so tests can
    /// assert the *remaining* bond stays intact and free.
    uint256 internal constant WITHDRAW = 40e6;

    /// Mirror of the events under test. Solidity events can't be imported standalone, so
    /// tests re-declare them to use with vm.expectEmit.
    event Deposited(uint256 indexed agentId, address indexed from, uint256 amount);
    event WithdrawalRequested(uint256 indexed agentId, uint256 amount, uint64 unlockTime);
    event WithdrawalCompleted(uint256 indexed agentId, address indexed to, uint256 amount);
    event WithdrawalTimelockUpdated(uint64 previous, uint64 current);

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

    // -------------------------------------------------------- withdrawal helpers

    /// Shared precondition of every completion/timelock test: STAKE deposited and a
    /// WITHDRAW-sized request already in flight, both as `seller`. Returns the request's
    /// snapshotted unlockTime so tests can warp relative to it instead of re-deriving
    /// `block.timestamp + timelock` arithmetic in every test body.
    function _depositAndRequest() internal returns (uint64 unlockTime) {
        vm.startPrank(seller);
        bond.deposit(AGENT_ID, STAKE);
        bond.requestWithdrawal(AGENT_ID, WITHDRAW);
        vm.stopPrank();
        (, unlockTime) = bond.pendingWithdrawal(AGENT_ID);
    }

    // ------------------------------------------------------- requestWithdrawal

    /// Happy path: the request snapshots an absolute unlock time, immediately removes the
    /// amount from *free* bond, and leaves gross bond untouched (custody only moves at
    /// completion).
    function test_RequestWithdrawalSnapshotsUnlockAndReducesFreeBond() public {
        vm.prank(seller);
        bond.deposit(AGENT_ID, STAKE);

        uint64 expectedUnlock = uint64(block.timestamp) + bond.withdrawalTimelock();
        vm.expectEmit(true, false, false, true);
        emit WithdrawalRequested(AGENT_ID, WITHDRAW, expectedUnlock);

        vm.prank(seller);
        bond.requestWithdrawal(AGENT_ID, WITHDRAW);

        // Free bond drops NOW — this is what stops JobEscrow reserving exiting funds...
        assertEq(bond.bondOf(AGENT_ID), STAKE - WITHDRAW, "free bond should shrink at request time");
        // ...but the tokens themselves haven't moved yet.
        assertEq(bond.bondBalance(AGENT_ID), STAKE, "gross bond untouched until completion");
        (uint256 amount, uint64 unlockTime) = bond.pendingWithdrawal(AGENT_ID);
        assertEq(amount, WITHDRAW, "pending amount recorded");
        assertEq(unlockTime, expectedUnlock, "unlock time snapshotted");
    }

    /// Operators hold delegated authority over the agent, so they may start a withdrawal
    /// (they can never redirect its payout — see the completion tests).
    function test_RequestWithdrawalByOperator() public {
        vm.prank(seller);
        bond.deposit(AGENT_ID, STAKE);
        registry.setOperator(AGENT_ID, operator, true);

        vm.prank(operator);
        bond.requestWithdrawal(AGENT_ID, WITHDRAW);

        (uint256 amount,) = bond.pendingWithdrawal(AGENT_ID);
        assertEq(amount, WITHDRAW, "operator-initiated request should record");
    }

    /// A wallet with no relationship to the agent can't start pulling its stake out.
    function test_RevertWhen_RequestWithdrawalByStranger() public {
        vm.prank(seller);
        bond.deposit(AGENT_ID, STAKE);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SellerBond.NotAgentOwnerOrOperator.selector, AGENT_ID, stranger));
        bond.requestWithdrawal(AGENT_ID, WITHDRAW);
    }

    /// Zero-amount requests are rejected — amount == 0 is the "no request pending"
    /// sentinel, so a zero request must never be representable.
    function test_RevertWhen_RequestWithdrawalZero() public {
        vm.prank(seller);
        vm.expectRevert(SellerBond.ZeroAmount.selector);
        bond.requestWithdrawal(AGENT_ID, 0);
    }

    /// Can't request more than the free bond — the error reports what was actually free.
    function test_RevertWhen_RequestWithdrawalExceedsFreeBond() public {
        vm.prank(seller);
        bond.deposit(AGENT_ID, STAKE);

        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(SellerBond.InsufficientBond.selector, AGENT_ID, STAKE + 1, STAKE));
        bond.requestWithdrawal(AGENT_ID, STAKE + 1);
    }

    /// One request in flight per agent: a second request must wait for the first to
    /// complete, not silently replace or stack on it.
    function test_RevertWhen_RequestWithdrawalWhileOnePending() public {
        _depositAndRequest();

        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(SellerBond.WithdrawalAlreadyPending.selector, AGENT_ID));
        bond.requestWithdrawal(AGENT_ID, 1);
    }

    /// Unknown agent ids revert via the registry, same as deposit.
    function test_RevertWhen_RequestWithdrawalForNonexistentAgent() public {
        uint256 ghostAgent = 999_999;
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(MockIdentityRegistry.NonexistentAgent.selector, ghostAgent));
        bond.requestWithdrawal(ghostAgent, WITHDRAW);
    }

    /// Fuzz: for any request size the books stay balanced — free + pending == gross.
    /// This is the accounting identity bondOf() relies on to never underflow.
    function testFuzz_RequestWithdrawalNettingHolds(uint256 amount) public {
        amount = bound(amount, 1, STAKE);
        vm.startPrank(seller);
        bond.deposit(AGENT_ID, STAKE);
        bond.requestWithdrawal(AGENT_ID, amount);
        vm.stopPrank();

        (uint256 pending,) = bond.pendingWithdrawal(AGENT_ID);
        assertEq(bond.bondOf(AGENT_ID) + pending, bond.bondBalance(AGENT_ID), "free + pending must equal gross");
        assertEq(bond.bondOf(AGENT_ID), STAKE - amount, "free bond nets out the pending amount");
    }

    // ------------------------------------------------------ completeWithdrawal

    /// The timelock actually locks: one second before maturity is still too early.
    function test_RevertWhen_CompleteBeforeTimelockExpires() public {
        uint64 unlockTime = _depositAndRequest();

        vm.warp(unlockTime - 1); // jump the chain clock to just before maturity
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(SellerBond.TimelockNotExpired.selector, AGENT_ID, unlockTime));
        bond.completeWithdrawal(AGENT_ID);
    }

    /// Happy path at maturity: tokens return to the owner, the request clears, gross bond
    /// drops — and free bond is UNCHANGED, because it already excluded the pending amount
    /// from the moment of the request.
    function test_CompleteWithdrawalPaysOwnerAndClearsRequest() public {
        uint64 unlockTime = _depositAndRequest();
        uint256 freeBefore = bond.bondOf(AGENT_ID);

        vm.warp(unlockTime);
        vm.expectEmit(true, true, false, true);
        emit WithdrawalCompleted(AGENT_ID, seller, WITHDRAW);

        vm.prank(seller);
        bond.completeWithdrawal(AGENT_ID);

        assertEq(usdc.balanceOf(seller), WITHDRAW, "owner should receive the withdrawal");
        assertEq(usdc.balanceOf(address(bond)), STAKE - WITHDRAW, "contract custody should shrink");
        assertEq(bond.bondBalance(AGENT_ID), STAKE - WITHDRAW, "gross bond should shrink");
        assertEq(bond.bondOf(AGENT_ID), freeBefore, "free bond must not change at completion");
        (uint256 amount,) = bond.pendingWithdrawal(AGENT_ID);
        assertEq(amount, 0, "request should be cleared");
    }

    /// An operator may *trigger* completion, but the money still goes to the owner —
    /// a compromised operator key can never turn the bond into its own funds.
    function test_CompleteTriggeredByOperatorStillPaysOwner() public {
        uint64 unlockTime = _depositAndRequest();
        registry.setOperator(AGENT_ID, operator, true);

        vm.warp(unlockTime);
        vm.prank(operator);
        bond.completeWithdrawal(AGENT_ID);

        assertEq(usdc.balanceOf(seller), WITHDRAW, "payout goes to the owner");
        assertEq(usdc.balanceOf(operator), 0, "operator must receive nothing");
    }

    /// If the agent NFT changes wallets mid-timelock, the *current* owner at completion
    /// time is paid — stake travels with the agent, exactly like reputation does.
    function test_CompleteAfterAgentTransferPaysNewOwner() public {
        uint64 unlockTime = _depositAndRequest();
        registry.setAgentOwner(AGENT_ID, newOwner); // simulate the ERC-721 transfer

        vm.warp(unlockTime);
        vm.prank(newOwner); // old owner lost authorization along with the NFT
        bond.completeWithdrawal(AGENT_ID);

        assertEq(usdc.balanceOf(newOwner), WITHDRAW, "new owner should receive the stake");
        assertEq(usdc.balanceOf(seller), 0, "previous owner should receive nothing");
    }

    /// Completing with no request in flight is a distinct, descriptive error.
    function test_RevertWhen_CompleteWithNothingPending() public {
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(SellerBond.NoWithdrawalPending.selector, AGENT_ID));
        bond.completeWithdrawal(AGENT_ID);
    }

    // ---------------------------------------------------- setWithdrawalTimelock

    /// The plan's invariant 4: a global timelock change never retroactively touches an
    /// in-flight request — shortening to zero doesn't spring the old lock early.
    function test_TimelockChangeDoesNotAffectPendingRequest() public {
        uint64 unlockTime = _depositAndRequest();

        // The test contract deployed SellerBond in setUp, so it IS the owner here.
        bond.setWithdrawalTimelock(0);

        // Still locked at the originally snapshotted time...
        vm.warp(unlockTime - 1);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(SellerBond.TimelockNotExpired.selector, AGENT_ID, unlockTime));
        bond.completeWithdrawal(AGENT_ID);

        // ...and opens exactly when the snapshot said it would.
        vm.warp(unlockTime);
        vm.prank(seller);
        bond.completeWithdrawal(AGENT_ID);
        assertEq(usdc.balanceOf(seller), WITHDRAW, "original schedule should still pay out");
    }

    /// The flip side: a request made AFTER the change uses the new timelock — here zero,
    /// so it matures immediately (the demo-recording configuration).
    function test_NewRequestUsesUpdatedTimelock() public {
        bond.setWithdrawalTimelock(0);
        vm.startPrank(seller);
        bond.deposit(AGENT_ID, STAKE);
        bond.requestWithdrawal(AGENT_ID, WITHDRAW);
        bond.completeWithdrawal(AGENT_ID); // no warp: unlockTime == now
        vm.stopPrank();

        assertEq(usdc.balanceOf(seller), WITHDRAW, "zero timelock should allow immediate completion");
    }

    /// Setter happy path: event reports old and new values, state updates.
    function test_SetWithdrawalTimelockEmitsAndApplies() public {
        vm.expectEmit(false, false, false, true);
        emit WithdrawalTimelockUpdated(3 days, 1 hours);
        bond.setWithdrawalTimelock(1 hours);
        assertEq(bond.withdrawalTimelock(), 1 hours, "timelock should update");
    }

    /// Only the contract owner may tune the risk parameter.
    function test_RevertWhen_SetTimelockNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert(SellerBond.NotOwner.selector);
        bond.setWithdrawalTimelock(1 hours);
    }

    /// The 30-day ceiling holds — bounding what a compromised owner key could freeze.
    function test_RevertWhen_SetTimelockAboveMax() public {
        uint64 tooLong = 30 days + 1;
        vm.expectRevert(abi.encodeWithSelector(SellerBond.TimelockTooLong.selector, tooLong, uint64(30 days)));
        bond.setWithdrawalTimelock(tooLong);
    }
}
