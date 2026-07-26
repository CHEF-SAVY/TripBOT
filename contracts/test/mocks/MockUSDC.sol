// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockUSDC — minimal stand-in for Arc's USDC in unit tests
/// @notice Unit tests never touch the real chain, so we need a token that behaves like
/// USDC from the contract's point of view: a plain ERC-20 with 6 decimals. We inherit
/// OpenZeppelin's audited ERC20 rather than writing transfer logic ourselves — the thing
/// under test is SellerBond, not the token.
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}

    /// @notice Real USDC uses 6 decimals (most ERC-20s use 18). Overriding keeps test
    /// amounts realistic — 1_000_000 units == 1 USDC — so decimal bugs can't hide.
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Test-only faucet: lets a test hand any address any balance directly,
    /// instead of simulating the real faucet/transfer chain. Never exists on real USDC.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
