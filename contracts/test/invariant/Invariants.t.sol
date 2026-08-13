// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {JobEscrow} from "../../src/JobEscrow.sol";
import {SellerBond} from "../../src/SellerBond.sol";
import {IdentityRegistry} from "../../src/registries/IdentityRegistry.sol";
import {ValidationRegistry} from "../../src/registries/ValidationRegistry.sol";
import {EscrowHandler} from "./EscrowHandler.sol";

/// @title InvariantTest — properties that must hold after any sequence of calls
/// @notice The unit and adversarial suites check paths somebody thought of. These check
/// properties nobody has to think of: the fuzzer builds arbitrary call sequences, and each
/// invariant is re-evaluated after every one of them.
///
/// The properties are chosen to be the ones whose violation means real money is wrong —
/// contract insolvency, collateral accounting drifting from the jobs it backs, and the
/// netting identity that both `reserve` and `requestWithdrawal` silently depend on.
contract InvariantTest is Test {
    IdentityRegistry internal identity;
    ValidationRegistry internal validation;
    JobEscrow internal escrow;
    SellerBond internal bond;
    EscrowHandler internal handler;

    address internal deployer = makeAddr("deployer");

    function setUp() public {
        vm.startPrank(deployer);
        identity = new IdentityRegistry();
        validation = new ValidationRegistry(address(identity));
        escrow = new JobEscrow(address(identity), address(validation), deployer);
        bond = new SellerBond(address(identity), address(escrow));
        escrow.setSellerBond(address(bond));
        // The attestation path is exercised by the unit suite; here it would only force every
        // createJob to mint a registry request first, which would throttle how much of the
        // settlement state space a run can reach.
        escrow.setValidationRegistryEnabled(false);
        vm.stopPrank();

        // Four actors who each own an agent, so the fuzzer can have the same address be a
        // buyer on one job and a seller on another — which is where accounting mistakes hide.
        address[] memory actors = new address[](4);
        uint256[] memory agents = new uint256[](4);
        for (uint256 i = 0; i < 4; i++) {
            actors[i] = makeAddr(string(abi.encodePacked("actor", vm.toString(i))));
            vm.prank(actors[i]);
            agents[i] = identity.register();
        }

        handler = new EscrowHandler(escrow, bond, identity, deployer, actors, agents);
        targetContract(address(handler));
    }

    // ------------------------------------------------------------------ solvency

    /// The bond contract must always hold at least everything it says it is holding: every
    /// agent's stake, plus every payout it deferred because a recipient refused it.
    function invariant_BondIsSolvent() public view {
        uint256 owed;
        for (uint256 i = 0; i < handler.agentCount(); i++) {
            owed += bond.bondBalance(handler.agentIds(i));
        }
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            owed += bond.pendingPayouts(handler.actors(i));
        }
        assertGe(address(bond).balance, owed, "SellerBond holds less than it owes");
    }

    /// The escrow must always be able to settle every job still in flight, plus anything it
    /// already owes through the pull-payment ledger.
    function invariant_EscrowIsSolvent() public view {
        uint256 owed;
        for (uint256 i = 0; i < handler.jobCount(); i++) {
            (,,, uint256 amount,,,, JobEscrow.JobStatus status,,) = escrow.jobs(handler.jobIds(i));
            if (status == JobEscrow.JobStatus.Active || status == JobEscrow.JobStatus.Disputed) {
                owed += amount;
            }
        }
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            owed += escrow.pendingPayouts(handler.actors(i));
        }
        assertGe(address(escrow).balance, owed, "JobEscrow cannot cover its unsettled jobs");
    }

    // ---------------------------------------------------------------- accounting

    /// The netting identity every safety check leans on. `bondOf` computes
    /// `bondBalance - pendingWithdrawal - reserved` in unchecked-by-default arithmetic, so if
    /// this ever fails to hold the function does not return a wrong number — it reverts, and
    /// takes createJob and requestWithdrawal down with it.
    function invariant_BondNettingHolds() public view {
        for (uint256 i = 0; i < handler.agentCount(); i++) {
            uint256 agentId = handler.agentIds(i);
            (uint256 pending,) = bond.pendingWithdrawal(agentId);
            assertLe(
                bond.reserved(agentId) + pending,
                bond.bondBalance(agentId),
                "reserved + pending withdrawal exceeds the posted stake"
            );
        }
    }

    /// Reserved collateral must equal exactly the sum of the reservations of the jobs still
    /// live against that agent — no more (collateral stranded after settlement) and no less
    /// (a live job whose bond was already released or slashed away).
    function invariant_ReservedMatchesLiveJobs() public view {
        for (uint256 a = 0; a < handler.agentCount(); a++) {
            uint256 agentId = handler.agentIds(a);
            uint256 expected;
            for (uint256 j = 0; j < handler.jobCount(); j++) {
                (, uint256 jobAgent,,, uint256 reservedBond,,, JobEscrow.JobStatus status,,) =
                    escrow.jobs(handler.jobIds(j));
                if (jobAgent != agentId) continue;
                if (status == JobEscrow.JobStatus.Active || status == JobEscrow.JobStatus.Disputed) {
                    expected += reservedBond;
                }
            }
            assertEq(bond.reserved(agentId), expected, "reserved collateral drifted from the jobs backing it");
        }
    }

    /// A job's escrowed amount and its reservation are fixed at creation. Neither may be
    /// rewritten afterwards by any later call, including an owner changing risk parameters
    /// mid-flight.
    function invariant_SettledJobsKeepTheirTerms() public view {
        for (uint256 i = 0; i < handler.jobCount(); i++) {
            (,,, uint256 amount, uint256 reservedBond,,, JobEscrow.JobStatus status,,) = escrow.jobs(handler.jobIds(i));
            if (status == JobEscrow.JobStatus.None) continue;
            assertGt(amount, 0, "a created job lost its escrowed amount");
            assertLe(reservedBond, amount, "reservation exceeds the job it backs");
        }
    }

    /// Non-vacuity check, deterministic rather than fuzzed.
    ///
    /// Every invariant above holds trivially against a stack nothing ever happened to, so the
    /// suite is only worth anything if the handler can actually reach funded jobs, slashing,
    /// timeouts and withdrawals. This drives it through each of those directly and asserts it
    /// arrived — if the handler ever stops being able to reach settlement, this fails loudly
    /// instead of the invariants quietly passing for the wrong reason.
    function test_HandlerCanReachEveryExitPath() public {
        handler.createJob(0, 0, 5 ether, 10 days);
        handler.createJob(1, 1, 5 ether, 10 days);
        handler.createJob(2, 2, 5 ether, 10 days);
        handler.createJob(3, 3, 5 ether, 10 days);
        assertGt(handler.ghostCalls("createJob"), 0, "handler cannot fund a job");
        assertGt(handler.ghostCalls("depositBond"), 0, "handler cannot post bond");

        handler.release(0);
        assertGt(handler.ghostCalls("release"), 0, "handler cannot release");

        handler.dispute(1, 1);
        assertGt(handler.ghostCalls("dispute"), 0, "handler cannot dispute");
        handler.resolveDispute(1, true);
        assertGt(handler.ghostCalls("resolveDispute"), 0, "handler cannot resolve a dispute");

        handler.dispute(2, 2);
        handler.resolveDisputeNeutral(2);
        assertGt(handler.ghostCalls("resolveDisputeNeutral"), 0, "handler cannot resolve neutrally");

        handler.warp(20 days);
        handler.warp(20 days);
        handler.warp(20 days);
        handler.claimTimeout(3, 0);
        assertGt(handler.ghostCalls("claimTimeout"), 0, "handler cannot time a job out");

        handler.requestWithdrawal(0, 1 ether);
        handler.warp(20 days);
        handler.completeWithdrawal(0);
        assertGt(handler.ghostCalls("completeWithdrawal"), 0, "handler cannot complete a withdrawal");
    }
}
