// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IIdentityRegistry} from "./interfaces/IIdentityRegistry.sol";
import {ISellerBond} from "./interfaces/ISellerBond.sol";

/// @title JobEscrow — one job, one escrowed USDC payment, released only on verified delivery
/// @notice Buyer's USDC sits here until the buyer releases it, an arbiter resolves a dispute
/// in the seller's favor, or a timeout auto-releases it — never before. The seller must have
/// bond reserved on SellerBond before a job can start, and a dispute resolved against the
/// seller slashes that same reservation to the buyer, on top of the escrowed refund.
///
/// Implemented incrementally, one function (plus its tests) per change — bodies still marked
/// TODO are pending, not forgotten. Validation Registry wiring (the requestHash check in
/// createJob, and the validationResponse calls) is deliberately deferred to Phase 3 — this
/// phase gets the core escrow state machine correct against mocks first.
contract JobEscrow {
    using SafeERC20 for IERC20;

    // ----------------------------------------------------------------- types

    enum JobStatus {
        None, // default zero value — also means "job doesn't exist", doubling as an existence check
        Active,
        Released,
        Disputed,
        Resolved,
        TimedOut
    }

    struct Job {
        address buyer;
        uint256 sellerAgentId;
        // Snapshotted via identityRegistry.ownerOf() at createJob() time, not re-read at
        // payout — a buyer commits to a specific counterparty at creation, and letting that
        // silently redirect via a mid-job agent-NFT transfer would let a bad actor launder a
        // payout through an NFT sale after delivery. (Contrast SellerBond.completeWithdrawal,
        // which deliberately pays the *current* owner — a withdrawal is the seller's own money
        // moving on their own initiative, not a buyer's already-committed payment.)
        address sellerPayoutAddress;
        uint256 amount;
        // amount * minBondRatioBps / 10000 at creation time — fixed for this job's lifetime.
        // This exact number is the only amount ever reserved, released, or slashed for this
        // job; no recomputation later, no partial-slash fallback needed.
        uint256 reservedBond;
        uint64 completionDeadline;
        JobStatus status;
        // Hash of the seller's ERC-8004 validationRequest for this job, checked against the
        // Validation Registry in Phase 3. Zero until that wiring lands.
        bytes32 validationRequestHash;
        // Hash of buyer-submitted dispute evidence — the hash lands on-chain, not raw evidence.
        bytes32 evidenceHash;
    }

    // ---------------------------------------------------------------- state

    IERC20 public immutable USDC;
    IIdentityRegistry public immutable IDENTITY_REGISTRY;
    // Raw address, not a typed interface, for now: the real Validation Registry ABI hasn't
    // been pulled from Arcscan yet (open question in 01-research-and-decisions.md). Phase 3
    // introduces IValidationRegistry once that's confirmed — no hand-written interface from
    // memory, same discipline as IIdentityRegistry.
    address public immutable VALIDATION_REGISTRY;
    // MVP dispute resolution: a single arbiter address (the deployer wallet), disclosed in the
    // README as centralized-for-now. Separate from `owner` — same key for the hackathon, but a
    // one-line change to rotate later without touching risk-parameter ownership.
    address public immutable ARBITER;

    address public owner;
    // Settable exactly once post-deploy (see setSellerBond) — resolves the circular
    // constructor dependency: JobEscrow needs SellerBond's address, but SellerBond's
    // JOB_ESCROW is immutable and needs JobEscrow's address. JobEscrow deploys first with
    // this unset; SellerBond deploys second with JobEscrow's address baked in as immutable;
    // then setSellerBond() is called once to complete the wiring.
    ISellerBond public sellerBond;

    // Gates every Validation Registry external call behind an owner-toggleable switch — the
    // registry's own spec is "still under active discussion," so a flaky registry can never
    // brick fund movement. Calls themselves aren't wired until Phase 3.
    bool public validationRegistryEnabled = true;
    // Risk parameter: required bond as a fraction of job amount, in basis points (2000 = 20%,
    // the spec's starting default). Owner-settable, same category as SellerBond's
    // withdrawalTimelock.
    uint256 public minBondRatioBps = 2000;
    // Dispute window and timeout grace period, merged into one owner-settable duration: buyer
    // can release()/dispute() any time up to completionDeadline + responseWindow; after that,
    // anyone can claimTimeout().
    uint64 public responseWindow = 48 hours;

    mapping(uint256 => Job) public jobs;
    uint256 public nextJobId;

    // ---------------------------------------------------------------- events

    event JobCreated(
        uint256 indexed jobId,
        address indexed buyer,
        uint256 indexed sellerAgentId,
        uint256 amount,
        uint256 reservedBond,
        uint64 completionDeadline
    );
    event JobReleased(uint256 indexed jobId);
    event JobDisputed(uint256 indexed jobId, bytes32 evidenceHash);
    event JobResolved(uint256 indexed jobId, bool sellerAtFault);
    event JobTimedOut(uint256 indexed jobId);
    event SellerBondSet(address sellerBond);
    event MinBondRatioBpsUpdated(uint256 previous, uint256 current);
    event ResponseWindowUpdated(uint64 previous, uint64 current);

    // ---------------------------------------------------------------- errors

    error NotOwner();
    error NotArbiter();
    error NotBuyer(uint256 jobId, address caller);
    error SellerBondAlreadySet();
    error SellerBondNotSet();
    error ZeroAmount();
    error DeadlineNotInFuture(uint64 completionDeadline);
    // Doubles as the "job doesn't exist" check: a nonexistent jobId's status is JobStatus.None,
    // which is never JobStatus.Active — same "revert doubles as existence check" pattern used
    // throughout SellerBond.
    error JobNotActive(uint256 jobId, JobStatus status);
    error JobNotDisputed(uint256 jobId, JobStatus status);
    error ResponseWindowElapsed(uint256 jobId, uint64 claimableAfter);
    error ResponseWindowNotElapsed(uint256 jobId, uint64 claimableAfter);

    // ------------------------------------------------------------- modifiers

    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    modifier onlyArbiter() {
        _checkArbiter();
        _;
    }

    modifier onlyBuyer(uint256 jobId) {
        _checkBuyer(jobId);
        _;
    }

    /// @dev See onlyOwner — check kept out of the modifier so it isn't duplicated into every
    /// use site's bytecode (forge lint's unwrapped-modifier-logic rule).
    function _checkOwner() internal view {
        if (msg.sender != owner) revert NotOwner();
    }

    /// @dev See onlyArbiter.
    function _checkArbiter() internal view {
        if (msg.sender != ARBITER) revert NotArbiter();
    }

    /// @dev See onlyBuyer.
    function _checkBuyer(uint256 jobId) internal view {
        if (msg.sender != jobs[jobId].buyer) revert NotBuyer(jobId, msg.sender);
    }

    // ----------------------------------------------------------- constructor

    constructor(address usdc_, address identityRegistry_, address validationRegistry_, address arbiter_) {
        USDC = IERC20(usdc_);
        IDENTITY_REGISTRY = IIdentityRegistry(identityRegistry_);
        VALIDATION_REGISTRY = validationRegistry_;
        ARBITER = arbiter_;
        owner = msg.sender;
    }

    // ------------------------------------------------------------- functions

    /// @notice One-time wiring of the SellerBond address, completing the two-step deploy.
    /// Reverts if already set — this pointer is meant to be immutable in practice, just not
    /// in the Solidity keyword sense (it can't be, since it isn't known at construction).
    function setSellerBond(address sellerBond_) external onlyOwner {
        if (address(sellerBond) != address(0)) revert SellerBondAlreadySet();
        sellerBond = ISellerBond(sellerBond_);
        emit SellerBondSet(sellerBond_);
    }

    /// @notice Buyer opens a job: validates amount/deadline, reserves the seller's bond,
    /// pulls `amount` USDC into escrow. Reverts via SellerBond.reserve() if the seller's free
    /// bond can't cover minBondRatioBps of `amount` — no duplicate ratio check here,
    /// SellerBond is the source of truth for its own balances.
    /// @dev `validationRequestHash` is stored on the job but not yet checked against the
    /// Validation Registry — that verification is Phase 3 (validationRegistryEnabled has no
    /// effect until then). `IDENTITY_REGISTRY.ownerOf` reverting for an unregistered
    /// `sellerAgentId` doubles as the existence check, same pattern as SellerBond.deposit.
    function createJob(uint256 sellerAgentId, uint256 amount, uint64 completionDeadline, bytes32 validationRequestHash)
        external
        returns (uint256 jobId)
    {
        if (amount == 0) revert ZeroAmount();
        if (completionDeadline <= block.timestamp) revert DeadlineNotInFuture(completionDeadline);
        if (address(sellerBond) == address(0)) revert SellerBondNotSet();

        // Snapshotted now, not re-read at payout — see the Job struct's sellerPayoutAddress
        // comment for why a buyer's committed counterparty must survive a mid-job NFT
        // transfer unchanged.
        address sellerPayoutAddress = IDENTITY_REGISTRY.ownerOf(sellerAgentId);

        // Fixed for this job's lifetime (invariant 1) — the only amount ever reserved,
        // released, or slashed for it, regardless of later minBondRatioBps changes.
        uint256 reservedBond = (amount * minBondRatioBps) / 10_000;

        jobId = nextJobId++;
        jobs[jobId] = Job({
            buyer: msg.sender,
            sellerAgentId: sellerAgentId,
            sellerPayoutAddress: sellerPayoutAddress,
            amount: amount,
            reservedBond: reservedBond,
            completionDeadline: completionDeadline,
            status: JobStatus.Active,
            validationRequestHash: validationRequestHash,
            evidenceHash: bytes32(0)
        });

        emit JobCreated(jobId, msg.sender, sellerAgentId, amount, reservedBond, completionDeadline);

        // Interactions last. If the seller's free bond can't cover reservedBond,
        // sellerBond.reserve() reverts and unwinds the job creation atomically — no separate
        // ratio check needed here, SellerBond is the source of truth for its own balances.
        sellerBond.reserve(sellerAgentId, reservedBond);
        USDC.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Buyer accepts delivery: pays the seller in full, releases the bond
    /// reservation. Only callable by the job's buyer, while Active, and only up to
    /// completionDeadline + responseWindow — past that point only claimTimeout applies
    /// (invariant 4: the two windows are mutually exclusive by construction).
    function release(uint256 jobId) external onlyBuyer(jobId) {
        Job storage job = jobs[jobId];
        if (job.status != JobStatus.Active) revert JobNotActive(jobId, job.status);

        uint64 claimableAfter = job.completionDeadline + responseWindow;
        if (block.timestamp >= claimableAfter) revert ResponseWindowElapsed(jobId, claimableAfter);

        job.status = JobStatus.Released;
        emit JobReleased(jobId);

        sellerBond.releaseReservation(job.sellerAgentId, job.reservedBond);
        USDC.safeTransfer(job.sellerPayoutAddress, job.amount);
    }

    /// @notice Buyer disputes instead of releasing: records evidenceHash on-chain (the hash,
    /// not raw evidence) and flips status to Disputed. No fund movement yet — that only
    /// happens at resolveDispute. Only callable by the job's buyer, before
    /// completionDeadline + responseWindow.
    function dispute(uint256 jobId, bytes32 evidenceHash) external onlyBuyer(jobId) {
        // TODO
    }

    /// @notice Arbiter resolves a dispute. sellerAtFault=true slashes the reserved bond to
    /// the buyer and separately refunds the escrowed amount; sellerAtFault=false pays the
    /// seller as if released normally. MVP: single arbiter address, disclosed as
    /// centralized-for-now.
    function resolveDispute(uint256 jobId, bool sellerAtFault) external onlyArbiter {
        // TODO
    }

    /// @notice Anyone may trigger auto-release to the seller once
    /// completionDeadline + responseWindow has passed with the buyer having done nothing —
    /// without this a buyer could grief a seller forever by simply not responding.
    function claimTimeout(uint256 jobId) external {
        // TODO
    }

    /// @notice Update the risk parameter controlling how much bond a job requires, as a
    /// fraction of job amount in basis points. Applies to jobs created after the change —
    /// already-active jobs keep their snapshotted reservedBond (invariant 1).
    function setMinBondRatioBps(uint256 newRatioBps) external onlyOwner {
        // TODO
    }

    /// @notice Update the combined dispute window / timeout grace period. Applies to jobs
    /// created after the change — an already-active job's deadline math was fixed at its own
    /// completionDeadline, set at creation time.
    function setResponseWindow(uint64 newWindow) external onlyOwner {
        // TODO
    }
}
