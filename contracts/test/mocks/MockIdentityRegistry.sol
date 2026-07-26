// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IIdentityRegistry} from "../../src/interfaces/IIdentityRegistry.sol";

/// @title MockIdentityRegistry — controllable stand-in for the ERC-8004 Identity Registry
/// @notice The real registry is an upgradeable ERC-721 deployed on Arc testnet. Unit tests
/// only need the two calls SellerBond makes (`isAuthorizedOrOwner`, `ownerOf`), so this
/// mock implements exactly those, with setters that let each test put the registry into
/// whatever state the scenario needs. Fidelity to the real contract's *observable*
/// behaviour is what matters — including that lookups on a nonexistent agent revert, since
/// SellerBond relies on that revert as its agent-existence check. The fork test
/// (ArcForkIntegration) is what validates our assumptions against the real deployment.
contract MockIdentityRegistry is IIdentityRegistry {
    /// agentId => owner address. address(0) means "agent does not exist" — mirrors how an
    /// ERC-721 treats an unminted token id.
    mapping(uint256 => address) private _owners;

    /// agentId => (operator => approved?). Lets tests model the "operator" half of
    /// isAuthorizedOrOwner (an address the owner delegated control to).
    mapping(uint256 => mapping(address => bool)) private _operators;

    /// Same error shape the real ERC-721 uses for unminted tokens; the exact message
    /// doesn't matter to SellerBond — only that the call reverts.
    error NonexistentAgent(uint256 agentId);

    // ------------------------------------------------------------- test setup helpers

    /// @notice Test-only: "mint" an agent to an owner. The real registry does this via
    /// register(); tests skip straight to the resulting state.
    function setAgentOwner(uint256 agentId, address owner) external {
        _owners[agentId] = owner;
    }

    /// @notice Test-only: grant/revoke operator rights over an agent.
    function setOperator(uint256 agentId, address operator, bool approved) external {
        _operators[agentId][operator] = approved;
    }

    // ------------------------------------------------------- IIdentityRegistry surface

    /// @inheritdoc IIdentityRegistry
    function isAuthorizedOrOwner(address spender, uint256 agentId) external view returns (bool) {
        address owner = _owners[agentId];
        // Reverting (not returning false) for unknown agents matches the real registry —
        // SellerBond depends on this as a free existence check.
        if (owner == address(0)) revert NonexistentAgent(agentId);
        return spender == owner || _operators[agentId][spender];
    }

    /// @inheritdoc IIdentityRegistry
    function ownerOf(uint256 agentId) external view returns (address) {
        address owner = _owners[agentId];
        if (owner == address(0)) revert NonexistentAgent(agentId);
        return owner;
    }
}
