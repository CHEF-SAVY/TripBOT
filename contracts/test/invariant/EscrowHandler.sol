// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {JobEscrow} from "../../src/JobEscrow.sol";
import {SellerBond} from "../../src/SellerBond.sol";
import {IdentityRegistry} from "../../src/registries/IdentityRegistry.sol";

/// @title EscrowHandler — drives randomised, *valid-shaped* call sequences at the stack
/// @notice The fuzzer picks which action runs and with what arguments; this contract's job is
/// only to keep the calls well-formed enough to reach real code, and to record what happened
/// so the invariants can be checked against reality rather than against assumptions.
///
/// Every action is wrapped in try/catch on purpose. A revert is a legitimate outcome — the
/// contracts are supposed to reject most random input — and treating it as a test failure
/// would stop the sequence at the first guard instead of exploring past it. What must never
/// happen is a revert-free path that leaves the books wrong, and that is what the invariants
/// look for.
contract EscrowHandler is CommonBase, StdCheats, StdUtils {
    JobEscrow public immutable ESCROW;
    SellerBond public immutable BOND;
    IdentityRegistry public immutable IDENTITY;
    address public immutable ARBITER;

    address[] public actors;
    uint256[] public agentIds;
    uint256[] public jobIds;

    /// Ghost: every wei this handler has ever sent into createJob.
    uint256 public ghostEscrowFunded;
    /// Ghost: every wei this handler has ever deposited as bond.
    uint256 public ghostBondDeposited;
    /// Ghost: how many times each action actually got past its guards, so a run that never
    /// reached the interesting code can be told apart from one that did.
    mapping(bytes32 => uint256) public ghostCalls;

    /// The actor and agent sets are fixed at construction rather than exposed as setters.
    /// As external functions they became fuzz targets, and the fuzzer promptly pushed
    /// duplicate and unregistered ids into the arrays — which made the invariants' own sums
    /// double-count and report a solvency failure that existed only in the harness.
    constructor(
        JobEscrow escrow_,
        SellerBond bond_,
        IdentityRegistry identity_,
        address arbiter_,
        address[] memory actors_,
        uint256[] memory agentIds_
    ) {
        ESCROW = escrow_;
        BOND = bond_;
        IDENTITY = identity_;
        ARBITER = arbiter_;
        for (uint256 i = 0; i < actors_.length; i++) {
            actors.push(actors_[i]);
        }
        for (uint256 i = 0; i < agentIds_.length; i++) {
            agentIds.push(agentIds_[i]);
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function agentCount() external view returns (uint256) {
        return agentIds.length;
    }

    function jobCount() external view returns (uint256) {
        return jobIds.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _agent(uint256 seed) internal view returns (uint256) {
        return agentIds[seed % agentIds.length];
    }

    function _hit(bytes32 name) internal {
        ghostCalls[name]++;
    }

    // --------------------------------------------------------------------- bond

    function depositBond(uint256 agentSeed, uint256 amount) external {
        uint256 agentId = _agent(agentSeed);
        amount = bound(amount, 1, 50 ether);
        address owner = IDENTITY.ownerOf(agentId);
        vm.deal(owner, owner.balance + amount);
        vm.prank(owner);
        try BOND.deposit{value: amount}(agentId) {
            ghostBondDeposited += amount;
            _hit("depositBond");
        } catch {}
    }

    function requestWithdrawal(uint256 agentSeed, uint256 amount) external {
        uint256 agentId = _agent(agentSeed);
        amount = bound(amount, 1, 60 ether);
        vm.prank(IDENTITY.ownerOf(agentId));
        try BOND.requestWithdrawal(agentId, amount) {
            _hit("requestWithdrawal");
        } catch {}
    }

    function completeWithdrawal(uint256 agentSeed) external {
        uint256 agentId = _agent(agentSeed);
        vm.prank(IDENTITY.ownerOf(agentId));
        try BOND.completeWithdrawal(agentId) {
            _hit("completeWithdrawal");
        } catch {}
    }

    function withdrawBondPayout(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        vm.prank(actor);
        try BOND.withdrawPayout() {
            _hit("withdrawBondPayout");
        } catch {}
    }

    // ------------------------------------------------------------------- escrow

    function createJob(uint256 buyerSeed, uint256 agentSeed, uint256 amount, uint256 duration) external {
        address buyer = _actor(buyerSeed);
        uint256 agentId = _agent(agentSeed);
        amount = bound(amount, 1, 30 ether);
        duration = bound(duration, 1, 300 days);

        // Top the agent's collateral up to whatever this job needs before opening it. Without
        // this, a random job almost never finds enough free bond, every createJob reverts, and
        // the sequence never reaches settlement, slashing, or withdrawal at all — the run
        // stays in the shallow part of the state space and the invariants hold vacuously.
        uint256 required = (amount * ESCROW.minBondRatioBps() + 9_999) / 10_000;
        if (required > BOND.bondOf(agentId)) {
            uint256 shortfall = required - BOND.bondOf(agentId);
            address owner = IDENTITY.ownerOf(agentId);
            vm.deal(owner, owner.balance + shortfall);
            vm.prank(owner);
            try BOND.deposit{value: shortfall}(agentId) {
                ghostBondDeposited += shortfall;
                _hit("depositBond");
            } catch {}
        }

        vm.deal(buyer, buyer.balance + amount);
        vm.prank(buyer);
        try ESCROW.createJob{value: amount}(agentId, uint64(block.timestamp + duration), bytes32(0)) returns (
            uint256 jobId
        ) {
            jobIds.push(jobId);
            ghostEscrowFunded += amount;
            _hit("createJob");
        } catch {}
    }

    function release(uint256 jobSeed) external {
        if (jobIds.length == 0) return;
        uint256 jobId = jobIds[jobSeed % jobIds.length];
        (address buyer,,,,,,,,,) = ESCROW.jobs(jobId);
        vm.prank(buyer);
        try ESCROW.release(jobId) {
            _hit("release");
        } catch {}
    }

    function dispute(uint256 jobSeed, uint256 evidenceSeed) external {
        if (jobIds.length == 0) return;
        uint256 jobId = jobIds[jobSeed % jobIds.length];
        (address buyer,,,,,,,,,) = ESCROW.jobs(jobId);
        bytes32 evidence = keccak256(abi.encode(evidenceSeed, jobId));
        vm.prank(buyer);
        try ESCROW.dispute(jobId, evidence) {
            _hit("dispute");
        } catch {}
    }

    function resolveDispute(uint256 jobSeed, bool sellerAtFault) external {
        if (jobIds.length == 0) return;
        uint256 jobId = jobIds[jobSeed % jobIds.length];
        vm.prank(ARBITER);
        try ESCROW.resolveDispute(jobId, sellerAtFault) {
            _hit("resolveDispute");
        } catch {}
    }

    function resolveDisputeNeutral(uint256 jobSeed) external {
        if (jobIds.length == 0) return;
        uint256 jobId = jobIds[jobSeed % jobIds.length];
        vm.prank(ARBITER);
        try ESCROW.resolveDisputeNeutral(jobId) {
            _hit("resolveDisputeNeutral");
        } catch {}
    }

    function claimTimeout(uint256 jobSeed, uint256 actorSeed) external {
        if (jobIds.length == 0) return;
        uint256 jobId = jobIds[jobSeed % jobIds.length];
        vm.prank(_actor(actorSeed));
        try ESCROW.claimTimeout(jobId) {
            _hit("claimTimeout");
        } catch {}
    }

    function claimDisputeTimeout(uint256 jobSeed, uint256 actorSeed) external {
        if (jobIds.length == 0) return;
        uint256 jobId = jobIds[jobSeed % jobIds.length];
        vm.prank(_actor(actorSeed));
        try ESCROW.claimDisputeTimeout(jobId) {
            _hit("claimDisputeTimeout");
        } catch {}
    }

    function withdrawEscrowPayout(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        vm.prank(actor);
        try ESCROW.withdrawPayout() {
            _hit("withdrawEscrowPayout");
        } catch {}
    }

    // --------------------------------------------------------------- environment

    /// Time is an input to this system — both settlement windows and the withdrawal timelock
    /// are deadline-driven, so a sequence that never advances the clock can only ever explore
    /// the pre-deadline half of the state machine.
    function warp(uint256 secondsForward) external {
        vm.warp(block.timestamp + bound(secondsForward, 1 hours, 20 days));
    }

    /// Risk parameters are owner-settable in production, so the invariants must survive them
    /// changing mid-flight rather than only holding at their defaults.
    function setBondRatio(uint256 bps) external {
        vm.prank(ESCROW.owner());
        try ESCROW.setMinBondRatioBps(bound(bps, 0, 10_000)) {
            _hit("setBondRatio");
        } catch {}
    }

    function setResponseWindow(uint256 window) external {
        vm.prank(ESCROW.owner());
        try ESCROW.setResponseWindow(uint64(bound(window, 0, 30 days))) {
            _hit("setResponseWindow");
        } catch {}
    }
}
