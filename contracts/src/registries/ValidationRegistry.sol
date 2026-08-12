// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IValidationRegistry} from "../interfaces/IValidationRegistry.sol";
import {IIdentityRegistry} from "../interfaces/IIdentityRegistry.sol";

/// @title ValidationRegistry — minimal ERC-8004 Validation Registry stand-in for BOT Chain
/// @notice No ERC-8004 registry is deployed on BOT Chain testnet. This backs JobEscrow's
/// toggleable attestation path (validationRegistryEnabled) — never the core escrow money
/// flow, which JobEscrow already treats as independent of this registry's health. Scoped
/// only to what Tripwire's flow needs: a seller names a validator for a job, and that
/// validator alone may respond.
contract ValidationRegistry is IValidationRegistry {
    IIdentityRegistry public immutable IDENTITY_REGISTRY;

    struct Request {
        bool exists;
        address validatorAddress;
        uint256 agentId;
        uint8 response;
        bytes32 responseHash;
        string tag;
        uint256 lastUpdate;
    }

    event ValidationRequested(bytes32 indexed requestHash, address indexed validatorAddress, uint256 indexed agentId);
    event ValidationResponded(bytes32 indexed requestHash, uint8 response, string tag);

    error RequestAlreadyExists(bytes32 requestHash);
    error UnknownRequest(bytes32 requestHash);
    error NotValidator(bytes32 requestHash, address caller);
    error NotAgentOwnerOrOperator(uint256 agentId, address caller);
    error InvalidAddress();
    error ResponseOutOfRange(uint8 response);

    mapping(bytes32 => Request) private _requests;
    uint256 private _nonce;

    constructor(address identityRegistry_) {
        if (identityRegistry_ == address(0) || identityRegistry_.code.length == 0) revert InvalidAddress();
        IDENTITY_REGISTRY = IIdentityRegistry(identityRegistry_);
    }

    /// @notice Seller-initiated: names `validatorAddress` (JobEscrow) as the sole party
    /// allowed to respond for `agentId`. Returns a fresh requestHash — never reused, since
    /// it's derived from an incrementing nonce.
    function validationRequest(address validatorAddress, uint256 agentId, string calldata requestURI)
        external
        returns (bytes32 requestHash)
    {
        if (validatorAddress == address(0)) revert InvalidAddress();
        if (!IDENTITY_REGISTRY.isAuthorizedOrOwner(msg.sender, agentId)) {
            revert NotAgentOwnerOrOperator(agentId, msg.sender);
        }
        requestHash = keccak256(abi.encode(msg.sender, validatorAddress, agentId, requestURI, _nonce++));
        _requests[requestHash] = Request({
            exists: true,
            validatorAddress: validatorAddress,
            agentId: agentId,
            response: 0,
            responseHash: bytes32(0),
            tag: "",
            lastUpdate: block.timestamp
        });
        emit ValidationRequested(requestHash, validatorAddress, agentId);
    }

    /// @inheritdoc IValidationRegistry
    function validationResponse(
        bytes32 requestHash,
        uint8 response,
        string calldata, /* responseURI */
        bytes32 responseHash,
        string calldata tag
    ) external override {
        if (response > 100) revert ResponseOutOfRange(response);
        Request storage r = _requests[requestHash];
        if (!r.exists) revert UnknownRequest(requestHash);
        if (msg.sender != r.validatorAddress) revert NotValidator(requestHash, msg.sender);

        r.response = response;
        r.responseHash = responseHash;
        r.tag = tag;
        r.lastUpdate = block.timestamp;
        emit ValidationResponded(requestHash, response, tag);
    }

    /// @inheritdoc IValidationRegistry
    function getValidationStatus(bytes32 requestHash)
        external
        view
        override
        returns (
            address validatorAddress,
            uint256 agentId,
            uint8 response,
            bytes32 responseHash,
            string memory tag,
            uint256 lastUpdate
        )
    {
        Request storage r = _requests[requestHash];
        if (!r.exists) revert UnknownRequest(requestHash);
        return (r.validatorAddress, r.agentId, r.response, r.responseHash, r.tag, r.lastUpdate);
    }
}
