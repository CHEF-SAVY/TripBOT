// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/// @notice Minimal interface to the ERC-8004 Validation Registry, limited to the calls
/// JobEscrow actually makes. Signatures match the deployed ValidationRegistryUpgradeable
/// on Arc testnet (proxy 0x8004Cb1BF31DAf7788923b405b754f57acEB4272, impl
/// 0xDB31f5d9167f8ebc8B30FbBF814c4d297c2D7F99 — ABI verified directly against Arcscan's
/// source on 2026-08-06). `validationRequest` is deliberately excluded: only the seller
/// calls it (off-chain, naming JobEscrow as validator), never JobEscrow itself.
interface IValidationRegistry {
    /// @notice Records the outcome of a previously-requested validation. The real registry
    /// requires `msg.sender == validatorAddress` from the matching prior
    /// `validationRequest()` — only the address named as validator may respond, so
    /// JobEscrow can only attest to requests that named JobEscrow itself.
    function validationResponse(
        bytes32 requestHash,
        uint8 response,
        string calldata responseURI,
        bytes32 responseHash,
        string calldata tag
    ) external;

    /// @notice Reads back a validation request's current status. Reverts for an unknown
    /// `requestHash` — not a safe zero-returning mapping getter, so callers that need to
    /// tolerate an unregistered hash must wrap this in try/catch.
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
        );
}
