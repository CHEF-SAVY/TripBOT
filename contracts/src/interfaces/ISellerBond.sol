// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/// @notice Interface to SellerBond, limited to the calls JobEscrow makes. Mirrors the real
/// contract's signatures exactly (contracts/src/SellerBond.sol) — this is our own contract,
/// so unlike IIdentityRegistry there's no external ABI to verify against.
interface ISellerBond {
    /// @notice Lock `amount` of the agent's free bond for a job. Reverts if insufficient.
    function reserve(uint256 agentId, uint256 amount) external;

    /// @notice Unlock a previous reservation (job released / resolved in seller's favor).
    function releaseReservation(uint256 agentId, uint256 amount) external;

    /// @notice Confiscate up to the agent's reserved bond and send it to `recipient`.
    function slash(uint256 agentId, uint256 amount, address recipient) external;

    /// @notice Free bond available to new jobs or withdrawal requests.
    function bondOf(uint256 agentId) external view returns (uint256 free);
}
