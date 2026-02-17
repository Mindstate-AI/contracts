// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {MindstateLaunchFactory} from "../src/launchpad/MindstateLaunchFactory.sol";
import {MindstateVault} from "../src/launchpad/MindstateVault.sol";

/**
 * @title RedeployFactory
 * @notice Deploys a new MindstateLaunchFactory with corrected sqrtPriceX96 constants
 *         and rewires the existing vault to use it.
 *
 *         Required environment variables:
 *           DEPLOYER_PRIVATE_KEY  — deployer / owner private key
 *           WETH                  — 0x4200000000000000000000000000000000000006
 *           V3_FACTORY            — 0x33128a8fC17869897dcE68Ed026d694621f6FDfD
 *           POSITION_MANAGER      — 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1
 *           VAULT                 — 0xC5B2Dc478e75188a454e33E89bc4F768c7079068
 *           FEE_COLLECTOR         — 0x19175b230dfFAb8da216Ae29f9596Ac349755D16
 */
contract RedeployFactory is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address weth = vm.envAddress("WETH");
        address v3Factory = vm.envAddress("V3_FACTORY");
        address positionManager = vm.envAddress("POSITION_MANAGER");
        address vaultAddr = vm.envAddress("VAULT");
        address deployer = vm.addr(deployerKey);

        // Existing implementation (reused)
        address implementation = 0x69511A29958867A96D28a15b3Ac614D1e8A4c47B;

        console.log("=== MindstateLaunchFactory Redeploy (sqrtPriceX96 fix) ===");
        console.log("Deployer:", deployer);
        console.log("Vault:   ", vaultAddr);
        console.log("");

        vm.startBroadcast(deployerKey);

        // 1. Deploy new factory with corrected constants
        MindstateLaunchFactory newFactory = new MindstateLaunchFactory(
            implementation,
            weth,
            v3Factory,
            positionManager,
            deployer
        );
        console.log("New MindstateLaunchFactory:", address(newFactory));

        // 2. Wire new factory → existing vault
        newFactory.setVault(vaultAddr);
        console.log("  newFactory.vault ->", vaultAddr);

        // 3. Wire existing vault → new factory
        MindstateVault(vaultAddr).setFactory(address(newFactory));
        console.log("  vault.factory ->  ", address(newFactory));

        vm.stopBroadcast();

        console.log("");
        console.log("=== Redeploy Complete ===");
        console.log("Old factory (deprecated): 0xda0314762b34b79212975A73De63bE62C74AeB31");
        console.log("New factory (active):    ", address(newFactory));
        console.log("");
        console.log("Update frontend config with the new factory address.");
    }
}
