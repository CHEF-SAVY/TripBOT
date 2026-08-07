// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IIdentityRegistry} from "../interfaces/IIdentityRegistry.sol";

/// @title IdentityRegistry — minimal ERC-8004 Identity Registry stand-in for BOT Chain
/// @notice No ERC-8004 registry is deployed on BOT Chain testnet (confirmed against
/// scan.bohr.life's own search API before writing this). This is a deliberately minimal
/// stand-in, scoped only to the calls Tripwire actually makes against IIdentityRegistry —
/// register an agentId, read its owner, and check owner-or-operator authorization. It is
/// not a general-purpose ERC-8004 implementation and does not attempt ERC-721 compliance.
contract IdentityRegistry is IIdentityRegistry {
    event AgentRegistered(uint256 indexed agentId, address indexed owner);
    event OperatorApprovalUpdated(uint256 indexed agentId, address indexed operator, bool approved);

    error AgentDoesNotExist(uint256 agentId);
    error NotAgentOwner(uint256 agentId, address caller);

    uint256 public nextAgentId;
    mapping(uint256 => address) public agentOwner;
    mapping(uint256 => mapping(address => bool)) public isOperator;

    /// @notice Registers a new agentId owned by the caller. No metadata/URI — Tripwire
    /// never reads anything from this registry beyond ownership.
    function register() external returns (uint256 agentId) {
        agentId = nextAgentId++;
        agentOwner[agentId] = msg.sender;
        emit AgentRegistered(agentId, msg.sender);
    }

    /// @notice Approve or revoke an operator for an agentId. Only the current owner.
    function setOperator(uint256 agentId, address operator, bool approved) external {
        if (agentOwner[agentId] == address(0)) revert AgentDoesNotExist(agentId);
        if (msg.sender != agentOwner[agentId]) revert NotAgentOwner(agentId, msg.sender);
        isOperator[agentId][operator] = approved;
        emit OperatorApprovalUpdated(agentId, operator, approved);
    }

    /// @inheritdoc IIdentityRegistry
    function ownerOf(uint256 agentId) public view override returns (address owner) {
        owner = agentOwner[agentId];
        if (owner == address(0)) revert AgentDoesNotExist(agentId);
    }

    /// @inheritdoc IIdentityRegistry
    function isAuthorizedOrOwner(address spender, uint256 agentId) external view override returns (bool) {
        address owner = ownerOf(agentId);
        return spender == owner || isOperator[agentId][spender];
    }
}
