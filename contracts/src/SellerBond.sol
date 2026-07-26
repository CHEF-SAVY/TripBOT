// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IIdentityRegistry} from "./interfaces/IIdentityRegistry.sol";

/// @title SellerBond — slashable USDC stake keyed by ERC-8004 agentId
/// @notice Sellers post USDC stake against their agentId before they're eligible to take
/// jobs. Bond is reserved per job by JobEscrow (not just ratio-checked at creation), so
/// every job's eventual slash or release is unconditionally fundable: `slash` can only
/// consume what `reserve` locked, and `bondOf` nets out both reservations and any pending
/// withdrawal.
///
/// SKELETON — state, signatures, events, and errors only. No function bodies yet; each
/// function is implemented one at a time with its tests (see plans/02-seller-bond.md).
contract SellerBond {
    // ----------------------------------------------------------------- types

    struct WithdrawalRequest {
        uint256 amount;
        uint64 unlockTime;
    }

    // ---------------------------------------------------------------- state

    IERC20 public immutable USDC;
    IIdentityRegistry public immutable IDENTITY_REGISTRY;
    /// @notice The only address allowed to reserve, release, or slash bond. Set once at
    /// construction, never mutable — nothing else can ever drain a seller's stake.
    address public immutable JOB_ESCROW;

    address public owner;
    /// @notice Applied to new withdrawal requests only; each request snapshots an absolute
    /// unlockTime, so changing this never retroactively affects an in-flight request.
    uint64 public withdrawalTimelock = 3 days;

    /// agentId => gross USDC posted
    mapping(uint256 => uint256) public bondBalance;
    /// agentId => sum locked by active/disputed jobs (moved only by JOB_ESCROW)
    mapping(uint256 => uint256) public reserved;
    /// agentId => at most one in-flight timelocked withdrawal
    mapping(uint256 => WithdrawalRequest) public pendingWithdrawal;

    // ---------------------------------------------------------------- events

    event Deposited(uint256 indexed agentId, address indexed from, uint256 amount);
    event WithdrawalRequested(uint256 indexed agentId, uint256 amount, uint64 unlockTime);
    event WithdrawalCompleted(uint256 indexed agentId, address indexed to, uint256 amount);
    event Reserved(uint256 indexed agentId, uint256 amount);
    event ReservationReleased(uint256 indexed agentId, uint256 amount);
    event Slashed(uint256 indexed agentId, address indexed recipient, uint256 amount);
    event WithdrawalTimelockUpdated(uint64 previous, uint64 current);

    // ---------------------------------------------------------------- errors

    error NotJobEscrow();
    error NotOwner();
    error NotAgentOwnerOrOperator(uint256 agentId, address caller);
    error ZeroAmount();
    error InsufficientBond(uint256 agentId, uint256 requested, uint256 free);
    error InsufficientReserved(uint256 agentId, uint256 requested, uint256 reserved_);
    error WithdrawalAlreadyPending(uint256 agentId);
    error NoWithdrawalPending(uint256 agentId);
    error TimelockNotExpired(uint256 agentId, uint64 unlockTime);

    // ------------------------------------------------------------- modifiers

    modifier onlyJobEscrow() {
        // TODO: revert NotJobEscrow unless msg.sender == JOB_ESCROW
        _;
    }

    modifier onlyOwner() {
        // TODO: revert NotOwner unless msg.sender == owner
        _;
    }

    // ----------------------------------------------------------- constructor

    constructor(address usdc_, address identityRegistry_, address jobEscrow_) {
        USDC = IERC20(usdc_);
        IDENTITY_REGISTRY = IIdentityRegistry(identityRegistry_);
        JOB_ESCROW = jobEscrow_;
        owner = msg.sender;
    }

    // ------------------------------------------------------------- functions

    /// @notice Permissionless top-up: pulls `amount` USDC via transferFrom and credits
    /// the agent's bond. Anyone may back any agent.
    function deposit(uint256 agentId, uint256 amount) external {
        // TODO
    }

    /// @notice Start a timelocked withdrawal. Only the agent's owner/operator; capped at
    /// bondOf(agentId) (i.e. cannot dip into reserved or already-pending amounts); reverts
    /// if a request is already in flight for this agent.
    function requestWithdrawal(uint256 agentId, uint256 amount) external {
        // TODO
    }

    /// @notice Pay out a matured withdrawal request and clear it.
    function completeWithdrawal(uint256 agentId) external {
        // TODO
    }

    /// @notice Lock `amount` of the agent's free bond for a job. Only JobEscrow.
    function reserve(uint256 agentId, uint256 amount) external onlyJobEscrow {
        // TODO
    }

    /// @notice Unlock a previous reservation (job released / resolved in seller's favor).
    function releaseReservation(uint256 agentId, uint256 amount) external onlyJobEscrow {
        // TODO
    }

    /// @notice Confiscate up to the agent's *reserved* bond and send it to `recipient`
    /// (the wronged buyer). Requires amount <= reserved[agentId] — a slash can never touch
    /// free bond, only what was locked for the job being resolved.
    function slash(uint256 agentId, uint256 amount, address recipient) external onlyJobEscrow {
        // TODO
    }

    /// @notice Free bond available to new jobs or withdrawal requests:
    /// bondBalance - pendingWithdrawal.amount - reserved.
    function bondOf(uint256 agentId) public view returns (uint256 free) {
        // TODO
    }

    /// @notice Update the timelock applied to future withdrawal requests.
    function setWithdrawalTimelock(uint64 newTimelock) external onlyOwner {
        // TODO
    }
}
