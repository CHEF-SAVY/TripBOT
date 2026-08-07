// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {JobEscrow} from "../src/JobEscrow.sol";
import {SellerBond} from "../src/SellerBond.sol";

/// @title Deploy — Phase 4 production deploy of JobEscrow + SellerBond to Arc testnet
/// @notice One script, one broadcast run, three ordered transactions from the same
/// deployer wallet: deploy JobEscrow (needs no prior address), deploy SellerBond (needs
/// JobEscrow's address baked in as immutable), then setSellerBond to complete the
/// circular wiring — same sequence documented in JobEscrow.setSellerBond's own doc
/// comment and plans/06-build-sequence.md's Phase 4 checklist.
contract Deploy is Script {
    // Re-confirmed live against docs.arc.io/arc/references/contract-addresses and
    // Arcscan's contract API on 2026-08-07 — not reused from the days-old table in
    // plans/01-research-and-decisions.md.
    address constant USDC = 0x3600000000000000000000000000000000000000;
    address constant IDENTITY_REGISTRY = 0x8004A818BFB912233c491871b3d84c89A494BD9e;
    address constant VALIDATION_REGISTRY = 0x8004Cb1BF31DAf7788923b405b754f57acEB4272;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        // Deployer becomes owner (set automatically to msg.sender in both constructors)
        // and, separately, is passed here as the immutable ARBITER — a deliberate choice
        // of a fresh wallet distinct from the buyer/seller demo wallets, so the arbiter
        // is a genuinely separate party from both sides of any dispute it resolves.
        JobEscrow jobEscrow = new JobEscrow(USDC, IDENTITY_REGISTRY, VALIDATION_REGISTRY, deployer);
        SellerBond sellerBond = new SellerBond(USDC, IDENTITY_REGISTRY, address(jobEscrow));
        jobEscrow.setSellerBond(address(sellerBond));

        vm.stopBroadcast();

        console.log("JobEscrow deployed at:", address(jobEscrow));
        console.log("SellerBond deployed at:", address(sellerBond));
        console.log("Arbiter/Owner:", deployer);
    }
}
