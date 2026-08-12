// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {JobEscrow} from "../src/JobEscrow.sol";
import {SellerBond} from "../src/SellerBond.sol";
import {IdentityRegistry} from "../src/registries/IdentityRegistry.sol";
import {ValidationRegistry} from "../src/registries/ValidationRegistry.sol";

/// @title Deploy — BOT Chain testnet deploy of the full Tripwire stack
/// @notice One script, one broadcast run, five ordered transactions from the same deployer
/// wallet: deploy the two ERC-8004 stand-in registries (no ERC-8004 registry exists on BOT
/// Chain testnet — confirmed against scan.bohr.life before writing these), deploy JobEscrow
/// (needs no prior address besides the registries), deploy SellerBond (needs JobEscrow's
/// address baked in as immutable), then setSellerBond to complete the circular wiring —
/// same sequence documented in JobEscrow.setSellerBond's own doc comment.
contract Deploy is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        IdentityRegistry identityRegistry = new IdentityRegistry();
        ValidationRegistry validationRegistry = new ValidationRegistry(address(identityRegistry));

        // Deployer becomes owner (set automatically to msg.sender in both constructors)
        // and, separately, is passed here as the immutable ARBITER — a deliberate choice
        // of a fresh wallet distinct from the buyer/seller demo wallets, so the arbiter
        // is a genuinely separate party from both sides of any dispute it resolves.
        JobEscrow jobEscrow = new JobEscrow(address(identityRegistry), address(validationRegistry), deployer);
        SellerBond sellerBond = new SellerBond(address(identityRegistry), address(jobEscrow));
        jobEscrow.setSellerBond(address(sellerBond));

        vm.stopBroadcast();

        console.log("IdentityRegistry deployed at:", address(identityRegistry));
        console.log("ValidationRegistry deployed at:", address(validationRegistry));
        console.log("JobEscrow deployed at:", address(jobEscrow));
        console.log("SellerBond deployed at:", address(sellerBond));
        console.log("Arbiter/Owner:", deployer);
    }
}
