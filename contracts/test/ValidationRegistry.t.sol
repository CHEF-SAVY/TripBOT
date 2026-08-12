// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ValidationRegistry} from "../src/registries/ValidationRegistry.sol";
import {MockIdentityRegistry} from "./mocks/MockIdentityRegistry.sol";

/// @title ValidationRegistryTest — unit tests for the minimal ERC-8004 Validation Registry stand-in
contract ValidationRegistryTest is Test {
    ValidationRegistry internal registry;
    MockIdentityRegistry internal identityRegistry;

    address internal seller = makeAddr("seller");
    address internal validator = makeAddr("validator");
    address internal stranger = makeAddr("stranger");
    uint256 internal constant AGENT_ID = 851_889;

    function setUp() public {
        identityRegistry = new MockIdentityRegistry();
        identityRegistry.setAgentOwner(AGENT_ID, seller);
        registry = new ValidationRegistry(address(identityRegistry));
    }

    function test_ValidationRequestThenResponseRoundTrips() public {
        vm.prank(seller);
        bytes32 requestHash = registry.validationRequest(validator, AGENT_ID, "ipfs://job-details");

        vm.prank(validator);
        registry.validationResponse(requestHash, 100, "", bytes32(0), "RELEASED");

        (address validatorAddress, uint256 agentId, uint8 response, bytes32 responseHash, string memory tag,) =
            registry.getValidationStatus(requestHash);
        assertEq(validatorAddress, validator, "validator should be recorded");
        assertEq(agentId, AGENT_ID, "agentId should be recorded");
        assertEq(response, 100, "response should be recorded");
        assertEq(responseHash, bytes32(0), "responseHash should be recorded");
        assertEq(tag, "RELEASED", "tag should be recorded");
    }

    function test_RevertWhen_ResponseFromNonValidator() public {
        vm.prank(seller);
        bytes32 requestHash = registry.validationRequest(validator, AGENT_ID, "");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ValidationRegistry.NotValidator.selector, requestHash, stranger));
        registry.validationResponse(requestHash, 100, "", bytes32(0), "RELEASED");
    }

    function test_RevertWhen_GetStatusForUnknownHash() public {
        bytes32 unknown = keccak256("never-requested");
        vm.expectRevert(abi.encodeWithSelector(ValidationRegistry.UnknownRequest.selector, unknown));
        registry.getValidationStatus(unknown);
    }

    function test_RevertWhen_ResponseForUnknownHash() public {
        bytes32 unknown = keccak256("never-requested");
        vm.prank(validator);
        vm.expectRevert(abi.encodeWithSelector(ValidationRegistry.UnknownRequest.selector, unknown));
        registry.validationResponse(unknown, 100, "", bytes32(0), "RELEASED");
    }

    /// Each call generates a fresh hash, even for identical arguments — collision-free by
    /// construction via the incrementing nonce.
    function test_ValidationRequestNeverCollidesAcrossCalls() public {
        vm.startPrank(seller);
        bytes32 first = registry.validationRequest(validator, AGENT_ID, "same-uri");
        bytes32 second = registry.validationRequest(validator, AGENT_ID, "same-uri");
        vm.stopPrank();

        assertTrue(first != second, "identical requests should still get distinct hashes");
    }

    function test_RevertWhen_ValidationRequestCallerDoesNotControlAgent() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ValidationRegistry.NotAgentOwnerOrOperator.selector, AGENT_ID, stranger));
        registry.validationRequest(validator, AGENT_ID, "ipfs://job-details");
    }

    function test_RevertWhen_ResponseExceedsStandardRange() public {
        vm.prank(seller);
        bytes32 requestHash = registry.validationRequest(validator, AGENT_ID, "");
        vm.prank(validator);
        vm.expectRevert(abi.encodeWithSelector(ValidationRegistry.ResponseOutOfRange.selector, 101));
        registry.validationResponse(requestHash, 101, "", bytes32(0), "INVALID");
    }
}
