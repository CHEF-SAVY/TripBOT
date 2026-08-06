// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {JobEscrow} from "../src/JobEscrow.sol";
import {SellerBond} from "../src/SellerBond.sol";
import {IValidationRegistry} from "../src/interfaces/IValidationRegistry.sol";

/// validationRequest is deliberately absent from IValidationRegistry.sol — JobEscrow itself
/// never calls it, only the seller does. This test needs it anyway, to set up registry state
/// exactly the way a real seller would, so it's declared here rather than widening the
/// production interface for a call site that only exists in a test.
interface IValidationRegistryTestSetup {
    function validationRequest(
        address validatorAddress,
        uint256 agentId,
        string calldata requestURI,
        bytes32 requestHash
    ) external;
}

/// @title ArcForkIntegration — pre-deploy smoke test against the real Arc testnet registries
/// @notice Not a unit-test replacement (see JobEscrow.t.sol for that): this exists purely to
/// catch "the real registry's interface doesn't actually match what we assumed" before
/// spending faucet funds on a real deploy. Forks the live chain via the `arc_testnet` named
/// endpoint in foundry.toml — costs no gas, this is simulation only.
///
/// Addresses re-confirmed live on 2026-08-06 (not copied from the days-old table in
/// plans/01-research-and-decisions.md): USDC and the Gateway Wallet are still listed
/// unchanged on docs.arc.io/arc/references/contract-addresses. The ERC-8004 registries
/// aren't on that page at all (they're a separate reference deployment, not one of Arc's own
/// core contracts) — re-verified instead straight against Arcscan's contract API, confirming
/// both proxies are still verified and pointing at the same implementation addresses recorded
/// in plans/01-research-and-decisions.md.
contract ArcForkIntegrationTest is Test {
    address constant USDC = 0x3600000000000000000000000000000000000000;
    address constant IDENTITY_REGISTRY = 0x8004A818BFB912233c491871b3d84c89A494BD9e;
    address constant VALIDATION_REGISTRY = 0x8004Cb1BF31DAf7788923b405b754f57acEB4272;

    // A real registered agentId on Arc testnet's live Identity Registry, and its real
    // current owner (both from Phase 0 registration — see project_tripwire_status memory /
    // plans/06-build-sequence.md). The owner is needed here because this test just revealed
    // a fact that wasn't previously verified: validationRequest is NOT permissionless — the
    // real registry requires msg.sender to be agentId's owner or an approved operator
    // (confirmed straight from the verified source: `registry.ownerOf` +
    // `isApprovedForAll`/`getApproved` check, reverting "Not authorized" otherwise). Matters
    // for the backend follow-up plan, not for JobEscrow itself, which never calls this.
    uint256 constant SELLER_AGENT_ID = 851_889;
    address constant SELLER_AGENT_OWNER = 0xBf6256299A705A56ecea00047e45976778fe0DD9;

    JobEscrow jobEscrow;
    SellerBond sellerBond;
    address arbiter = makeAddr("arbiter");

    function setUp() public {
        vm.createSelectFork("arc_testnet");
        jobEscrow = new JobEscrow(USDC, IDENTITY_REGISTRY, VALIDATION_REGISTRY, arbiter);
        sellerBond = new SellerBond(USDC, IDENTITY_REGISTRY, address(jobEscrow));
        jobEscrow.setSellerBond(address(sellerBond));
    }

    /// The exact behavioral assumption isValidationRequestValid's try/catch depends on:
    /// getValidationStatus really does revert for an unregistered hash, not return zeros.
    function test_RealRegistry_GetValidationStatusRevertsForUnknownHash() public {
        vm.expectRevert();
        IValidationRegistry(VALIDATION_REGISTRY).getValidationStatus(keccak256("definitely-never-registered"));
    }

    /// isValidationRequestValid must swallow that revert into a plain `false`, not propagate
    /// it — confirms JobEscrow's own view of an unregistered hash matches the raw call above.
    function test_IsValidationRequestValid_FalseForUnknownHashAgainstRealRegistry() public view {
        assertFalse(jobEscrow.isValidationRequestValid(keccak256("definitely-never-registered"), SELLER_AGENT_ID));
    }

    /// End-to-end against the real registry: a fresh requestHash, registered exactly the way
    /// a real seller would (naming this fork-deployed JobEscrow as validator), must make
    /// isValidationRequestValid return true for the matching agent and false for a mismatched
    /// one — confirms the real validationRequest/getValidationStatus round-trip matches the
    /// interface JobEscrow was built against.
    function test_RealValidationRequest_ThenIsValidationRequestValid() public {
        bytes32 requestHash = keccak256(abi.encodePacked("tripwire-fork-test", block.timestamp, block.number));

        // Must be pranked as the agentId's real owner — see the SELLER_AGENT_OWNER comment
        // above for why.
        vm.prank(SELLER_AGENT_OWNER);
        IValidationRegistryTestSetup(VALIDATION_REGISTRY)
            .validationRequest(address(jobEscrow), SELLER_AGENT_ID, "", requestHash);

        assertTrue(jobEscrow.isValidationRequestValid(requestHash, SELLER_AGENT_ID));
        assertFalse(
            jobEscrow.isValidationRequestValid(requestHash, SELLER_AGENT_ID + 1),
            "a mismatched agentId must not validate"
        );
    }

    /// The access-control fact JobEscrow's design depends on: only the exact address named
    /// as validator in the matching validationRequest may call validationResponse. Confirms
    /// against the real deployed registry, not just the mock.
    function test_RealValidationResponse_RevertsForCallerThatIsNotTheNamedValidator() public {
        bytes32 requestHash = keccak256(abi.encodePacked("tripwire-fork-test-access-control", block.timestamp));
        vm.prank(SELLER_AGENT_OWNER);
        IValidationRegistryTestSetup(VALIDATION_REGISTRY)
            .validationRequest(address(jobEscrow), SELLER_AGENT_ID, "", requestHash);

        // This test contract is not JobEscrow, so it's not the named validator.
        vm.expectRevert();
        IValidationRegistry(VALIDATION_REGISTRY).validationResponse(requestHash, 100, "", bytes32(0), "FORK_TEST");

        // Pranking as JobEscrow itself succeeds — confirms the real registry's check really
        // is `msg.sender == validatorAddress`, exactly what _attestValidation relies on.
        vm.prank(address(jobEscrow));
        IValidationRegistry(VALIDATION_REGISTRY).validationResponse(requestHash, 100, "", bytes32(0), "FORK_TEST");
    }
}
