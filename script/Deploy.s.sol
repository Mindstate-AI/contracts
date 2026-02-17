// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {MindstateToken} from "../src/MindstateToken.sol";
import {MindstateFactory} from "../src/MindstateFactory.sol";
import {MindstateLaunchFactory} from "../src/launchpad/MindstateLaunchFactory.sol";
import {MindstateVault} from "../src/launchpad/MindstateVault.sol";
import {FeeCollector} from "../src/launchpad/FeeCollector.sol";

/**
 * @title Deploy
 * @notice Deploys the complete Mindstate protocol stack to any EVM chain.
 *
 *         Deployment order:
 *           1. MindstateToken (implementation — not used directly, only as clone template)
 *           2. MindstateFactory (lightweight clone factory for direct deployments)
 *           3. FeeCollector (platform fee treasury)
 *           4. MindstateVault (holds V3 LP NFTs, distributes fees)
 *           5. MindstateLaunchFactory (launchpad — deploys token + V3 pool in one tx)
 *           6. Wire contracts together (vault ↔ factory, vault ↔ feeCollector)
 *
 *         Required environment variables:
 *           DEPLOYER_PRIVATE_KEY  — private key of the deployer (becomes owner of admin contracts)
 *           WETH                  — WETH address on the target chain
 *           V3_FACTORY            — Uniswap V3 Factory address
 *           POSITION_MANAGER      — Uniswap V3 NonfungiblePositionManager address
 *
 *         Base Mainnet addresses:
 *           WETH              = 0x4200000000000000000000000000000000000006
 *           V3_FACTORY        = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD
 *           POSITION_MANAGER  = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1
 *
 *         Base Sepolia addresses:
 *           WETH              = 0x4200000000000000000000000000000000000006
 *           V3_FACTORY        = 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24
 *           POSITION_MANAGER  = 0x27F971cb582BF9E50F397e4d29a5C7A34f11faA2
 *
 *         Usage:
 *           forge script script/Deploy.s.sol \
 *             --rpc-url $RPC_URL \
 *             --private-key $DEPLOYER_PRIVATE_KEY \
 *             --broadcast \
 *             --verify
 */
contract Deploy is Script {
    function run() external {
        // ── Read environment variables ───────────────────────────
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address weth = vm.envAddress("WETH");
        address v3Factory = vm.envAddress("V3_FACTORY");
        address positionManager = vm.envAddress("POSITION_MANAGER");
        address deployer = vm.addr(deployerKey);

        console.log("=== Mindstate Protocol Deployment ===");
        console.log("Deployer:          ", deployer);
        console.log("WETH:              ", weth);
        console.log("V3 Factory:        ", v3Factory);
        console.log("Position Manager:  ", positionManager);
        console.log("");

        vm.startBroadcast(deployerKey);

        // ── 1. MindstateToken implementation ─────────────────────
        MindstateToken implementation = new MindstateToken();
        console.log("1. MindstateToken (impl):    ", address(implementation));

        // ── 2. MindstateFactory (clone factory) ──────────────────
        MindstateFactory factory = new MindstateFactory(address(implementation));
        console.log("2. MindstateFactory:         ", address(factory));

        // ── 3. FeeCollector (platform treasury) ──────────────────
        FeeCollector feeCollector = new FeeCollector(deployer);
        console.log("3. FeeCollector:             ", address(feeCollector));

        // ── 4. MindstateVault (LP NFT custody + fee distribution)
        MindstateVault vault = new MindstateVault(
            positionManager,
            weth,
            deployer
        );
        console.log("4. MindstateVault:           ", address(vault));

        // ── 5. MindstateLaunchFactory (launchpad) ────────────────
        MindstateLaunchFactory launchFactory = new MindstateLaunchFactory(
            address(implementation),
            weth,
            v3Factory,
            positionManager,
            deployer
        );
        console.log("5. MindstateLaunchFactory:   ", address(launchFactory));

        // ── 6. Wire contracts together ───────────────────────────
        //    Vault needs to know its factory (for registerPosition access control)
        vault.setFactory(address(launchFactory));
        console.log("   Vault.factory ->          ", address(launchFactory));

        //    Vault needs the fee collector address (for fee distribution)
        vault.setFeeCollector(address(feeCollector));
        console.log("   Vault.feeCollector ->     ", address(feeCollector));

        //    LaunchFactory needs the vault address (to send LP NFTs)
        launchFactory.setVault(address(vault));
        console.log("   LaunchFactory.vault ->    ", address(vault));

        //    FeeCollector authorizes the vault as a fee source
        feeCollector.setAuthorizedSource(address(vault), true);
        console.log("   FeeCollector authorized:  ", address(vault));

        vm.stopBroadcast();

        // ── Summary ──────────────────────────────────────────────
        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("");
        console.log("Core:");
        console.log("  MindstateToken (impl)     ", address(implementation));
        console.log("  MindstateFactory          ", address(factory));
        console.log("");
        console.log("Launchpad:");
        console.log("  MindstateLaunchFactory    ", address(launchFactory));
        console.log("  MindstateVault            ", address(vault));
        console.log("  FeeCollector              ", address(feeCollector));
        console.log("");
        console.log("Owner (all admin contracts):", deployer);
        console.log("");
        console.log("Next steps:");
        console.log("  1. Verify contracts on block explorer (--verify flag)");
        console.log("  2. Optionally set launch agents: launchFactory.setLaunchAgent(agent, true)");
        console.log("  3. Accept ownership via Ownable2Step if transferring admin");
    }
}
