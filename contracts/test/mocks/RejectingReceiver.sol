// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/// @title RejectingReceiver — a contract that always refuses incoming native value
/// @notice Exercises the NativeTransferFailed path introduced by switching SellerBond and
/// JobEscrow from ERC-20 transfers to low-level native `call`s: a recipient with no
/// receive/fallback function (or one that reverts) must cause the whole payout transaction
/// to revert, not silently swallow the failure.
contract RejectingReceiver {
    // Deliberately no receive() or fallback() — any plain value transfer to this contract
    // fails at the EVM level.
}
