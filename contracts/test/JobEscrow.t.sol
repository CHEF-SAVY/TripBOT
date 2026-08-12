// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {JobEscrow} from "../src/JobEscrow.sol";
import {SellerBond} from "../src/SellerBond.sol";
import {MockIdentityRegistry} from "./mocks/MockIdentityRegistry.sol";
import {MockValidationRegistry} from "./mocks/MockValidationRegistry.sol";
import {RejectingReceiver} from "./mocks/RejectingReceiver.sol";

/// @title JobEscrowTest — unit tests for JobEscrow against mocked externals + a real SellerBond
/// @notice SellerBond is real (not mocked) here on purpose: createJob's insufficient-bond
/// revert should come from SellerBond.reserve() itself, not a duplicate check in JobEscrow —
/// so the test needs the actual reservation accounting, not a stand-in. Only the Identity
/// Registry and Validation Registry are mocked.
///
/// The escrowed amount is native BOT value (`msg.value` at createJob time), not a pulled
/// ERC-20 — createJob is `payable` and no longer takes an `amount` parameter.
///
/// validationRegistryEnabled defaults true on JobEscrow itself, but every test in this file
/// not specifically about the Validation Registry passes bytes32(0) as validationRequestHash,
/// from back when the flag had no effect on this suite. setUp() disables the flag once so
/// their original behavior is preserved unchanged; the Validation-Registry-specific tests
/// re-enable it deliberately and use _createJobWithValidHash.
contract JobEscrowTest is Test {
    // ------------------------------------------------------------------ fixtures

    MockIdentityRegistry internal registry;
    MockValidationRegistry internal validationRegistry;
    JobEscrow internal jobEscrow;
    SellerBond internal sellerBond;

    address internal buyer = makeAddr("buyer");
    address internal seller = makeAddr("seller");
    address internal arbiter = makeAddr("arbiter");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant SELLER_AGENT_ID = 851_889;

    /// 500 BOT job; at the default 20% minBondRatioBps that's a 100 BOT reservation.
    uint256 internal constant AMOUNT = 500 ether;
    uint256 internal constant REQUIRED_BOND = 100 ether;
    /// Comfortably more than REQUIRED_BOND, so a single job leaves room to spare.
    uint256 internal constant SELLER_STAKE = 200 ether;

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
    event ValidationRegistryEnabledUpdated(bool previous, bool current);

    bytes32 internal constant EVIDENCE_HASH = keccak256("bad-delivery");

    /// Fresh state before every test: the full two-step deploy (JobEscrow first, then
    /// SellerBond with JobEscrow's address baked in, then setSellerBond wires them together),
    /// one registered seller agent with SELLER_STAKE already posted, one buyer funded with
    /// native BOT.
    function setUp() public {
        registry = new MockIdentityRegistry();
        validationRegistry = new MockValidationRegistry();
        jobEscrow = new JobEscrow(address(registry), address(validationRegistry), arbiter);
        sellerBond = new SellerBond(address(registry), address(jobEscrow));
        jobEscrow.setSellerBond(address(sellerBond));
        // Restores pre-Validation-Registry behavior for every existing bytes32(0)-hash test —
        // see the contract-level @notice above.
        jobEscrow.setValidationRegistryEnabled(false);

        registry.setAgentOwner(SELLER_AGENT_ID, seller);
        vm.deal(seller, SELLER_STAKE);
        vm.prank(seller);
        sellerBond.deposit{value: SELLER_STAKE}(SELLER_AGENT_ID);

        vm.deal(buyer, 1000 ether);

        completionDeadline = uint64(block.timestamp) + 1 days;
    }

    // ------------------------------------------------------------------ constructor

    function test_RevertWhen_ConstructorArbiterIsZero() public {
        vm.expectRevert(JobEscrow.InvalidAddress.selector);
        new JobEscrow(address(registry), address(validationRegistry), address(0));
    }

    function test_RevertWhen_ConstructorIdentityRegistryHasNoCode() public {
        vm.expectRevert(abi.encodeWithSelector(JobEscrow.InvalidContract.selector, stranger));
        new JobEscrow(stranger, address(validationRegistry), arbiter);
    }

    function test_RevertWhen_ConstructorValidationRegistryHasNoCode() public {
        vm.expectRevert(abi.encodeWithSelector(JobEscrow.InvalidContract.selector, stranger));
        new JobEscrow(address(registry), stranger, arbiter);
    }

    // ------------------------------------------------------------------ setSellerBond

    function test_SetSellerBondWiresAddressAndEmits() public {
        JobEscrow fresh = new JobEscrow(address(registry), address(validationRegistry), arbiter);
        SellerBond freshBond = new SellerBond(address(registry), address(fresh));

        vm.expectEmit(false, false, false, true);
        emit SellerBondSet(address(freshBond));
        fresh.setSellerBond(address(freshBond));

        assertEq(address(fresh.sellerBond()), address(freshBond), "sellerBond pointer should be wired");
    }

    function test_RevertWhen_SetSellerBondByNonOwner() public {
        JobEscrow fresh = new JobEscrow(address(registry), address(validationRegistry), arbiter);
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

    function test_RevertWhen_SetSellerBondHasDifferentEscrowWiring() public {
        JobEscrow fresh = new JobEscrow(address(registry), address(validationRegistry), arbiter);
        JobEscrow otherEscrow = new JobEscrow(address(registry), address(validationRegistry), arbiter);
        SellerBond wrongBond = new SellerBond(address(registry), address(otherEscrow));

        vm.expectRevert(abi.encodeWithSelector(JobEscrow.SellerBondMisconfigured.selector, address(wrongBond)));
        fresh.setSellerBond(address(wrongBond));
    }

    // ------------------------------------------------------------------ createJob

    /// The core happy path: bond reserved on SellerBond, native BOT escrowed, Job struct
    /// recorded correctly, event emitted with the exact reservedBond that was computed.
    function test_CreateJobReservesBondAndEscrowsValue() public {
        vm.expectEmit(true, true, true, true);
        emit JobCreated(0, buyer, SELLER_AGENT_ID, AMOUNT, REQUIRED_BOND, completionDeadline);

        vm.prank(buyer);
        uint256 jobId = jobEscrow.createJob{value: AMOUNT}(SELLER_AGENT_ID, completionDeadline, bytes32(0));

        assertEq(jobId, 0, "first job should be id 0");
        assertEq(jobEscrow.nextJobId(), 1, "nextJobId should advance");

        (
            address jobBuyer,
            uint256 jobSellerAgentId,
            address sellerPayoutAddress,
            uint256 amount,
            uint256 reservedBond,
            uint64 deadline,
            uint64 responseDeadline,
            JobEscrow.JobStatus status,,
        ) = jobEscrow.jobs(jobId);
        assertEq(jobBuyer, buyer, "buyer should be recorded");
        assertEq(jobSellerAgentId, SELLER_AGENT_ID, "sellerAgentId should be recorded");
        assertEq(sellerPayoutAddress, seller, "sellerPayoutAddress should snapshot the current owner");
        assertEq(amount, AMOUNT, "amount should be recorded");
        assertEq(reservedBond, REQUIRED_BOND, "reservedBond should be 20% of amount");
        assertEq(
            responseDeadline,
            completionDeadline + jobEscrow.responseWindow(),
            "responseDeadline should snapshot at creation"
        );
        assertEq(deadline, completionDeadline, "deadline should be recorded");
        assertEq(uint8(status), uint8(JobEscrow.JobStatus.Active), "job should start Active");

        assertEq(sellerBond.reserved(SELLER_AGENT_ID), REQUIRED_BOND, "SellerBond should show the reservation");
        assertEq(address(jobEscrow).balance, AMOUNT, "escrow should hold the buyer's payment");
    }

    /// A second job gets the next sequential id — jobIds aren't reused or randomized.
    function test_CreateJobIncrementsJobId() public {
        vm.deal(seller, SELLER_STAKE); // top up: two jobs need 2x REQUIRED_BOND reserved
        vm.prank(seller);
        sellerBond.deposit{value: SELLER_STAKE}(SELLER_AGENT_ID);

        vm.prank(buyer);
        jobEscrow.createJob{value: AMOUNT}(SELLER_AGENT_ID, completionDeadline, bytes32(0));

        vm.prank(buyer);
        uint256 secondJobId = jobEscrow.createJob{value: AMOUNT}(SELLER_AGENT_ID, completionDeadline, bytes32(0));
        assertEq(secondJobId, 1, "second job should be id 1");
    }

    function test_RevertWhen_CreateJobZeroAmount() public {
        vm.prank(buyer);
        vm.expectRevert(JobEscrow.ZeroAmount.selector);
        jobEscrow.createJob{value: 0}(SELLER_AGENT_ID, completionDeadline, bytes32(0));
    }

    function test_RevertWhen_CreateJobDeadlineNotInFuture() public {
        uint64 pastDeadline = uint64(block.timestamp);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(JobEscrow.DeadlineNotInFuture.selector, pastDeadline));
        jobEscrow.createJob{value: AMOUNT}(SELLER_AGENT_ID, pastDeadline, bytes32(0));
    }

    /// createJob must fail cleanly, not silently escrow funds with no bond backing them, if
    /// the two-step deploy's wiring call was never made.
    function test_RevertWhen_CreateJobSellerBondNotSet() public {
        JobEscrow unwired = new JobEscrow(address(registry), address(validationRegistry), arbiter);
        vm.prank(buyer);
        vm.expectRevert(JobEscrow.SellerBondNotSet.selector);
        unwired.createJob{value: AMOUNT}(SELLER_AGENT_ID, completionDeadline, bytes32(0));
    }

    /// The property the reservation design exists for: JobEscrow doesn't duplicate a ratio
    /// check, it just lets SellerBond.reserve()'s own revert propagate.
    function test_RevertWhen_CreateJobInsufficientBond() public {
        uint256 tooLarge = SELLER_STAKE * 100; // 20% of this dwarfs what the seller posted
        vm.deal(buyer, tooLarge);
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                SellerBond.InsufficientBond.selector, SELLER_AGENT_ID, (tooLarge * 2000) / 10_000, SELLER_STAKE
            )
        );
        jobEscrow.createJob{value: tooLarge}(SELLER_AGENT_ID, completionDeadline, bytes32(0));
    }

    /// A seller agentId that was never registered must revert — ownerOf's own revert doubles
    /// as JobEscrow's existence check, same pattern as SellerBond.deposit.
    function test_RevertWhen_CreateJobNonexistentSellerAgent() public {
        uint256 ghostAgent = 999_999;
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(MockIdentityRegistry.NonexistentAgent.selector, ghostAgent));
        jobEscrow.createJob{value: AMOUNT}(ghostAgent, completionDeadline, bytes32(0));
    }

    // ---------------------------------------------------- createJob validation registry gate

    /// The hard gate only fires when validationRegistryEnabled — off by default in this
    /// suite's setUp() (see the contract-level doc comment), so every test in this section
    /// turns it back on explicitly.
    function test_CreateJobSucceedsWithValidHashWhenRegistryEnabled() public {
        uint256 jobId = _createJobWithValidHash(keccak256("gate-happy-path"));
        (,,,,,,, JobEscrow.JobStatus status,,) = jobEscrow.jobs(jobId);
        assertEq(uint8(status), uint8(JobEscrow.JobStatus.Active), "job should be created Active");
    }

    function test_RevertWhen_CreateJobRegistryEnabledAndHashUnregistered() public {
        jobEscrow.setValidationRegistryEnabled(true);
        bytes32 requestHash = keccak256("never-registered");

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(JobEscrow.ValidationRequestInvalid.selector, requestHash, SELLER_AGENT_ID)
        );
        jobEscrow.createJob{value: AMOUNT}(SELLER_AGENT_ID, completionDeadline, requestHash);
    }

    /// A requestHash that's registered, but names some other address as validator, must not
    /// satisfy this JobEscrow's gate — a seller registering for a different validator can't
    /// accidentally (or deliberately) pass that registration off as valid here.
    function test_RevertWhen_CreateJobRegistryEnabledAndWrongValidator() public {
        jobEscrow.setValidationRegistryEnabled(true);
        bytes32 requestHash = keccak256("wrong-validator-for-job");
        validationRegistry.validationRequest(makeAddr("notJobEscrow"), SELLER_AGENT_ID, "", requestHash);

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(JobEscrow.ValidationRequestInvalid.selector, requestHash, SELLER_AGENT_ID)
        );
        jobEscrow.createJob{value: AMOUNT}(SELLER_AGENT_ID, completionDeadline, requestHash);
    }

    /// A requestHash already claimed by one job must not back a second one — without this,
    /// two jobs sharing a hash would silently corrupt each other's attestation later (see
    /// ValidationRequestHashAlreadyUsed).
    function test_RevertWhen_CreateJobReusesAlreadyClaimedHash() public {
        bytes32 requestHash = keccak256("reuse-me");
        _createJobWithValidHash(requestHash); // first job legitimately claims the hash

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(JobEscrow.ValidationRequestHashAlreadyUsed.selector, requestHash));
        jobEscrow.createJob{value: AMOUNT}(SELLER_AGENT_ID, completionDeadline, requestHash);
    }

    /// Two distinct, independently-registered hashes for the same seller must both work —
    /// confirms the fix is "no reuse of one hash," not an overbroad "one hash per seller."
    function test_CreateJobSucceedsWithTwoDistinctHashesForSameSeller() public {
        uint256 jobId1 = _createJobWithValidHash(keccak256("distinct-hash-one"));

        // A second job needs its own native value and enough free bond — top up both.
        vm.deal(buyer, AMOUNT);
        vm.deal(seller, REQUIRED_BOND);
        vm.prank(seller);
        sellerBond.deposit{value: REQUIRED_BOND}(SELLER_AGENT_ID);

        uint256 jobId2 = _createJobWithValidHash(keccak256("distinct-hash-two"));
        assertTrue(jobId2 != jobId1, "should be two distinct jobs");
    }

    // ------------------------------------------------------------------ release

    function _createJob() internal returns (uint256 jobId) {
        vm.prank(buyer);
        jobId = jobEscrow.createJob{value: AMOUNT}(SELLER_AGENT_ID, completionDeadline, bytes32(0));
    }

    /// Like _createJob, but with validationRegistryEnabled turned on and a real hash
    /// registered on the mock beforehand — used by the Validation Registry gate/attestation
    /// tests, which need a job that will actually pass the enabled hard gate.
    function _createJobWithValidHash(bytes32 requestHash) internal returns (uint256 jobId) {
        jobEscrow.setValidationRegistryEnabled(true);
        validationRegistry.validationRequest(address(jobEscrow), SELLER_AGENT_ID, "", requestHash);
        vm.prank(buyer);
        jobId = jobEscrow.createJob{value: AMOUNT}(SELLER_AGENT_ID, completionDeadline, requestHash);
    }

    /// The core happy path: seller gets paid in full, the reservation is released back to
    /// SellerBond's free bond, status moves to Released.
    function test_ReleasePaysSellerAndClearsReservation() public {
        uint256 jobId = _createJob();

        vm.expectEmit(true, false, false, true);
        emit JobReleased(jobId);
        vm.prank(buyer);
        jobEscrow.release(jobId);

        assertEq(seller.balance, AMOUNT, "seller should be paid in full");
        assertEq(sellerBond.reserved(SELLER_AGENT_ID), 0, "reservation should be released");
        assertEq(sellerBond.bondOf(SELLER_AGENT_ID), SELLER_STAKE, "seller's full stake should be free again");

        (,,,,,,, JobEscrow.JobStatus status,,) = jobEscrow.jobs(jobId);
        assertEq(uint8(status), uint8(JobEscrow.JobStatus.Released), "status should be Released");
    }

    /// A buyer can release immediately, even before completionDeadline itself — the window is
    /// "any time up to deadline + responseWindow," not gated by the deadline on the front end.
    function test_ReleaseAllowedImmediatelyAfterCreation() public {
        uint256 jobId = _createJob();
        vm.prank(buyer);
        jobEscrow.release(jobId); // no warp — should succeed right away
        assertEq(seller.balance, AMOUNT, "release should succeed before the deadline");
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

        (,,,,,,, JobEscrow.JobStatus status,, bytes32 evidenceHash) = jobEscrow.jobs(jobId);
        assertEq(uint8(status), uint8(JobEscrow.JobStatus.Disputed), "status should be Disputed");
        assertEq(evidenceHash, EVIDENCE_HASH, "evidenceHash should be recorded");
        assertEq(address(jobEscrow).balance, AMOUNT, "escrow should still hold the payment");
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

    function test_RevertWhen_DisputeEvidenceHashIsZero() public {
        uint256 jobId = _createJob();

        vm.prank(buyer);
        vm.expectRevert(JobEscrow.EvidenceHashRequired.selector);
        jobEscrow.dispute(jobId, bytes32(0));
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
        uint256 buyerBalanceBefore = buyer.balance;

        vm.expectEmit(true, false, false, true);
        emit JobResolved(jobId, true);
        vm.prank(arbiter);
        jobEscrow.resolveDispute(jobId, true);

        assertEq(
            buyer.balance,
            buyerBalanceBefore + AMOUNT + REQUIRED_BOND,
            "buyer should get the refund plus the slashed bond"
        );
        assertEq(sellerBond.reserved(SELLER_AGENT_ID), 0, "reservation should be consumed by the slash");
        assertEq(
            sellerBond.bondOf(SELLER_AGENT_ID), SELLER_STAKE - REQUIRED_BOND, "seller's stake should permanently shrink"
        );

        (,,,,,,, JobEscrow.JobStatus status,,) = jobEscrow.jobs(jobId);
        assertEq(uint8(status), uint8(JobEscrow.JobStatus.Resolved), "status should be Resolved");
    }

    /// A dispute that doesn't find the seller at fault pays out exactly like release() would.
    function test_ResolveDisputeSellerNotAtFaultPaysSellerNormally() public {
        uint256 jobId = _createAndDisputeJob();

        vm.prank(arbiter);
        jobEscrow.resolveDispute(jobId, false);

        assertEq(seller.balance, AMOUNT, "seller should be paid in full");
        assertEq(sellerBond.reserved(SELLER_AGENT_ID), 0, "reservation should be released, not slashed");
        assertEq(sellerBond.bondOf(SELLER_AGENT_ID), SELLER_STAKE, "seller's full stake should be free again");
    }

    function test_ResolveDisputeNeutralRefundsBuyerWithoutSlashingSeller() public {
        uint256 jobId = _createAndDisputeJob();
        uint256 buyerBalanceBefore = buyer.balance;
        uint256 grossBondBefore = sellerBond.bondBalance(SELLER_AGENT_ID);

        vm.prank(arbiter);
        jobEscrow.resolveDisputeNeutral(jobId);

        assertEq(buyer.balance, buyerBalanceBefore + AMOUNT, "neutral outcome should refund escrow");
        assertEq(seller.balance, 0, "neutral outcome must not pay for missing work");
        assertEq(sellerBond.reserved(SELLER_AGENT_ID), 0, "neutral outcome should release collateral");
        assertEq(sellerBond.bondBalance(SELLER_AGENT_ID), grossBondBefore, "neutral outcome must not slash");
        (,,,,,,, JobEscrow.JobStatus status,,) = jobEscrow.jobs(jobId);
        assertEq(uint8(status), uint8(JobEscrow.JobStatus.Resolved), "neutral outcome should settle the dispute");
    }

    function test_RevertWhen_ResolveNeutralByNonArbiter() public {
        uint256 jobId = _createAndDisputeJob();
        vm.prank(stranger);
        vm.expectRevert(JobEscrow.NotArbiter.selector);
        jobEscrow.resolveDisputeNeutral(jobId);
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

    // ---------------------------------------------------------- claimDisputeTimeout

    function test_RevertWhen_ClaimDisputeTimeoutBeforeDeadline() public {
        uint256 jobId = _createAndDisputeJob();
        uint64 deadline = jobEscrow.disputeDeadline(jobId);

        vm.expectRevert(abi.encodeWithSelector(JobEscrow.ArbitrationWindowNotElapsed.selector, jobId, deadline));
        jobEscrow.claimDisputeTimeout(jobId);
    }

    function test_ClaimDisputeTimeoutRefundsWithoutUnprovenSlash() public {
        uint256 jobId = _createAndDisputeJob();
        uint256 buyerBalanceBefore = buyer.balance;
        uint256 sellerGrossBondBefore = sellerBond.bondBalance(SELLER_AGENT_ID);

        vm.warp(jobEscrow.disputeDeadline(jobId));
        vm.prank(stranger);
        jobEscrow.claimDisputeTimeout(jobId);

        assertEq(buyer.balance, buyerBalanceBefore + AMOUNT, "buyer should recover escrow");
        assertEq(sellerBond.reserved(SELLER_AGENT_ID), 0, "unadjudicated collateral should be released");
        assertEq(
            sellerBond.bondBalance(SELLER_AGENT_ID), sellerGrossBondBefore, "timeout must not slash without a ruling"
        );
        (,,,,,,, JobEscrow.JobStatus status,,) = jobEscrow.jobs(jobId);
        assertEq(uint8(status), uint8(JobEscrow.JobStatus.Resolved), "timeout should settle the dispute");
    }

    function test_DisputeDeadlineIsUnaffectedByLaterWindowChange() public {
        jobEscrow.setArbitrationWindow(2 days);
        uint256 jobId = _createAndDisputeJob();
        uint64 snapshottedDeadline = jobEscrow.disputeDeadline(jobId);

        jobEscrow.setArbitrationWindow(1 hours);
        vm.warp(snapshottedDeadline - 1);
        vm.expectRevert(
            abi.encodeWithSelector(JobEscrow.ArbitrationWindowNotElapsed.selector, jobId, snapshottedDeadline)
        );
        jobEscrow.claimDisputeTimeout(jobId);

        vm.warp(snapshottedDeadline);
        jobEscrow.claimDisputeTimeout(jobId);
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

        assertEq(seller.balance, AMOUNT, "seller should be paid in full");
        assertEq(sellerBond.reserved(SELLER_AGENT_ID), 0, "reservation should be released");

        (,,,,,,, JobEscrow.JobStatus status,,) = jobEscrow.jobs(jobId);
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

    // ------------------------------------------------------------------ setValidationRegistryEnabled

    /// setUp() already disabled the flag (see the contract-level doc comment above), so this
    /// tests the false -> true transition; the gate/attestation tests below cover re-enabling
    /// for real.
    function test_SetValidationRegistryEnabledEmitsAndApplies() public {
        vm.expectEmit(false, false, false, true);
        emit ValidationRegistryEnabledUpdated(false, true);
        jobEscrow.setValidationRegistryEnabled(true);
        assertTrue(jobEscrow.validationRegistryEnabled(), "flag should update");
    }

    function test_RevertWhen_SetValidationRegistryEnabledNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert(JobEscrow.NotOwner.selector);
        jobEscrow.setValidationRegistryEnabled(true);
    }

    // ------------------------------------------------------------------ isValidationRequestValid

    function test_IsValidationRequestValid_TrueForRegisteredRequest() public {
        bytes32 requestHash = keccak256("valid-request");
        validationRegistry.validationRequest(address(jobEscrow), SELLER_AGENT_ID, "", requestHash);
        assertTrue(jobEscrow.isValidationRequestValid(requestHash, SELLER_AGENT_ID));
    }

    function test_IsValidationRequestValid_FalseForUnregisteredHash() public view {
        assertFalse(jobEscrow.isValidationRequestValid(keccak256("never-requested"), SELLER_AGENT_ID));
    }

    /// A request naming some other validator (not this JobEscrow) must not pass — otherwise
    /// any seller's registration for a different, unrelated validator would incorrectly
    /// satisfy this JobEscrow's gate.
    function test_IsValidationRequestValid_FalseForWrongValidator() public {
        bytes32 requestHash = keccak256("wrong-validator");
        validationRegistry.validationRequest(makeAddr("someOtherValidator"), SELLER_AGENT_ID, "", requestHash);
        assertFalse(jobEscrow.isValidationRequestValid(requestHash, SELLER_AGENT_ID));
    }

    /// A request correctly naming this JobEscrow, but for a different sellerAgentId, must
    /// not validate a job being created for SELLER_AGENT_ID.
    function test_IsValidationRequestValid_FalseForWrongAgent() public {
        bytes32 requestHash = keccak256("wrong-agent");
        validationRegistry.validationRequest(address(jobEscrow), SELLER_AGENT_ID + 1, "", requestHash);
        assertFalse(jobEscrow.isValidationRequestValid(requestHash, SELLER_AGENT_ID));
    }

    // ------------------------------------------------------------------ validation attestation

    /// release() writes response=100, an empty responseHash, and tag "RELEASED" for the
    /// job's requestHash.
    function test_ReleaseWritesReleasedAttestation() public {
        bytes32 requestHash = keccak256("attest-release");
        uint256 jobId = _createJobWithValidHash(requestHash);

        vm.prank(buyer);
        jobEscrow.release(jobId);

        (,, uint8 response, bytes32 responseHash, string memory tag,) =
            validationRegistry.getValidationStatus(requestHash);
        assertEq(response, 100, "response should be 100 for a clean release");
        assertEq(responseHash, bytes32(0), "responseHash should be empty for a clean release");
        assertEq(tag, "RELEASED", "tag should be RELEASED");
    }

    /// Invariant 3: a Validation Registry failure inside release()'s attestation call must
    /// never block the payout itself — the seller still gets paid even though the registry
    /// call reverted.
    function test_ReleaseStillPaysOutWhenAttestationReverts() public {
        bytes32 requestHash = keccak256("attest-release-fails");
        uint256 jobId = _createJobWithValidHash(requestHash);
        validationRegistry.setAlwaysRevertOnResponse(requestHash);

        vm.prank(buyer);
        jobEscrow.release(jobId);

        assertEq(seller.balance, AMOUNT, "seller should still be paid despite the reverting attestation");
    }

    /// resolveDispute(sellerAtFault=true) writes response=0, the buyer's real evidenceHash
    /// (not an empty one), and tag "SELLER_AT_FAULT" — the evidenceHash is what makes this
    /// attestation genuinely content-addressed and checkable, not just a bare score.
    function test_ResolveDisputeSellerAtFaultWritesAttestationWithEvidenceHash() public {
        bytes32 requestHash = keccak256("attest-at-fault");
        uint256 jobId = _createJobWithValidHash(requestHash);
        vm.prank(buyer);
        jobEscrow.dispute(jobId, EVIDENCE_HASH);

        vm.prank(arbiter);
        jobEscrow.resolveDispute(jobId, true);

        (,, uint8 response, bytes32 responseHash, string memory tag,) =
            validationRegistry.getValidationStatus(requestHash);
        assertEq(response, 0, "response should be 0 for seller at fault");
        assertEq(responseHash, EVIDENCE_HASH, "responseHash should carry the buyer's dispute evidence hash");
        assertEq(tag, "SELLER_AT_FAULT", "tag should be SELLER_AT_FAULT");
    }

    /// Invariant 3, at-fault path: the slash + refund must still complete even when the
    /// attestation call reverts.
    function test_ResolveDisputeSellerAtFaultStillPaysOutWhenAttestationReverts() public {
        bytes32 requestHash = keccak256("attest-at-fault-fails");
        uint256 jobId = _createJobWithValidHash(requestHash);
        vm.prank(buyer);
        jobEscrow.dispute(jobId, EVIDENCE_HASH);
        validationRegistry.setAlwaysRevertOnResponse(requestHash);
        uint256 buyerBalanceBefore = buyer.balance;

        vm.prank(arbiter);
        jobEscrow.resolveDispute(jobId, true);

        assertEq(
            buyer.balance,
            buyerBalanceBefore + AMOUNT + REQUIRED_BOND,
            "buyer should still get the refund plus the slashed bond despite the reverting attestation"
        );
    }

    /// resolveDispute(sellerAtFault=false) writes response=100 and tag
    /// "DISPUTE_RESOLVED_SELLER" — a distinct tag from a plain release() so an off-chain
    /// observer can tell "went through a dispute and the seller cleared" apart from "buyer
    /// never disputed at all", even though the payout is identical.
    function test_ResolveDisputeSellerNotAtFaultWritesAttestation() public {
        bytes32 requestHash = keccak256("attest-not-at-fault");
        uint256 jobId = _createJobWithValidHash(requestHash);
        vm.prank(buyer);
        jobEscrow.dispute(jobId, EVIDENCE_HASH);

        vm.prank(arbiter);
        jobEscrow.resolveDispute(jobId, false);

        (,, uint8 response, bytes32 responseHash, string memory tag,) =
            validationRegistry.getValidationStatus(requestHash);
        assertEq(response, 100, "response should be 100");
        assertEq(responseHash, bytes32(0), "responseHash should be empty");
        assertEq(tag, "DISPUTE_RESOLVED_SELLER", "tag should be DISPUTE_RESOLVED_SELLER");
    }

    /// claimTimeout() writes response=50 (indeterminate, not 100 — nobody actually confirmed
    /// delivery, the buyer just never responded) and tag "TIMED_OUT".
    function test_ClaimTimeoutWritesTimedOutAttestation() public {
        bytes32 requestHash = keccak256("attest-timeout");
        uint256 jobId = _createJobWithValidHash(requestHash);
        vm.warp(completionDeadline + jobEscrow.responseWindow());

        jobEscrow.claimTimeout(jobId);

        (,, uint8 response, bytes32 responseHash, string memory tag,) =
            validationRegistry.getValidationStatus(requestHash);
        assertEq(response, 50, "response should be 50 (indeterminate) for a timeout");
        assertEq(responseHash, bytes32(0), "responseHash should be empty");
        assertEq(tag, "TIMED_OUT", "tag should be TIMED_OUT");
    }

    /// Invariant 3, timeout path: the auto-release to the seller must still complete even
    /// when the attestation call reverts.
    function test_ClaimTimeoutStillPaysOutWhenAttestationReverts() public {
        bytes32 requestHash = keccak256("attest-timeout-fails");
        uint256 jobId = _createJobWithValidHash(requestHash);
        validationRegistry.setAlwaysRevertOnResponse(requestHash);
        vm.warp(completionDeadline + jobEscrow.responseWindow());

        jobEscrow.claimTimeout(jobId);

        assertEq(seller.balance, AMOUNT, "seller should still be paid despite the reverting attestation");
    }

    /// The kill switch also gates the attestation calls, not just createJob's gate — with
    /// validationRegistryEnabled off, release() must not even attempt validationResponse, so
    /// the registry's stored status for this (validly registered) requestHash stays at its
    /// pre-response default: request recorded, but never actually responded to.
    function test_ReleaseSkipsAttestationWhenRegistryDisabled() public {
        bytes32 requestHash = keccak256("attest-disabled");
        uint256 jobId = _createJobWithValidHash(requestHash);
        jobEscrow.setValidationRegistryEnabled(false);

        vm.prank(buyer);
        jobEscrow.release(jobId);

        (,, uint8 response,, string memory tag,) = validationRegistry.getValidationStatus(requestHash);
        assertEq(response, 0, "response should still be the pre-response default");
        assertEq(tag, "", "tag should still be empty, validationResponse should never have been called");
    }

    // ------------------------------------------------------------------ responseDeadline snapshot

    /// The property invariant 4 depends on: a job's response window is fixed at creation
    /// (mirrors SellerBond's withdrawalTimelock snapshot pattern), so a later owner change
    /// to the global responseWindow can never retroactively strip a buyer's remaining time.
    /// Without the snapshot, shortening responseWindow after creation would make release()
    /// revert here even though the job's original 48h window hasn't elapsed.
    function test_ReleaseStillSucceedsAfterResponseWindowIsShortened() public {
        uint256 jobId = _createJob(); // snapshots responseDeadline = completionDeadline + 48h

        jobEscrow.setResponseWindow(1 hours); // shortened well after creation
        // Past where the NEW (shortened) window would have elapsed, but nowhere near the
        // job's actual snapshotted responseDeadline.
        vm.warp(completionDeadline + 2 hours);

        vm.prank(buyer);
        jobEscrow.release(jobId);
        assertEq(seller.balance, AMOUNT, "release should still succeed under the job's original window");
    }

    /// The mirror image: claimTimeout must NOT be claimable yet at that same point in time,
    /// for a job created before the window was shortened — proving claimTimeout also reads
    /// the snapshot, not the live responseWindow.
    function test_RevertWhen_ClaimTimeoutBeforeOriginalWindowDespiteShortening() public {
        uint256 jobId = _createJob();
        uint64 originalResponseDeadline = completionDeadline + 48 hours;

        jobEscrow.setResponseWindow(1 hours);
        vm.warp(completionDeadline + 2 hours); // past the new window, before the original one

        vm.expectRevert(
            abi.encodeWithSelector(JobEscrow.ResponseWindowNotElapsed.selector, jobId, originalResponseDeadline)
        );
        jobEscrow.claimTimeout(jobId);
    }

    // ------------------------------------------------------------------ createJob deadline bound

    function test_RevertWhen_CreateJobDeadlineTooFar() public {
        uint64 maxDeadline = uint64(block.timestamp) + jobEscrow.MAX_JOB_DURATION();
        uint64 tooFar = maxDeadline + 1;
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(JobEscrow.DeadlineTooFar.selector, tooFar, maxDeadline));
        jobEscrow.createJob{value: AMOUNT}(SELLER_AGENT_ID, tooFar, bytes32(0));
    }

    /// A deadline exactly at the boundary must still succeed — the cap shouldn't be off-by-one.
    function test_CreateJobAllowsDeadlineAtMax() public {
        uint64 maxDeadline = uint64(block.timestamp) + jobEscrow.MAX_JOB_DURATION();
        vm.prank(buyer);
        uint256 jobId = jobEscrow.createJob{value: AMOUNT}(SELLER_AGENT_ID, maxDeadline, bytes32(0));
        assertEq(jobId, 0, "boundary deadline should be accepted");
    }

    /// The specific overflow this bound exists to prevent: without it, a "no real deadline"
    /// sentinel like type(uint64).max would make completionDeadline + responseWindow
    /// overflow uint64 and permanently lock the job's escrow and reserved bond, since every
    /// exit path computes that same sum.
    function test_RevertWhen_CreateJobDeadlineIsMaxUint64Sentinel() public {
        uint64 maxDeadline = uint64(block.timestamp) + jobEscrow.MAX_JOB_DURATION();
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(JobEscrow.DeadlineTooFar.selector, type(uint64).max, maxDeadline));
        jobEscrow.createJob{value: AMOUNT}(SELLER_AGENT_ID, type(uint64).max, bytes32(0));
    }

    // ------------------------------------------------------------------ zero-bond-ratio configuration

    /// The documented "0% is a legitimate demo/testing configuration" claim, verified end to
    /// end: a job created while minBondRatioBps is 0 never touches SellerBond's
    /// reserve/releaseReservation, since there's nothing to reserve.
    function test_CreateJobAndReleaseWorkWithZeroBondRatio() public {
        jobEscrow.setMinBondRatioBps(0);

        vm.prank(buyer);
        uint256 jobId = jobEscrow.createJob{value: AMOUNT}(SELLER_AGENT_ID, completionDeadline, bytes32(0));

        (,,,, uint256 reservedBond,,,,,) = jobEscrow.jobs(jobId);
        assertEq(reservedBond, 0, "reservedBond should be zero at 0% ratio");
        assertEq(sellerBond.reserved(SELLER_AGENT_ID), 0, "SellerBond should never have been touched");

        vm.prank(buyer);
        jobEscrow.release(jobId);
        assertEq(seller.balance, AMOUNT, "seller should still be paid in full");
    }

    function test_TinyNonzeroJobRoundsRequiredBondUp() public {
        vm.prank(buyer);
        uint256 jobId = jobEscrow.createJob{value: 1}(SELLER_AGENT_ID, completionDeadline, bytes32(0));

        (,,,, uint256 reservedBond,,,,,) = jobEscrow.jobs(jobId);
        assertEq(reservedBond, 1, "a nonzero collateral ratio must not round down to zero");
        assertEq(sellerBond.reserved(SELLER_AGENT_ID), 1, "the rounded collateral must actually be reserved");
    }

    function test_RejectedSellerPayoutDoesNotBlockRelease() public {
        RejectingReceiver rejecting = new RejectingReceiver();
        registry.setAgentOwner(SELLER_AGENT_ID, address(rejecting));

        uint256 jobId = _createJob();
        vm.prank(buyer);
        jobEscrow.release(jobId);

        assertEq(jobEscrow.pendingPayouts(address(rejecting)), AMOUNT, "failed push should become a pull credit");
        assertEq(sellerBond.reserved(SELLER_AGENT_ID), 0, "bond must be released despite payout incompatibility");
        (,,,,,,, JobEscrow.JobStatus status,,) = jobEscrow.jobs(jobId);
        assertEq(uint8(status), uint8(JobEscrow.JobStatus.Released), "release should settle atomically");
    }

    function test_PauseBlocksOnlyNewJobs() public {
        uint256 existingJobId = _createJob();
        jobEscrow.setJobCreationPaused(true);

        vm.prank(buyer);
        vm.expectRevert(JobEscrow.JobCreationIsPaused.selector);
        jobEscrow.createJob{value: AMOUNT}(SELLER_AGENT_ID, completionDeadline, bytes32(0));

        vm.prank(buyer);
        jobEscrow.release(existingJobId);
        assertEq(seller.balance, AMOUNT, "the emergency brake must leave existing exits live");
    }

    function test_DisabledValidationRejectsAmbiguousNonzeroHash() public {
        bytes32 requestHash = keccak256("must-not-be-recorded");
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(JobEscrow.ValidationHashMustBeZeroWhenDisabled.selector, requestHash));
        jobEscrow.createJob{value: AMOUNT}(SELLER_AGENT_ID, completionDeadline, requestHash);
    }

    function test_ArbiterRotationRequiresAcceptance() public {
        address newArbiter = makeAddr("newArbiter");
        jobEscrow.transferArbiter(newArbiter);

        assertEq(jobEscrow.ARBITER(), arbiter, "proposal alone must not rotate authority");
        vm.prank(stranger);
        vm.expectRevert(JobEscrow.NotPendingArbiter.selector);
        jobEscrow.acceptArbiter();

        vm.prank(newArbiter);
        jobEscrow.acceptArbiter();
        assertEq(jobEscrow.ARBITER(), newArbiter, "pending arbiter should take authority on acceptance");
    }

    function test_OwnershipRotationRequiresAcceptance() public {
        address newOwner = makeAddr("newOwner");
        jobEscrow.transferOwnership(newOwner);
        assertEq(jobEscrow.owner(), address(this), "proposal alone must not rotate authority");

        vm.prank(stranger);
        vm.expectRevert(JobEscrow.NotPendingOwner.selector);
        jobEscrow.acceptOwnership();

        vm.prank(newOwner);
        jobEscrow.acceptOwnership();
        assertEq(jobEscrow.owner(), newOwner, "pending owner should take authority on acceptance");
    }

    function test_RevertWhen_ArbitrationWindowExceedsMaximum() public {
        uint64 tooLong = jobEscrow.MAX_ARBITRATION_WINDOW() + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                JobEscrow.ArbitrationWindowTooLong.selector, tooLong, jobEscrow.MAX_ARBITRATION_WINDOW()
            )
        );
        jobEscrow.setArbitrationWindow(tooLong);
    }

    function test_RevertWhen_AdministrativeAddressesAreZero() public {
        vm.expectRevert(JobEscrow.InvalidAddress.selector);
        jobEscrow.transferOwnership(address(0));
        vm.expectRevert(JobEscrow.InvalidAddress.selector);
        jobEscrow.transferArbiter(address(0));
    }

    function test_DeferredPayoutCanBePulledAfterReceiverBecomesCompatible() public {
        RejectingReceiver rejecting = new RejectingReceiver();
        registry.setAgentOwner(SELLER_AGENT_ID, address(rejecting));
        uint256 jobId = _createJob();
        vm.prank(buyer);
        jobEscrow.release(jobId);

        vm.prank(address(rejecting));
        vm.expectRevert(abi.encodeWithSelector(JobEscrow.NativeTransferFailed.selector, address(rejecting), AMOUNT));
        jobEscrow.withdrawPayout();
        assertEq(jobEscrow.pendingPayouts(address(rejecting)), AMOUNT, "failed pull must retain the credit");

        vm.etch(address(rejecting), hex"");
        vm.prank(address(rejecting));
        jobEscrow.withdrawPayout();
        assertEq(jobEscrow.pendingPayouts(address(rejecting)), 0, "successful pull should consume the credit");
        assertEq(address(rejecting).balance, AMOUNT, "recipient should receive the full deferred payout");
    }

    function test_RevertWhen_NoEscrowPayoutIsPending() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(JobEscrow.NoPayoutPending.selector, stranger));
        jobEscrow.withdrawPayout();
    }

    /// The seller-at-fault dispute path also has nothing to slash at 0% ratio — the buyer
    /// still gets their escrowed refund, just no bond compensation on top (there's no bond).
    function test_ResolveDisputeSellerAtFaultWorksWithZeroBondRatio() public {
        jobEscrow.setMinBondRatioBps(0);

        vm.prank(buyer);
        uint256 jobId = jobEscrow.createJob{value: AMOUNT}(SELLER_AGENT_ID, completionDeadline, bytes32(0));
        vm.prank(buyer);
        jobEscrow.dispute(jobId, EVIDENCE_HASH);

        uint256 buyerBalanceBefore = buyer.balance;
        vm.prank(arbiter);
        jobEscrow.resolveDispute(jobId, true);

        assertEq(buyer.balance, buyerBalanceBefore + AMOUNT, "buyer should get the escrow refund with no bond to slash");
    }
}
