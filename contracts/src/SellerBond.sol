// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IIdentityRegistry} from "./interfaces/IIdentityRegistry.sol";

/// @title SellerBond — slashable USDC stake keyed by ERC-8004 agentId
/// @notice Sellers post USDC stake against their agentId before they're eligible to take
/// jobs. Bond is reserved per job by JobEscrow (not just ratio-checked at creation), so
/// every job's eventual slash or release is unconditionally fundable: `slash` can only
/// consume what `reserve` locked, and `bondOf` nets out both reservations and any pending
/// withdrawal.
///
/// Implemented incrementally, one function (plus its tests) per change — bodies still
/// marked TODO are pending, not forgotten.
contract SellerBond {
    /// SafeERC20 wraps every token call so that tokens which signal failure by returning
    /// `false` (instead of reverting) still abort the transaction. Real USDC reverts on
    /// failure anyway, but this makes the contract safe against *any* ERC-20 quirk —
    /// standard defensive practice, costs almost nothing.
    using SafeERC20 for IERC20;

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

    /// @notice Post stake: pulls `amount` USDC from the caller and credits it to
    /// `agentId`'s bond. Restricted to the agent's owner/operator so the bond is always
    /// the seller's *own* skin in the game — that's the economic promise Tripwire makes
    /// to buyers, so the contract enforces it rather than trusting convention.
    /// @dev The caller must have `approve`d this contract for at least `amount` first —
    /// that's how ERC-20 pull-payments work: owner grants an allowance, contract spends it.
    /// @param agentId The ERC-8004 agent the stake backs (bond is keyed by agent, not by
    /// wallet, so reputation and stake travel together if the agent NFT changes wallets).
    /// @param amount USDC amount in 6-decimal units (1_000_000 = 1 USDC).
    function deposit(uint256 agentId, uint256 amount) external {
        // Reject zero early: a zero deposit would succeed but only emit a misleading
        // event and waste gas — better to fail loudly.
        if (amount == 0) revert ZeroAmount();

        // Ownership gate. Two things happen in this one call:
        //  1. If `agentId` was never registered, the registry itself reverts — so we get
        //     an existence check for free and can never credit bond to a ghost agent.
        //  2. If the caller is neither the agent's owner nor an approved operator, we
        //     revert with a descriptive error.
        if (!IDENTITY_REGISTRY.isAuthorizedOrOwner(msg.sender, agentId)) {
            revert NotAgentOwnerOrOperator(agentId, msg.sender);
        }

        // Effects before interactions (checks-effects-interactions pattern): we update our
        // own bookkeeping *before* the external token call. If the transfer fails, the
        // whole transaction — bookkeeping included — rolls back atomically, so there's no
        // state where the balance is credited but the money never arrived.
        bondBalance[agentId] += amount;
        emit Deposited(agentId, msg.sender, amount);

        // Pull the USDC in. safeTransferFrom reverts on any failure (insufficient
        // allowance, insufficient balance, token returning false).
        USDC.safeTransferFrom(msg.sender, address(this), amount);
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

    /// @notice Free bond available to new jobs or withdrawal requests.
    /// @dev This is THE number every safety check in the system reads: JobEscrow calls it
    /// (via `reserve`) before accepting a job, and `requestWithdrawal` caps against it.
    /// It nets out the two kinds of "spoken for" bond:
    ///   - `reserved`      — locked as collateral for jobs still in flight
    ///   - `pendingWithdrawal.amount` — already promised back to the seller, mid-timelock
    /// The subtraction cannot underflow because both quantities only ever *grow* through
    /// functions that first check against this same net value — the invariant
    /// `reserved + pending <= bondBalance` is maintained at every write site.
    function bondOf(uint256 agentId) public view returns (uint256 free) {
        return bondBalance[agentId] - pendingWithdrawal[agentId].amount - reserved[agentId];
    }

    /// @notice Update the timelock applied to future withdrawal requests.
    function setWithdrawalTimelock(uint64 newTimelock) external onlyOwner {
        // TODO
    }
}
