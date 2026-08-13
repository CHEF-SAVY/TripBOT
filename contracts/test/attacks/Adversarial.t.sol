// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {JobEscrow} from "../../src/JobEscrow.sol";
import {SellerBond} from "../../src/SellerBond.sol";
import {IdentityRegistry} from "../../src/registries/IdentityRegistry.sol";
import {ValidationRegistry} from "../../src/registries/ValidationRegistry.sol";
import {
    HostileIdentityRegistry,
    ImpostorBond,
    ReentrantBondHolder,
    ReentrantBuyer,
    ReentrantSeller,
    TogglingSeller
} from "./Attackers.sol";

/// @title AdversarialTest — attacker's-eye view of the escrow stack
/// @notice Written from the attacker's side rather than the specification's. Each test states
/// the theft it is attempting and asserts that the money did not move, rather than asserting
/// that some particular error was raised: what matters is the balance, not the revert string.
///
/// The whole stack is real here — real IdentityRegistry, real ValidationRegistry, real
/// SellerBond, real JobEscrow. Mocks would prove nothing about an attack, because the mock is
/// exactly the component an attacker would be trying to subvert.
contract AdversarialTest is Test {
    IdentityRegistry internal identity;
    ValidationRegistry internal validation;
    JobEscrow internal escrow;
    SellerBond internal bond;

    address internal deployer = makeAddr("deployer");
    address internal buyer = makeAddr("buyer");
    address internal seller = makeAddr("seller");
    address internal attacker = makeAddr("attacker");

    uint256 internal sellerAgentId;
    uint256 internal attackerAgentId;

    uint256 internal constant AMOUNT = 10 ether;
    uint256 internal constant STAKE = 20 ether;

    function setUp() public {
        vm.startPrank(deployer);
        identity = new IdentityRegistry();
        validation = new ValidationRegistry(address(identity));
        escrow = new JobEscrow(address(identity), address(validation), deployer);
        bond = new SellerBond(address(identity), address(escrow));
        escrow.setSellerBond(address(bond));
        // Attestation is orthogonal to every theft attempted here, and leaving it on would
        // force each test to mint a real validation request just to reach the code under
        // attack. The registry's own authorization is attacked directly in its own section.
        escrow.setValidationRegistryEnabled(false);
        vm.stopPrank();

        vm.prank(seller);
        sellerAgentId = identity.register();
        vm.prank(attacker);
        attackerAgentId = identity.register();

        vm.deal(buyer, 1_000 ether);
        vm.deal(seller, 1_000 ether);
        vm.deal(attacker, 1_000 ether);

        vm.prank(seller);
        bond.deposit{value: STAKE}(sellerAgentId);
    }

    function _openJob() internal returns (uint256 jobId) {
        vm.prank(buyer);
        jobId = escrow.createJob{value: AMOUNT}(sellerAgentId, uint64(block.timestamp + 1 days), bytes32(0));
    }

    // ================================================================ escrow drain

    /// Attack: settle a job the attacker has nothing to do with.
    function test_Attack_CannotReleaseSomeoneElsesJob() public {
        uint256 jobId = _openJob();
        uint256 before = address(escrow).balance;

        vm.prank(attacker);
        vm.expectRevert();
        escrow.release(jobId);

        assertEq(address(escrow).balance, before, "escrow drained by a stranger's release");
    }

    /// Attack: rule on a dispute without being the arbiter, paying yourself.
    function test_Attack_CannotResolveWithoutBeingArbiter() public {
        uint256 jobId = _openJob();
        vm.prank(buyer);
        escrow.dispute(jobId, keccak256("evidence"));

        uint256 before = address(escrow).balance;
        vm.prank(attacker);
        vm.expectRevert();
        escrow.resolveDispute(jobId, true);

        assertEq(address(escrow).balance, before, "escrow drained by an unauthorized ruling");
    }

    /// Attack: claim the timeout payout before the window has elapsed.
    function test_Attack_CannotClaimTimeoutEarly() public {
        uint256 jobId = _openJob();
        uint256 before = address(escrow).balance;

        vm.prank(attacker);
        vm.expectRevert();
        escrow.claimTimeout(jobId);

        assertEq(address(escrow).balance, before, "escrow paid out before the response window");
    }

    /// Attack: take the money twice by releasing and then timing the same job out.
    function test_Attack_CannotSettleTheSameJobTwice() public {
        uint256 jobId = _openJob();
        vm.prank(buyer);
        escrow.release(jobId);

        uint256 afterRelease = address(escrow).balance;
        vm.warp(block.timestamp + 365 days);
        vm.prank(attacker);
        vm.expectRevert();
        escrow.claimTimeout(jobId);

        assertEq(address(escrow).balance, afterRelease, "job settled twice");
    }

    /// Attack: a seller contract re-enters release() while being paid, to be paid again.
    function test_Attack_ReentrantSellerCannotDoubleRelease() public {
        ReentrantSeller evil = new ReentrantSeller(escrow);
        vm.prank(address(evil));
        uint256 evilAgent = identity.register();
        vm.deal(address(evil), 100 ether);
        vm.prank(address(evil));
        bond.deposit{value: STAKE}(evilAgent);

        vm.prank(buyer);
        uint256 jobId = escrow.createJob{value: AMOUNT}(evilAgent, uint64(block.timestamp + 1 days), bytes32(0));

        evil.arm(jobId, 0);
        uint256 escrowBefore = address(escrow).balance;

        vm.prank(buyer);
        escrow.release(jobId);

        assertGt(evil.reentryAttempts(), 0, "attacker never got control - test is not exercising reentrancy");
        assertFalse(evil.reentryStatus(), "reentrant release succeeded");
        assertEq(address(escrow).balance, escrowBefore - AMOUNT, "escrow paid more than the job amount");
        assertEq(address(evil).balance, 100 ether - STAKE + AMOUNT, "attacker received more than one payout");
    }

    /// Attack: re-enter claimTimeout from inside the timeout payout itself.
    function test_Attack_ReentrantSellerCannotDoubleTimeout() public {
        ReentrantSeller evil = new ReentrantSeller(escrow);
        vm.prank(address(evil));
        uint256 evilAgent = identity.register();
        vm.deal(address(evil), 100 ether);
        vm.prank(address(evil));
        bond.deposit{value: STAKE}(evilAgent);

        vm.prank(buyer);
        uint256 jobId = escrow.createJob{value: AMOUNT}(evilAgent, uint64(block.timestamp + 1 days), bytes32(0));

        vm.warp(block.timestamp + 365 days);
        evil.arm(jobId, 1);
        uint256 escrowBefore = address(escrow).balance;

        escrow.claimTimeout(jobId);

        assertGt(evil.reentryAttempts(), 0, "attacker never got control");
        assertFalse(evil.reentryStatus(), "reentrant timeout succeeded");
        assertEq(address(escrow).balance, escrowBefore - AMOUNT, "escrow paid twice on timeout");
    }

    /// Attack: settle a *different* job by re-entering while being paid for this one.
    function test_Attack_ReentrantSellerCannotSettleASecondJob() public {
        ReentrantSeller evil = new ReentrantSeller(escrow);
        vm.prank(address(evil));
        uint256 evilAgent = identity.register();
        vm.deal(address(evil), 200 ether);
        vm.prank(address(evil));
        bond.deposit{value: 100 ether}(evilAgent);

        vm.startPrank(buyer);
        uint256 jobA = escrow.createJob{value: AMOUNT}(evilAgent, uint64(block.timestamp + 1 days), bytes32(0));
        uint256 jobB = escrow.createJob{value: AMOUNT}(evilAgent, uint64(block.timestamp + 1 days), bytes32(0));
        vm.stopPrank();

        // Paid for job A, try to also settle job B inside the same call.
        evil.arm(jobB, 0);
        uint256 escrowBefore = address(escrow).balance;

        vm.prank(buyer);
        escrow.release(jobA);

        assertGt(evil.reentryAttempts(), 0, "attacker never got control");
        assertFalse(evil.reentryStatus(), "cross-job reentrancy settled a second job");
        assertEq(address(escrow).balance, escrowBefore - AMOUNT, "more than one job's escrow left the contract");

        (,,,,,,, JobEscrow.JobStatus statusB,,) = escrow.jobs(jobB);
        assertEq(uint8(statusB), uint8(JobEscrow.JobStatus.Active), "job B was settled by reentrancy");
    }

    /// Attack: bank a pull-payment credit by refusing the push, then re-enter withdrawPayout
    /// while it pays out, to collect the same credit twice.
    function test_Attack_CannotDrainPendingPayoutsByReentry() public {
        TogglingSeller evil = new TogglingSeller(escrow);
        vm.prank(address(evil));
        uint256 evilAgent = identity.register();
        vm.deal(address(evil), 100 ether);
        vm.prank(address(evil));
        bond.deposit{value: STAKE}(evilAgent);

        vm.prank(buyer);
        uint256 jobId = escrow.createJob{value: AMOUNT}(evilAgent, uint64(block.timestamp + 1 days), bytes32(0));

        // Refusing the push forces the payout into the pull-payment ledger.
        vm.prank(buyer);
        escrow.release(jobId);

        uint256 credited = escrow.pendingPayouts(address(evil));
        assertEq(credited, AMOUNT, "credit was never banked - the attack path is not reachable");

        evil.stopRefusing();
        evil.arm();
        uint256 escrowBefore = address(escrow).balance;
        uint256 attackerBefore = address(evil).balance;

        evil.withdrawPayout();

        assertGt(evil.reentryAttempts(), 0, "attacker never got control");
        assertFalse(evil.reentryStatus(), "reentrant withdrawPayout succeeded");
        assertEq(escrow.pendingPayouts(address(evil)), 0, "credit not cleared");
        assertEq(address(escrow).balance, escrowBefore - credited, "withdrew more than the credit");
        assertEq(address(evil).balance, attackerBefore + credited, "attacker collected the credit twice");
    }

    /// Attack: fund one job, then reuse the same validation request to open a second.
    function test_Attack_CannotReuseAValidationRequestForTwoJobs() public {
        vm.prank(deployer);
        escrow.setValidationRegistryEnabled(true);

        vm.prank(seller);
        bytes32 requestHash = validation.validationRequest(address(escrow), sellerAgentId, "urn:job:1");

        vm.prank(buyer);
        escrow.createJob{value: AMOUNT}(sellerAgentId, uint64(block.timestamp + 1 days), requestHash);

        vm.prank(buyer);
        vm.expectRevert();
        escrow.createJob{value: AMOUNT}(sellerAgentId, uint64(block.timestamp + 1 days), requestHash);
    }

    // ================================================================== bond drain

    /// Attack: slash a seller's stake directly, bypassing JobEscrow entirely.
    function test_Attack_CannotSlashDirectly() public {
        uint256 before = bond.bondBalance(sellerAgentId);

        vm.prank(attacker);
        vm.expectRevert();
        bond.slash(sellerAgentId, before, attacker);

        assertEq(bond.bondBalance(sellerAgentId), before, "stake slashed without going through escrow");
    }

    /// Attack: reserve or release another agent's collateral directly.
    function test_Attack_CannotReserveOrReleaseDirectly() public {
        vm.startPrank(attacker);
        vm.expectRevert();
        bond.reserve(sellerAgentId, 1 ether);
        vm.expectRevert();
        bond.releaseReservation(sellerAgentId, 1 ether);
        vm.stopPrank();

        assertEq(bond.reserved(sellerAgentId), 0, "reservation state moved by a stranger");
    }

    /// Attack: withdraw a stake belonging to an agent the attacker does not own.
    function test_Attack_CannotWithdrawAnotherAgentsStake() public {
        uint256 before = bond.bondBalance(sellerAgentId);

        vm.prank(attacker);
        vm.expectRevert();
        bond.requestWithdrawal(sellerAgentId, before);

        assertEq(bond.bondBalance(sellerAgentId), before, "stake withdrawn by a non-owner");
    }

    /// Attack: withdraw collateral that is reserved against a live job.
    function test_Attack_CannotWithdrawReservedCollateral() public {
        _openJob();
        uint256 reserved = bond.reserved(sellerAgentId);
        assertGt(reserved, 0, "nothing reserved - test is not exercising the guard");

        // Read before the cheatcodes: an inline call here would consume both the prank and
        // the expectRevert, and the staticcall's success would be mistaken for the guard
        // failing to fire.
        uint256 gross = bond.bondBalance(sellerAgentId);
        assertGt(gross, bond.bondOf(sellerAgentId), "free bond should already be below gross");

        vm.prank(seller);
        vm.expectRevert();
        bond.requestWithdrawal(sellerAgentId, gross);

        assertEq(bond.reserved(sellerAgentId), reserved, "reserved collateral was withdrawn");
    }

    /// Attack: re-enter completeWithdrawal while the payout is in flight, to withdraw twice.
    function test_Attack_ReentrantWithdrawalCannotDoubleSpend() public {
        ReentrantBondHolder evil = new ReentrantBondHolder(bond);
        vm.prank(address(evil));
        uint256 evilAgent = identity.register();
        vm.deal(address(evil), 100 ether);
        evil.deposit{value: 50 ether}(evilAgent);

        evil.requestWithdrawal(evilAgent, 50 ether);
        vm.warp(block.timestamp + 30 days);

        evil.arm(evilAgent);
        uint256 bondBefore = address(bond).balance;
        evil.completeWithdrawal(evilAgent);

        assertFalse(evil.reentryStatus(), "reentrant withdrawal succeeded");
        assertEq(address(bond).balance, bondBefore - 50 ether, "bond paid out more than was requested");
        assertEq(bond.bondBalance(evilAgent), 0, "accounting diverged from the payout");
    }

    /// Attack: have the escrow slash more than the job ever reserved.
    function test_Attack_EscrowCannotSlashBeyondTheReservation() public {
        uint256 jobId = _openJob();
        uint256 reserved = bond.reserved(sellerAgentId);

        vm.prank(buyer);
        escrow.dispute(jobId, keccak256("evidence"));
        vm.prank(deployer);
        escrow.resolveDispute(jobId, true);

        assertEq(bond.bondBalance(sellerAgentId), STAKE - reserved, "more than the reservation was slashed");
        assertEq(bond.reserved(sellerAgentId), 0, "reservation left dangling after the slash");
    }

    // ==================================================== identity registry bypass

    /// Attack: post bond against an agent the attacker does not own, then withdraw it.
    function test_Attack_CannotDepositBondForAnAgentYouDoNotOwn() public {
        vm.prank(attacker);
        vm.expectRevert();
        bond.deposit{value: 1 ether}(sellerAgentId);
    }

    /// Attack: register a validation request for someone else's agent, naming the escrow as
    /// validator, so a job can be opened against an agent the attacker does not control.
    function test_Attack_CannotRegisterValidationForAnotherAgent() public {
        vm.prank(attacker);
        vm.expectRevert();
        validation.validationRequest(address(escrow), sellerAgentId, "urn:stolen");
    }

    /// Attack: answer a validation request the attacker is not the named validator for.
    function test_Attack_CannotRespondToAValidationRequest() public {
        vm.prank(seller);
        bytes32 requestHash = validation.validationRequest(address(escrow), sellerAgentId, "urn:job");

        vm.prank(attacker);
        vm.expectRevert();
        validation.validationResponse(requestHash, 0, "", bytes32(0), "SELLER_AT_FAULT");
    }

    /// Attack: approve yourself as an operator on an agent you do not own.
    function test_Attack_CannotSelfApproveAsOperator() public {
        vm.prank(attacker);
        vm.expectRevert();
        identity.setOperator(sellerAgentId, attacker, true);

        assertFalse(identity.isOperator(sellerAgentId, attacker), "attacker approved itself");
    }

    /// Attack: an operator legitimately approved by the seller tries to redirect the stake to
    /// itself. Authority to manage the bond must not imply ownership of the proceeds.
    function test_Attack_OperatorCannotRedirectTheStakeToItself() public {
        vm.prank(seller);
        identity.setOperator(sellerAgentId, attacker, true);

        vm.prank(attacker);
        bond.requestWithdrawal(sellerAgentId, STAKE);
        vm.warp(block.timestamp + 30 days);

        uint256 attackerBefore = attacker.balance;
        uint256 sellerBefore = seller.balance;
        vm.prank(attacker);
        bond.completeWithdrawal(sellerAgentId);

        assertEq(attacker.balance, attackerBefore, "operator received the stake");
        assertEq(seller.balance, sellerBefore + STAKE, "stake did not go to the agent owner");
    }

    /// Attack: swap the escrow's bond contract for an impostor that reports fake collateral.
    function test_Attack_CannotRepointTheEscrowAtAnImpostorBond() public {
        ImpostorBond impostor = new ImpostorBond(address(escrow), address(identity));

        vm.prank(deployer);
        vm.expectRevert();
        escrow.setSellerBond(address(impostor));

        assertEq(address(escrow.sellerBond()), address(bond), "escrow was repointed");
    }

    /// Attack: stand up a parallel escrow wired to a registry that lies about ownership, and
    /// use it to move the real bond. The bond's JOB_ESCROW is immutable, so the hostile stack
    /// can exist but cannot reach the real collateral.
    function test_Attack_HostileRegistryCannotReachTheRealBond() public {
        HostileIdentityRegistry hostile = new HostileIdentityRegistry(attacker);

        vm.startPrank(attacker);
        JobEscrow rogue = new JobEscrow(address(hostile), address(validation), attacker);
        vm.stopPrank();

        uint256 stakeBefore = bond.bondBalance(sellerAgentId);

        // The rogue escrow cannot be wired to the real bond: SellerBond.JOB_ESCROW is
        // immutable and names the genuine escrow.
        vm.prank(attacker);
        vm.expectRevert();
        rogue.setSellerBond(address(bond));

        // And the real bond refuses instructions from anything but the genuine escrow.
        vm.prank(address(rogue));
        vm.expectRevert();
        bond.slash(sellerAgentId, stakeBefore, attacker);

        assertEq(bond.bondBalance(sellerAgentId), stakeBefore, "hostile registry reached the real stake");
    }

    /// Attack: open a job against an agent id that was never registered.
    function test_Attack_CannotOpenAJobAgainstAnUnregisteredAgent() public {
        vm.prank(buyer);
        vm.expectRevert();
        escrow.createJob{value: AMOUNT}(999_999, uint64(block.timestamp + 1 days), bytes32(0));
    }

    // ======================================================== solvency backstop

    /// Whatever sequence the attacker runs, the escrow must still hold at least the sum of
    /// every unsettled job, and the bond at least the sum of every agent's balance.
    function test_Attack_StackStaysSolventAcrossAMixedRun() public {
        uint256 jobA = _openJob();
        uint256 jobB = _openJob();
        uint256 jobC = _openJob();

        vm.prank(buyer);
        escrow.release(jobA);
        vm.prank(buyer);
        escrow.dispute(jobB, keccak256("evidence"));
        vm.prank(deployer);
        escrow.resolveDispute(jobB, true);

        (,,, uint256 amountC,,,, JobEscrow.JobStatus statusC,,) = escrow.jobs(jobC);
        assertEq(uint8(statusC), uint8(JobEscrow.JobStatus.Active));
        assertGe(address(escrow).balance, amountC, "escrow cannot cover its remaining live job");

        uint256 accounted = bond.bondBalance(sellerAgentId) + bond.bondBalance(attackerAgentId);
        assertGe(address(bond).balance, accounted, "bond holds less than it has promised");
        assertGe(bond.bondBalance(sellerAgentId), bond.reserved(sellerAgentId), "reserved exceeds the stake");
    }
}
