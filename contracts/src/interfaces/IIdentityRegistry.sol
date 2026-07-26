// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/// @notice Minimal interface to the ERC-8004 Identity Registry, limited to the calls
/// Tripwire actually makes. Signatures match the deployed IdentityRegistryUpgradeable
/// on Arc testnet (proxy 0x8004A818BFB912233c491871b3d84c89A494BD9e, verified ABI).
interface IIdentityRegistry {
    /// @notice True if `spender` is the owner of the agent NFT or an approved operator.
    /// Reverts for a nonexistent agentId, which doubles as an existence check.
    function isAuthorizedOrOwner(address spender, uint256 agentId) external view returns (bool);

    /// @notice ERC-721 owner of the agent NFT.
    function ownerOf(uint256 agentId) external view returns (address);
}
