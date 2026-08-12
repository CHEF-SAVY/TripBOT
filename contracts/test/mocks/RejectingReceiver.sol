// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/// @title RejectingReceiver — a contract that always refuses incoming native value
/// @notice Exercises the deferred-credit path: a recipient with no receive/fallback
/// function cannot block the surrounding withdrawal or escrow settlement.
contract RejectingReceiver {
    // Deliberately no receive() or fallback() — any plain value transfer to this contract
    // fails at the EVM level.
}
