// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {JobEscrow} from "../src/JobEscrow.sol";
import {SellerBond} from "../src/SellerBond.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockIdentityRegistry} from "./mocks/MockIdentityRegistry.sol";

/// @title JobEscrowTest — unit tests for JobEscrow against mocked externals + a real SellerBond
/// @notice SellerBond is real (not mocked) here on purpose: plan 05's test list wants
/// createJob's insufficient-bond revert to come from SellerBond.reserve() itself, not a
/// duplicate check in JobEscrow — so the test needs the actual reservation accounting, not a
/// stand-in. Only the Identity Registry and USDC are mocked. The Validation Registry address
/// is a placeholder — no calls are wired into it until Phase 3.
contract JobEscrowTest is Test {
    // ------------------------------------------------------------------ fixtures

    MockUSDC internal usdc;
    MockIdentityRegistry internal registry;
    JobEscrow internal jobEscrow;
    SellerBond internal sellerBond;

    address internal buyer = makeAddr("buyer");
    address internal seller = makeAddr("seller");
    address internal arbiter = makeAddr("arbiter");
    address internal stranger = makeAddr("stranger");
    address internal validationRegistryPlaceholder = makeAddr("validationRegistry");

    uint256 internal constant SELLER_AGENT_ID = 851_889;

    /// 500 USDC job; at the default 20% minBondRatioBps that's a 100 USDC reservation.
    uint256 internal constant AMOUNT = 500e6;
    uint256 internal constant REQUIRED_BOND = 100e6;
    /// Comfortably more than REQUIRED_BOND, so a single job leaves room to spare.
    uint256 internal constant SELLER_STAKE = 200e6;

    uint64 internal completionDeadline;

    /// Mirror of the events under test, re-declared for vm.expectEmit (Solidity events can't
    /// be imported standalone).
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

    bytes32 internal constant EVIDENCE_HASH = keccak256("bad-delivery");

    /// Fresh state before every test: the full two-step deploy (JobEscrow first, then
    /// SellerBond with JobEscrow's address baked in, then setSellerBond wires them together),
    /// one registered seller agent with SELLER_STAKE already posted, one funded buyer who has
    /// already approved JobEscrow to pull USDC.
    function setUp() public {
        usdc = new MockUSDC();
        registry = new MockIdentityRegistry();
        jobEscrow = new JobEscrow(address(usdc), address(registry), validationRegistryPlaceholder, arbiter);
        sellerBond = new SellerBond(address(usdc), address(registry), address(jobEscrow));
        jobEscrow.setSellerBond(address(sellerBond));

        registry.setAgentOwner(SELLER_AGENT_ID, seller);
        usdc.mint(seller, SELLER_STAKE);
        vm.startPrank(seller);
        usdc.approve(address(sellerBond), SELLER_STAKE);
        sellerBond.deposit(SELLER_AGENT_ID, SELLER_STAKE);
        vm.stopPrank();

        usdc.mint(buyer, AMOUNT);
        vm.prank(buyer);
        usdc.approve(address(jobEscrow), AMOUNT);

        completionDeadline = uint64(block.timestamp) + 1 days;
    }

    // ------------------------------------------------------------------ setSellerBond

    function test_SetSellerBondWiresAddressAndEmits() public {
        JobEscrow fresh = new JobEscrow(address(usdc), address(registry), validationRegistryPlaceholder, arbiter);
        SellerBond freshBond = new SellerBond(address(usdc), address(registry), address(fresh));

        vm.expectEmit(false, false, false, true);
        emit SellerBondSet(address(freshBond));
        fresh.setSellerBond(address(freshBond));

        assertEq(address(fresh.sellerBond()), address(freshBond), "sellerBond pointer should be wired");
    }

    function test_RevertWhen_SetSellerBondByNonOwner() public {
        JobEscrow fresh = new JobEscrow(address(usdc), address(registry), validationRegistryPlaceholder, arbiter);
        vm.prank(stranger);
        vm.expectRevert(JobEscrow.NotOwner.selector);
        fresh.setSellerBond(makeAddr("someSellerBond"));
    }

    /// The pointer is meant to be immutable in practice — a second call must never let the
    /// owner redirect an already-wired JobEscrow to a different SellerBond.
    function test_RevertWhen_SetSellerBondCalledTwice() public {
        vm.expectRevert(JobEscrow.SellerBondAlreadySet.selector);
        jobEscrow.setSellerBond(makeAddr("anotherSellerBond"));
    }

    // ------------------------------------------------------------------ createJob

    /// The core happy path: bond reserved on SellerBond, USDC pulled into escrow, Job struct
    /// recorded correctly, event emitted with the exact reservedBond that was computed.
    function test_CreateJobReservesBondAndPullsUSDC() public {
        vm.expectEmit(true, true, true, true);
        emit JobCreated(0, buyer, SELLER_AGENT_ID, AMOUNT, REQUIRED_BOND, completionDeadline);

        vm.prank(buyer);
        uint256 jobId = jobEscrow.createJob(SELLER_AGENT_ID, AMOUNT, completionDeadline, bytes32(0));

        assertEq(jobId, 0, "first job should be id 0");
        assertEq(jobEscrow.nextJobId(), 1, "nextJobId should advance");

        (
            address jobBuyer,
            uint256 jobSellerAgentId,
            address sellerPayoutAddress,
            uint256 amount,
            uint256 reservedBond,
            uint64 deadline,
            JobEscrow.JobStatus status,,
        ) = jobEscrow.jobs(jobId);
        assertEq(jobBuyer, buyer, "buyer should be recorded");
        assertEq(jobSellerAgentId, SELLER_AGENT_ID, "sellerAgentId should be recorded");
        assertEq(sellerPayoutAddress, seller, "sellerPayoutAddress should snapshot the current owner");
        assertEq(amount, AMOUNT, "amount should be recorded");
        assertEq(reservedBond, REQUIRED_BOND, "reservedBond should be 20% of amount");
        assertEq(deadline, completionDeadline, "deadline should be recorded");
        assertEq(uint8(status), uint8(JobEscrow.JobStatus.Active), "job should start Active");

        assertEq(sellerBond.reserved(SELLER_AGENT_ID), REQUIRED_BOND, "SellerBond should show the reservation");
        assertEq(usdc.balanceOf(address(jobEscrow)), AMOUNT, "escrow should hold the buyer's payment");
        assertEq(usdc.balanceOf(buyer), 0, "buyer should have paid the full amount");
    }

    /// A second job gets the next sequential id — jobIds aren't reused or randomized.
    function test_CreateJobIncrementsJobId() public {
        usdc.mint(buyer, 2 * AMOUNT); // setUp only funded/approved enough for one job
        usdc.mint(seller, SELLER_STAKE);
        vm.startPrank(buyer);
        usdc.approve(address(jobEscrow), 2 * AMOUNT); // approve() sets, not adds — cover both jobs up front
        jobEscrow.createJob(SELLER_AGENT_ID, AMOUNT, completionDeadline, bytes32(0));
        vm.stopPrank();
        vm.startPrank(seller);
        usdc.approve(address(sellerBond), SELLER_STAKE);
        sellerBond.deposit(SELLER_AGENT_ID, SELLER_STAKE); // top up: two jobs need 2x REQUIRED_BOND reserved
        vm.stopPrank();

        vm.prank(buyer);
        uint256 secondJobId = jobEscrow.createJob(SELLER_AGENT_ID, AMOUNT, completionDeadline, bytes32(0));
        assertEq(secondJobId, 1, "second job should be id 1");
    }

    function test_RevertWhen_CreateJobZeroAmount() public {
        vm.prank(buyer);
        vm.expectRevert(JobEscrow.ZeroAmount.selector);
        jobEscrow.createJob(SELLER_AGENT_ID, 0, completionDeadline, bytes32(0));
    }

    function test_RevertWhen_CreateJobDeadlineNotInFuture() public {
        uint64 pastDeadline = uint64(block.timestamp);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(JobEscrow.DeadlineNotInFuture.selector, pastDeadline));
        jobEscrow.createJob(SELLER_AGENT_ID, AMOUNT, pastDeadline, bytes32(0));
    }

    /// createJob must fail cleanly, not silently escrow funds with no bond backing them, if
    /// the two-step deploy's wiring call was never made.
    function test_RevertWhen_CreateJobSellerBondNotSet() public {
        JobEscrow unwired = new JobEscrow(address(usdc), address(registry), validationRegistryPlaceholder, arbiter);
        vm.prank(buyer);
        vm.expectRevert(JobEscrow.SellerBondNotSet.selector);
        unwired.createJob(SELLER_AGENT_ID, AMOUNT, completionDeadline, bytes32(0));
    }

    /// The property the reservation design exists for: JobEscrow doesn't duplicate a ratio
    /// check, it just lets SellerBond.reserve()'s own revert propagate.
    function test_RevertWhen_CreateJobInsufficientBond() public {
        uint256 tooLarge = SELLER_STAKE * 100; // 20% of this dwarfs what the seller posted
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                SellerBond.InsufficientBond.selector, SELLER_AGENT_ID, (tooLarge * 2000) / 10_000, SELLER_STAKE
            )
        );
        jobEscrow.createJob(SELLER_AGENT_ID, tooLarge, completionDeadline, bytes32(0));
    }

    /// A seller agentId that was never registered must revert — ownerOf's own revert doubles
    /// as JobEscrow's existence check, same pattern as SellerBond.deposit.
    function test_RevertWhen_CreateJobNonexistentSellerAgent() public {
        uint256 ghostAgent = 999_999;
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(MockIdentityRegistry.NonexistentAgent.selector, ghostAgent));
        jobEscrow.createJob(ghostAgent, AMOUNT, completionDeadline, bytes32(0));
    }

    // ------------------------------------------------------------------ release

    function _createJob() internal returns (uint256 jobId) {
        vm.prank(buyer);
        jobId = jobEscrow.createJob(SELLER_AGENT_ID, AMOUNT, completionDeadline, bytes32(0));
    }

    /// The core happy path: seller gets paid in full, the reservation is released back to
    /// SellerBond's free bond, status moves to Released.
    function test_ReleasePaysSellerAndClearsReservation() public {
        uint256 jobId = _createJob();

        vm.expectEmit(true, false, false, true);
        emit JobReleased(jobId);
        vm.prank(buyer);
        jobEscrow.release(jobId);

        assertEq(usdc.balanceOf(seller), AMOUNT, "seller should be paid in full");
        assertEq(sellerBond.reserved(SELLER_AGENT_ID), 0, "reservation should be released");
        assertEq(sellerBond.bondOf(SELLER_AGENT_ID), SELLER_STAKE, "seller's full stake should be free again");

        (,,,,,, JobEscrow.JobStatus status,,) = jobEscrow.jobs(jobId);
        assertEq(uint8(status), uint8(JobEscrow.JobStatus.Released), "status should be Released");
    }

    /// A buyer can release immediately, even before completionDeadline itself — the window is
    /// "any time up to deadline + responseWindow," not gated by the deadline on the front end.
    function test_ReleaseAllowedImmediatelyAfterCreation() public {
        uint256 jobId = _createJob();
        vm.prank(buyer);
        jobEscrow.release(jobId); // no warp — should succeed right away
        assertEq(usdc.balanceOf(seller), AMOUNT, "release should succeed before the deadline");
    }

    function test_RevertWhen_ReleaseByNonBuyer() public {
        uint256 jobId = _createJob();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(JobEscrow.NotBuyer.selector, jobId, stranger));
        jobEscrow.release(jobId);
    }

    /// Releasing an already-released job must fail — status only ever moves forward once.
    function test_RevertWhen_ReleaseNotActive() public {
        uint256 jobId = _createJob();
        vm.startPrank(buyer);
        jobEscrow.release(jobId);
        vm.expectRevert(abi.encodeWithSelector(JobEscrow.JobNotActive.selector, jobId, JobEscrow.JobStatus.Released));
        jobEscrow.release(jobId);
        vm.stopPrank();
    }

    /// Past completionDeadline + responseWindow, only claimTimeout applies — invariant 4's
    /// mutual exclusivity, enforced on the release side.
    function test_RevertWhen_ReleaseAfterResponseWindowElapsed() public {
        uint256 jobId = _createJob();
        uint64 claimableAfter = completionDeadline + jobEscrow.responseWindow();
        vm.warp(claimableAfter);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(JobEscrow.ResponseWindowElapsed.selector, jobId, claimableAfter));
        jobEscrow.release(jobId);
    }

    // ------------------------------------------------------------------ dispute

    /// The core happy path: evidence hash recorded, status flips, no funds move yet —
    /// resolution (and any payout) only happens at resolveDispute.
    function test_DisputeRecordsEvidenceAndFlipsStatus() public {
        uint256 jobId = _createJob();

        vm.expectEmit(true, false, false, true);
        emit JobDisputed(jobId, EVIDENCE_HASH);
        vm.prank(buyer);
        jobEscrow.dispute(jobId, EVIDENCE_HASH);

        (,,,,,, JobEscrow.JobStatus status,, bytes32 evidenceHash) = jobEscrow.jobs(jobId);
        assertEq(uint8(status), uint8(JobEscrow.JobStatus.Disputed), "status should be Disputed");
        assertEq(evidenceHash, EVIDENCE_HASH, "evidenceHash should be recorded");
        assertEq(usdc.balanceOf(address(jobEscrow)), AMOUNT, "escrow should still hold the payment");
        assertEq(sellerBond.reserved(SELLER_AGENT_ID), REQUIRED_BOND, "reservation should still be locked");
    }

    function test_RevertWhen_DisputeByNonBuyer() public {
        uint256 jobId = _createJob();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(JobEscrow.NotBuyer.selector, jobId, stranger));
        jobEscrow.dispute(jobId, EVIDENCE_HASH);
    }

    /// Disputing an already-resolved (here: released) job must fail — status only moves
    /// forward once, and Disputed is only reachable from Active.
    function test_RevertWhen_DisputeNotActive() public {
        uint256 jobId = _createJob();
        vm.startPrank(buyer);
        jobEscrow.release(jobId);
        vm.expectRevert(abi.encodeWithSelector(JobEscrow.JobNotActive.selector, jobId, JobEscrow.JobStatus.Released));
        jobEscrow.dispute(jobId, EVIDENCE_HASH);
        vm.stopPrank();
    }

    /// Same window as release() — past it, only claimTimeout applies.
    function test_RevertWhen_DisputeAfterResponseWindowElapsed() public {
        uint256 jobId = _createJob();
        uint64 claimableAfter = completionDeadline + jobEscrow.responseWindow();
        vm.warp(claimableAfter);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(JobEscrow.ResponseWindowElapsed.selector, jobId, claimableAfter));
        jobEscrow.dispute(jobId, EVIDENCE_HASH);
    }

    // ------------------------------------------------------------------ resolveDispute

    function _createAndDisputeJob() internal returns (uint256 jobId) {
        jobId = _createJob();
        vm.prank(buyer);
        jobEscrow.dispute(jobId, EVIDENCE_HASH);
    }

    /// The pitch's core mechanic: the buyer gets made whole *and* compensated. Two separate
    /// transfers land in the buyer's wallet — the escrowed refund from JobEscrow, and the
    /// slashed bond straight from SellerBond — and the seller's stake permanently shrinks.
    function test_ResolveDisputeSellerAtFaultSlashesBondAndRefundsBuyer() public {
        uint256 jobId = _createAndDisputeJob();

        vm.expectEmit(true, false, false, true);
        emit JobResolved(jobId, true);
        vm.prank(arbiter);
        jobEscrow.resolveDispute(jobId, true);

        assertEq(usdc.balanceOf(buyer), AMOUNT + REQUIRED_BOND, "buyer should get the refund plus the slashed bond");
        assertEq(sellerBond.reserved(SELLER_AGENT_ID), 0, "reservation should be consumed by the slash");
        assertEq(
            sellerBond.bondOf(SELLER_AGENT_ID), SELLER_STAKE - REQUIRED_BOND, "seller's stake should permanently shrink"
        );

        (,,,,,, JobEscrow.JobStatus status,,) = jobEscrow.jobs(jobId);
        assertEq(uint8(status), uint8(JobEscrow.JobStatus.Resolved), "status should be Resolved");
    }

    /// A dispute that doesn't find the seller at fault pays out exactly like release() would.
    function test_ResolveDisputeSellerNotAtFaultPaysSellerNormally() public {
        uint256 jobId = _createAndDisputeJob();

        vm.prank(arbiter);
        jobEscrow.resolveDispute(jobId, false);

        assertEq(usdc.balanceOf(seller), AMOUNT, "seller should be paid in full");
        assertEq(sellerBond.reserved(SELLER_AGENT_ID), 0, "reservation should be released, not slashed");
        assertEq(sellerBond.bondOf(SELLER_AGENT_ID), SELLER_STAKE, "seller's full stake should be free again");
    }

    function test_RevertWhen_ResolveDisputeByNonArbiter() public {
        uint256 jobId = _createAndDisputeJob();
        vm.prank(stranger);
        vm.expectRevert(JobEscrow.NotArbiter.selector);
        jobEscrow.resolveDispute(jobId, true);
    }

    /// Only a Disputed job can be resolved — an Active job must go through dispute() first.
    function test_RevertWhen_ResolveDisputeNotDisputed() public {
        uint256 jobId = _createJob();
        vm.prank(arbiter);
        vm.expectRevert(abi.encodeWithSelector(JobEscrow.JobNotDisputed.selector, jobId, JobEscrow.JobStatus.Active));
        jobEscrow.resolveDispute(jobId, true);
    }

    // ------------------------------------------------------------------ claimTimeout

    /// Anyone — not just the buyer or seller — may trigger the rescue once the window has
    /// elapsed with the buyer having done nothing.
    function test_ClaimTimeoutPaysSellerAfterWindow() public {
        uint256 jobId = _createJob();
        uint64 claimableAfter = completionDeadline + jobEscrow.responseWindow();
        vm.warp(claimableAfter);

        vm.expectEmit(true, false, false, true);
        emit JobTimedOut(jobId);
        vm.prank(stranger);
        jobEscrow.claimTimeout(jobId);

        assertEq(usdc.balanceOf(seller), AMOUNT, "seller should be paid in full");
        assertEq(sellerBond.reserved(SELLER_AGENT_ID), 0, "reservation should be released");

        (,,,,,, JobEscrow.JobStatus status,,) = jobEscrow.jobs(jobId);
        assertEq(uint8(status), uint8(JobEscrow.JobStatus.TimedOut), "status should be TimedOut");
    }

    function test_RevertWhen_ClaimTimeoutBeforeWindowElapsed() public {
        uint256 jobId = _createJob();
        uint64 claimableAfter = completionDeadline + jobEscrow.responseWindow();

        vm.expectRevert(abi.encodeWithSelector(JobEscrow.ResponseWindowNotElapsed.selector, jobId, claimableAfter));
        jobEscrow.claimTimeout(jobId);
    }

    /// A job the buyer already released can't also be timed out — status only moves forward
    /// once, and TimedOut is only reachable from Active.
    function test_RevertWhen_ClaimTimeoutNotActive() public {
        uint256 jobId = _createJob();
        vm.prank(buyer);
        jobEscrow.release(jobId);

        uint64 claimableAfter = completionDeadline + jobEscrow.responseWindow();
        vm.warp(claimableAfter);
        vm.expectRevert(abi.encodeWithSelector(JobEscrow.JobNotActive.selector, jobId, JobEscrow.JobStatus.Released));
        jobEscrow.claimTimeout(jobId);
    }

    // ------------------------------------------------------------------ setMinBondRatioBps

    function test_SetMinBondRatioBpsEmitsAndApplies() public {
        vm.expectEmit(false, false, false, true);
        emit MinBondRatioBpsUpdated(2000, 1000);
        jobEscrow.setMinBondRatioBps(1000);
        assertEq(jobEscrow.minBondRatioBps(), 1000, "ratio should update");
    }

    function test_RevertWhen_SetMinBondRatioBpsNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert(JobEscrow.NotOwner.selector);
        jobEscrow.setMinBondRatioBps(1000);
    }

    /// The 100% ceiling holds — bounding what a careless or compromised owner key could brick.
    function test_RevertWhen_SetMinBondRatioBpsAboveMax() public {
        uint256 tooHigh = 10_000 + 1;
        vm.expectRevert(abi.encodeWithSelector(JobEscrow.MinBondRatioTooHigh.selector, tooHigh, uint256(10_000)));
        jobEscrow.setMinBondRatioBps(tooHigh);
    }

    // ------------------------------------------------------------------ setResponseWindow

    function test_SetResponseWindowEmitsAndApplies() public {
        vm.expectEmit(false, false, false, true);
        emit ResponseWindowUpdated(48 hours, 1 hours);
        jobEscrow.setResponseWindow(1 hours);
        assertEq(jobEscrow.responseWindow(), 1 hours, "window should update");
    }

    function test_RevertWhen_SetResponseWindowNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert(JobEscrow.NotOwner.selector);
        jobEscrow.setResponseWindow(1 hours);
    }

    /// The 30-day ceiling holds — bounding what a compromised owner key could freeze.
    function test_RevertWhen_SetResponseWindowAboveMax() public {
        uint64 tooLong = 30 days + 1;
        vm.expectRevert(abi.encodeWithSelector(JobEscrow.ResponseWindowTooLong.selector, tooLong, uint64(30 days)));
        jobEscrow.setResponseWindow(tooLong);
    }
}
