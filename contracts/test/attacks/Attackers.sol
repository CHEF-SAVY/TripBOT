// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IIdentityRegistry} from "../../src/interfaces/IIdentityRegistry.sol";
import {JobEscrow} from "../../src/JobEscrow.sol";
import {SellerBond} from "../../src/SellerBond.sol";

/// @title Attacker contracts for the adversarial suite
/// @notice These exist to be hostile. Each one models a counterparty that an agent-facing
/// escrow will eventually meet: a seller whose payout address is a contract, a buyer whose
/// refund address is a contract, or an unrelated caller probing the privileged entry points.
/// The value of a reentrant attacker is that it attacks at the only moment the contract is
/// mid-flight — while a payout call has handed it control and before the caller's frame has
/// finished unwinding.

/// @notice Seller payout address that re-enters JobEscrow the instant it is paid.
contract ReentrantSeller {
    JobEscrow public immutable ESCROW;
    uint256 public targetJobId;
    /// 0 = release, 1 = claimTimeout, 2 = withdrawPayout
    uint8 public mode;
    uint256 public reentryAttempts;
    bool public reentryStatus;
    bool internal armed;

    constructor(JobEscrow escrow_) {
        ESCROW = escrow_;
    }

    function arm(uint256 jobId, uint8 mode_) external {
        targetJobId = jobId;
        mode = mode_;
        armed = true;
        reentryAttempts = 0;
        reentryStatus = false;
    }

    receive() external payable {
        if (!armed) return;
        armed = false;
        reentryAttempts++;
        if (mode == 0) {
            try ESCROW.release(targetJobId) {
                reentryStatus = true;
            } catch {}
        } else if (mode == 1) {
            try ESCROW.claimTimeout(targetJobId) {
                reentryStatus = true;
            } catch {}
        } else {
            try ESCROW.withdrawPayout() {
                reentryStatus = true;
            } catch {}
        }
    }
}

/// @notice Buyer whose refund lands in a contract that immediately re-enters resolution.
contract ReentrantBuyer {
    JobEscrow public immutable ESCROW;
    uint256 public targetJobId;
    uint256 public reentryAttempts;
    bool public reentryStatus;
    bool internal armed;

    constructor(JobEscrow escrow_) {
        ESCROW = escrow_;
    }

    function arm(uint256 jobId) external {
        targetJobId = jobId;
        armed = true;
    }

    function createJob(uint256 agentId, uint64 deadline, bytes32 hash_) external payable returns (uint256) {
        return ESCROW.createJob{value: msg.value}(agentId, deadline, hash_);
    }

    function dispute(uint256 jobId, bytes32 evidence) external {
        ESCROW.dispute(jobId, evidence);
    }

    receive() external payable {
        if (!armed) return;
        armed = false;
        reentryAttempts++;
        try ESCROW.withdrawPayout() {
            reentryStatus = true;
        } catch {}
    }
}

/// @notice Bond withdrawal recipient that re-enters SellerBond while being paid.
contract ReentrantBondHolder {
    SellerBond public immutable BOND;
    uint256 public targetAgentId;
    uint256 public reentryAttempts;
    bool public reentryStatus;
    bool internal armed;

    constructor(SellerBond bond_) {
        BOND = bond_;
    }

    function arm(uint256 agentId) external {
        targetAgentId = agentId;
        armed = true;
    }

    function deposit(uint256 agentId) external payable {
        BOND.deposit{value: msg.value}(agentId);
    }

    function requestWithdrawal(uint256 agentId, uint256 amount) external {
        BOND.requestWithdrawal(agentId, amount);
    }

    function completeWithdrawal(uint256 agentId) external {
        BOND.completeWithdrawal(agentId);
    }

    receive() external payable {
        if (!armed) return;
        armed = false;
        reentryAttempts++;
        try BOND.completeWithdrawal(targetAgentId) {
            reentryStatus = true;
        } catch {}
    }
}

/// @notice The attacker that actually reaches the pull-payment ledger.
///
/// A recipient can only accumulate a `pendingPayouts` credit by refusing the push, and can
/// only re-enter `withdrawPayout` by accepting value. One contract that flips between the two
/// satisfies both: refuse during settlement to bank a credit, then accept and re-enter while
/// the credit is being paid out, trying to be paid twice for it.
contract TogglingSeller {
    JobEscrow public immutable ESCROW;
    bool public refusing = true;
    bool public armed;
    uint256 public reentryAttempts;
    bool public reentryStatus;

    constructor(JobEscrow escrow_) {
        ESCROW = escrow_;
    }

    function stopRefusing() external {
        refusing = false;
    }

    function arm() external {
        armed = true;
    }

    function withdrawPayout() external {
        ESCROW.withdrawPayout();
    }

    receive() external payable {
        if (refusing) revert("payout refused");
        if (!armed) return;
        armed = false;
        reentryAttempts++;
        try ESCROW.withdrawPayout() {
            reentryStatus = true;
        } catch {}
    }
}

/// @notice An IdentityRegistry that lies: it reports the attacker as the owner of every agent
/// and authorizes everyone. Used to prove that the registry pointer cannot be swapped after
/// construction, so a hostile registry is not reachable from a deployed stack.
contract HostileIdentityRegistry is IIdentityRegistry {
    address public immutable ATTACKER;

    constructor(address attacker_) {
        ATTACKER = attacker_;
    }

    function ownerOf(uint256) external view override returns (address) {
        return ATTACKER;
    }

    function isAuthorizedOrOwner(address, uint256) external pure override returns (bool) {
        return true;
    }
}

/// @notice A SellerBond-shaped impostor used to try to hijack JobEscrow.setSellerBond.
contract ImpostorBond {
    address public JOB_ESCROW;
    address public IDENTITY_REGISTRY;

    constructor(address jobEscrow_, address identityRegistry_) {
        JOB_ESCROW = jobEscrow_;
        IDENTITY_REGISTRY = identityRegistry_;
    }

    function reserve(uint256, uint256) external {}
    function releaseReservation(uint256, uint256) external {}
    function slash(uint256, uint256, address) external {}
}
