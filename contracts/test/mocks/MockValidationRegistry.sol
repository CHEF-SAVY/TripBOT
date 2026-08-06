// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IValidationRegistry} from "../../src/interfaces/IValidationRegistry.sol";

/// @title MockValidationRegistry — controllable stand-in for the ERC-8004 Validation Registry
/// @notice Implements all three real functions, including validationRequest — even though
/// JobEscrow itself never calls that one — so a test can set up state exactly the way a
/// real seller would (call validationRequest naming JobEscrow as validator), rather than
/// reaching for a special test-only setter. Fidelity to the real contract's *observable*
/// behaviour is what matters: requestHash uniqueness is global (a second validationRequest
/// for an already-used hash reverts), getValidationStatus reverts for an unknown hash
/// rather than returning zeros, and validationResponse reverts unless the caller is the
/// exact address named as validator. ArcForkIntegration.t.sol is what validates these
/// assumptions against the real deployment — this mock only needs to be internally
/// consistent with them for unit tests.
contract MockValidationRegistry is IValidationRegistry {
    struct Status {
        address validatorAddress;
        uint256 agentId;
        uint8 response;
        bytes32 responseHash;
        string tag;
        uint256 lastUpdate;
        bool exists;
    }

    /// requestHash => status. `exists` distinguishes "never requested" from a genuine
    /// all-zero response, since response/responseHash/tag/lastUpdate can legitimately all
    /// be zero-ish before validationResponse is ever called.
    mapping(bytes32 => Status) private _statuses;

    /// Test-only escape hatch: requestHash => force validationResponse to revert for it,
    /// regardless of caller. Lets tests simulate "the registry is up but this specific call
    /// fails" on an otherwise-validly-registered job, without a second mock contract and a
    /// second JobEscrow/SellerBond deployment just for that one scenario. See
    /// setAlwaysRevertOnResponse below.
    mapping(bytes32 => bool) private _forceRevertOnResponse;

    error RequestHashAlreadyExists(bytes32 requestHash);
    error UnknownRequestHash(bytes32 requestHash);
    error NotValidator(bytes32 requestHash, address caller);
    error ForcedRevert(bytes32 requestHash);

    // ------------------------------------------------------- IValidationRegistry surface

    /// @notice Not part of IValidationRegistry (JobEscrow never calls it), but implemented
    /// here so tests can register requests exactly as a real seller would.
    function validationRequest(address validatorAddress, uint256 agentId, string calldata, bytes32 requestHash)
        external
    {
        // Mirrors the real registry's global uniqueness — a seller reusing a hash across
        // two different requests (accidentally or otherwise) must fail the same way here.
        if (_statuses[requestHash].exists) revert RequestHashAlreadyExists(requestHash);
        _statuses[requestHash] = Status({
            validatorAddress: validatorAddress,
            agentId: agentId,
            response: 0,
            responseHash: bytes32(0),
            tag: "",
            lastUpdate: block.timestamp,
            exists: true
        });
    }

    /// @inheritdoc IValidationRegistry
    function validationResponse(
        bytes32 requestHash,
        uint8 response,
        string calldata, /* responseURI */
        bytes32 responseHash,
        string calldata tag
    ) external {
        if (_forceRevertOnResponse[requestHash]) revert ForcedRevert(requestHash);

        Status storage status = _statuses[requestHash];
        if (!status.exists) revert UnknownRequestHash(requestHash);
        // Only the exact address named as validator in the matching validationRequest may
        // respond — this is the access-control fact JobEscrow's design depends on.
        if (msg.sender != status.validatorAddress) revert NotValidator(requestHash, msg.sender);

        status.response = response;
        status.responseHash = responseHash;
        status.tag = tag;
        status.lastUpdate = block.timestamp;
    }

    /// @inheritdoc IValidationRegistry
    function getValidationStatus(bytes32 requestHash)
        external
        view
        returns (
            address validatorAddress,
            uint256 agentId,
            uint8 response,
            bytes32 responseHash,
            string memory tag,
            uint256 lastUpdate
        )
    {
        Status storage status = _statuses[requestHash];
        // Reverting (not returning zeros) for an unknown hash matches the real registry —
        // JobEscrow's isValidationRequestValid depends on this being a revert, not a
        // zero-returning getter, to tell "never requested" apart from a genuine response.
        if (!status.exists) revert UnknownRequestHash(requestHash);
        return
            (
                status.validatorAddress,
                status.agentId,
                status.response,
                status.responseHash,
                status.tag,
                status.lastUpdate
            );
    }

    // ------------------------------------------------------------- test setup helpers

    /// @notice Test-only: force validationResponse to revert unconditionally for
    /// `requestHash`, regardless of who calls it. See _forceRevertOnResponse above.
    function setAlwaysRevertOnResponse(bytes32 requestHash) external {
        _forceRevertOnResponse[requestHash] = true;
    }
}
