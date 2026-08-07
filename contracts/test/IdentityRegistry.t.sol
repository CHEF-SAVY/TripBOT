// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IdentityRegistry} from "../src/registries/IdentityRegistry.sol";

/// @title IdentityRegistryTest — unit tests for the minimal ERC-8004 Identity Registry stand-in
contract IdentityRegistryTest is Test {
    IdentityRegistry internal registry;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal operator = makeAddr("operator");

    function setUp() public {
        registry = new IdentityRegistry();
    }

    function test_RegisterAssignsSequentialIdsOwnedByCaller() public {
        vm.prank(alice);
        uint256 first = registry.register();
        vm.prank(bob);
        uint256 second = registry.register();

        assertEq(first, 0, "first agent should be id 0");
        assertEq(second, 1, "second agent should be id 1");
        assertEq(registry.ownerOf(first), alice, "first agent owned by alice");
        assertEq(registry.ownerOf(second), bob, "second agent owned by bob");
    }

    function test_RevertWhen_OwnerOfNonexistentAgent() public {
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.AgentDoesNotExist.selector, 999));
        registry.ownerOf(999);
    }

    function test_IsAuthorizedOrOwner_TrueForOwner() public {
        vm.prank(alice);
        uint256 agentId = registry.register();
        assertTrue(registry.isAuthorizedOrOwner(alice, agentId));
        assertFalse(registry.isAuthorizedOrOwner(bob, agentId));
    }

    function test_SetOperatorGrantsAuthorization() public {
        vm.prank(alice);
        uint256 agentId = registry.register();

        vm.prank(alice);
        registry.setOperator(agentId, operator, true);
        assertTrue(registry.isAuthorizedOrOwner(operator, agentId), "operator should be authorized");

        vm.prank(alice);
        registry.setOperator(agentId, operator, false);
        assertFalse(registry.isAuthorizedOrOwner(operator, agentId), "revoked operator should lose authorization");
    }

    function test_RevertWhen_SetOperatorByNonOwner() public {
        vm.prank(alice);
        uint256 agentId = registry.register();

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.NotAgentOwner.selector, agentId, bob));
        registry.setOperator(agentId, operator, true);
    }
}
