// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IIdentityRegistry} from "./interfaces/IIdentityRegistry.sol";

/// @title SellerBond — slashable native-BOT stake keyed by ERC-8004 agentId
/// @notice Sellers post native BOT stake against their agentId before they're eligible to
/// take jobs. Bond is reserved per job by JobEscrow (not just ratio-checked at creation), so
/// every job's eventual slash or release is unconditionally fundable: `slash` can only
/// consume what `reserve` locked, and `bondOf` nets out both reservations and any pending
/// withdrawal.
///
/// BOT Chain uses standard native value (like ETH on any EVM chain) as its gas token —
/// unlike Arc, where USDC is the native gas token with a fixed pseudo-ERC20 interface at
/// 0x3600...0000. There is no token contract here at all: deposits arrive as `msg.value`,
/// payouts go out via a low-level `call` carrying value.
contract SellerBond {
    // ----------------------------------------------------------------- types

    struct WithdrawalRequest {
        uint256 amount;
        uint64 unlockTime;
    }

    // ---------------------------------------------------------------- state

    IIdentityRegistry public immutable IDENTITY_REGISTRY;
    /// @notice The only address allowed to reserve, release, or slash bond. Set once at
    /// construction, never mutable — nothing else can ever drain a seller's stake.
    address public immutable JOB_ESCROW;

    address public owner;
    /// @notice Hard ceiling on `withdrawalTimelock`. Bounds what a compromised owner key
    /// can do: without it, the owner could set a century-long timelock and effectively
    /// freeze every *future* withdrawal request (in-flight ones are safe — they snapshot).
    /// There is deliberately no minimum: we want a near-zero timelock for demo recordings,
    /// and "owner is centralized-for-now" is already a disclosed trust assumption.
    uint64 public constant MAX_WITHDRAWAL_TIMELOCK = 30 days;
    /// @notice Applied to new withdrawal requests only; each request snapshots an absolute
    /// unlockTime, so changing this never retroactively affects an in-flight request.
    uint64 public withdrawalTimelock = 3 days;

    /// agentId => gross native BOT posted
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
    error TimelockTooLong(uint64 requested, uint64 max);
    error NativeTransferFailed(address recipient, uint256 amount);

    // ------------------------------------------------------------- modifiers

    modifier onlyJobEscrow() {
        _checkJobEscrow();
        _;
    }

    modifier onlyOwner() {
        // Modifier bodies are inlined into every function that uses them, so the actual
        // check lives in an internal function (one copy in the bytecode) and the modifier
        // just calls it — forge lint's `unwrapped-modifier-logic` convention.
        _checkOwner();
        _;
    }

    /// @dev See onlyOwner — the check itself, kept out of the modifier so it isn't
    /// duplicated into every use site's bytecode.
    function _checkOwner() internal view {
        if (msg.sender != owner) revert NotOwner();
    }

    /// @dev See onlyJobEscrow. JOB_ESCROW is immutable and set once at construction, so
    /// this is the only gate that ever needs checking — there's no owner-mutable backdoor
    /// that could let anything else reserve, release, or slash a seller's bond.
    function _checkJobEscrow() internal view {
        if (msg.sender != JOB_ESCROW) revert NotJobEscrow();
    }

    // ----------------------------------------------------------- constructor

    constructor(address identityRegistry_, address jobEscrow_) {
        IDENTITY_REGISTRY = IIdentityRegistry(identityRegistry_);
        JOB_ESCROW = jobEscrow_;
        owner = msg.sender;
    }

    // ------------------------------------------------------------- functions

    /// @dev Shared native-value payout path: a low-level `call` (not `.transfer()`,
    /// which hard-caps forwarded gas at 2300 and can break on recipients with any
    /// non-trivial receive/fallback logic) that reverts the whole transaction on failure —
    /// same "money must move or nothing happens" guarantee SafeERC20 gave the USDC version.
    function _payOut(address recipient, uint256 amount) private {
        (bool success,) = payable(recipient).call{value: amount}("");
        if (!success) revert NativeTransferFailed(recipient, amount);
    }

    /// @notice Post stake: credits `msg.value` native BOT to `agentId`'s bond. Restricted
    /// to the agent's owner/operator so the bond is always the seller's *own* skin in the
    /// game — that's the economic promise Tripwire makes to buyers, so the contract
    /// enforces it rather than trusting convention.
    /// @param agentId The ERC-8004 agent the stake backs (bond is keyed by agent, not by
    /// wallet, so reputation and stake travel together if the agent NFT changes wallets).
    function deposit(uint256 agentId) external payable {
        // Reject zero early: a zero deposit would succeed but only emit a misleading
        // event and waste gas — better to fail loudly.
        if (msg.value == 0) revert ZeroAmount();

        // Ownership gate. Two things happen in this one call:
        //  1. If `agentId` was never registered, the registry itself reverts — so we get
        //     an existence check for free and can never credit bond to a ghost agent.
        //  2. If the caller is neither the agent's owner nor an approved operator, we
        //     revert with a descriptive error.
        if (!IDENTITY_REGISTRY.isAuthorizedOrOwner(msg.sender, agentId)) {
            revert NotAgentOwnerOrOperator(agentId, msg.sender);
        }

        // The value already arrived with the call (native value, unlike a pull-based
        // ERC-20 transferFrom) — bookkeeping just has to catch up.
        bondBalance[agentId] += msg.value;
        emit Deposited(agentId, msg.sender, msg.value);
    }

    /// @notice Start a timelocked withdrawal. Only the agent's owner/operator; capped at
    /// bondOf(agentId) (i.e. cannot dip into reserved or already-pending amounts); reverts
    /// if a request is already in flight for this agent.
    /// @dev The timelock is the whole point of this two-step dance: a dispute can land at
    /// any moment, so a seller must never be able to yank their stake instantly. Requesting
    /// immediately removes `amount` from bondOf(), so no *new* job can be created against
    /// funds that are on their way out — but the money itself stays here until the clock
    /// runs, still visible to anyone auditing the seller's exit.
    /// There is deliberately no cancel: a mistaken request simply matures and can be
    /// completed then re-deposited. Cancelability would add a state transition JobEscrow
    /// has to reason about, for no benefit the timelock doesn't already provide.
    function requestWithdrawal(uint256 agentId, uint256 amount) external {
        // Same guard order as deposit: cheap sanity check first, then authorization.
        if (amount == 0) revert ZeroAmount();

        // Same gate as deposit — and as there, the registry reverting for an unknown
        // agentId doubles as the existence check.
        if (!IDENTITY_REGISTRY.isAuthorizedOrOwner(msg.sender, agentId)) {
            revert NotAgentOwnerOrOperator(agentId, msg.sender);
        }

        // One request in flight per agent, ever. amount == 0 is the "no request" sentinel
        // (a real request can't be zero — rejected above), which is why no separate
        // "exists" flag is needed in the struct.
        if (pendingWithdrawal[agentId].amount != 0) revert WithdrawalAlreadyPending(agentId);

        // Cap at *free* bond. bondOf() already nets out reserved collateral, so a seller
        // structurally cannot start withdrawing funds that back a live job.
        uint256 free = bondOf(agentId);
        if (amount > free) revert InsufficientBond(agentId, amount, free);

        // Snapshot an absolute unlock time NOW. If the global withdrawalTimelock changes
        // later, this request is unaffected in either direction — invariant 4 of the plan.
        // (uint64 comfortably holds any realistic timestamp; it overflows in the year
        // 584e9, so the unchecked-by-default cast is fine.)
        uint64 unlockTime = uint64(block.timestamp) + withdrawalTimelock;
        pendingWithdrawal[agentId] = WithdrawalRequest({amount: amount, unlockTime: unlockTime});
        emit WithdrawalRequested(agentId, amount, unlockTime);
    }

    /// @notice Pay out a matured withdrawal request and clear it. Only the agent's
    /// owner/operator may trigger it, but the BOT always goes to the agent NFT's *current
    /// owner* — an operator has authority to manage the bond, not to own the proceeds, so
    /// a compromised operator key can never redirect funds to itself. Paying the current
    /// (not request-time) owner also means a mid-timelock agent transfer sends the stake
    /// to the new owner: stake travels with the agent, same as reputation.
    /// @dev Completion is always fundable: slash() only ever consumes *reserved* bond, and
    /// the pending amount was subtracted from bondOf() the moment it was requested, so
    /// nothing that happens during the timelock can spend it out from under the seller.
    function completeWithdrawal(uint256 agentId) external {
        if (!IDENTITY_REGISTRY.isAuthorizedOrOwner(msg.sender, agentId)) {
            revert NotAgentOwnerOrOperator(agentId, msg.sender);
        }

        // Load once into memory — we read .amount/.unlockTime multiple times and then
        // delete the storage slot, so a memory copy is both cheaper and safer than
        // re-reading storage after mutation.
        WithdrawalRequest memory request = pendingWithdrawal[agentId];
        if (request.amount == 0) revert NoWithdrawalPending(agentId);
        if (block.timestamp < request.unlockTime) {
            revert TimelockNotExpired(agentId, request.unlockTime);
        }

        // Resolve the payout destination before touching state (it's a view call, so CEI
        // isn't at stake — this is just the natural reading order). Note: if the agent NFT
        // could ever be burned, ownerOf would revert and the request would sit here until
        // the agent exists again; acceptable because burning your identity mid-withdrawal
        // is self-inflicted, but worth knowing.
        address recipient = IDENTITY_REGISTRY.ownerOf(agentId);

        // Effects before the value transfer, as everywhere else. Both the gross balance
        // and the pending marker drop by the same amount, so bondOf() — which had already
        // excluded this amount — is unchanged by completion. Free bond moved at *request*
        // time; completion only moves custody.
        delete pendingWithdrawal[agentId];
        bondBalance[agentId] -= request.amount;
        emit WithdrawalCompleted(agentId, recipient, request.amount);

        _payOut(recipient, request.amount);
    }

    /// @notice Lock `amount` of the agent's free bond for a job. Only JobEscrow.
    /// @dev Checked against bondOf(), which already nets out both existing reservations and
    /// any pending withdrawal — so a seller can never have more locked against them (across
    /// any number of concurrent jobs plus an in-flight withdrawal) than they actually posted.
    /// This is finding 5 from the research doc: a ratio check at creation alone can't prevent
    /// two concurrent jobs from both passing individually and then being jointly unfundable
    /// at dispute time. Real reservation closes that gap.
    function reserve(uint256 agentId, uint256 amount) external onlyJobEscrow {
        if (amount == 0) revert ZeroAmount();

        uint256 free = bondOf(agentId);
        if (amount > free) revert InsufficientBond(agentId, amount, free);

        reserved[agentId] += amount;
        emit Reserved(agentId, amount);
    }

    /// @notice Unlock a previous reservation (job released / resolved in seller's favor).
    /// @dev No value movement here — this only frees bookkeeping room. Whichever side the
    /// funds actually end up on was already settled by `release`/`completeWithdrawal`
    /// elsewhere; this call just tells us the job this amount was locked for is done.
    function releaseReservation(uint256 agentId, uint256 amount) external onlyJobEscrow {
        if (amount == 0) revert ZeroAmount();

        uint256 currentlyReserved = reserved[agentId];
        if (amount > currentlyReserved) {
            revert InsufficientReserved(agentId, amount, currentlyReserved);
        }

        reserved[agentId] -= amount;
        emit ReservationReleased(agentId, amount);
    }

    /// @notice Confiscate up to the agent's *reserved* bond and send it to `recipient`
    /// (the wronged buyer). Requires amount <= reserved[agentId] — a slash can never touch
    /// free bond, only what was locked for the job being resolved.
    /// @dev Both bondBalance and reserved drop together: the stake is gone for good, not
    /// just unreserved, so it can never be double-counted toward a later job or withdrawal.
    function slash(uint256 agentId, uint256 amount, address recipient) external onlyJobEscrow {
        if (amount == 0) revert ZeroAmount();

        uint256 currentlyReserved = reserved[agentId];
        if (amount > currentlyReserved) {
            revert InsufficientReserved(agentId, amount, currentlyReserved);
        }

        // Effects before interactions, as everywhere else in this contract.
        bondBalance[agentId] -= amount;
        reserved[agentId] = currentlyReserved - amount;
        emit Slashed(agentId, recipient, amount);

        _payOut(recipient, amount);
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

    /// @notice Update the timelock applied to future withdrawal requests. Capped at
    /// MAX_WITHDRAWAL_TIMELOCK; already-pending requests keep their snapshotted unlockTime
    /// no matter what this is set to (see requestWithdrawal).
    function setWithdrawalTimelock(uint64 newTimelock) external onlyOwner {
        if (newTimelock > MAX_WITHDRAWAL_TIMELOCK) {
            revert TimelockTooLong(newTimelock, MAX_WITHDRAWAL_TIMELOCK);
        }
        emit WithdrawalTimelockUpdated(withdrawalTimelock, newTimelock);
        withdrawalTimelock = newTimelock;
    }
}
