// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {TokenClaimerUpgradeable} from "../src/TokenClaimer.sol";
import {UpgradeableProxy} from "../src/UpgradeableProxy.sol";

contract DeployTokenClaimer is Script {
    address public deployer;
    address public tokenAddress;

    function run() public {
        // Get environment variables
        tokenAddress = vm.envAddress("TOKEN_ADDR");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        deployer = vm.createWallet(deployerPrivateKey).addr;

        console.log("=== TokenClaimer Deployment ===");
        console.log("Deployer:", deployer);
        console.log("Token Address:", tokenAddress);

        vm.startBroadcast(deployerPrivateKey);

        deployTokenClaimer();

        vm.stopBroadcast();
    }

    function deployTokenClaimer() public {
        console.log("\n--- Deploying TokenClaimer Logic ---");

        // Deploy the logic contract
        TokenClaimerUpgradeable logic = new TokenClaimerUpgradeable(
            tokenAddress
        );
        console.log("Logic Contract:", address(logic));

        console.log("\n--- Deploying Proxy ---");

        // Deploy the proxy with the logic contract
        UpgradeableProxy proxy = new UpgradeableProxy(
            address(logic),
            deployer,
            ""
        );
        console.log("Proxy Contract:", address(proxy));
        console.log("Proxy Admin:", proxy.proxyAdmin());

        console.log("\n--- Initializing Contract ---");

        // Cast proxy to the logic interface and initialize
        TokenClaimerUpgradeable tokenClaimer = TokenClaimerUpgradeable(
            address(proxy)
        );
        tokenClaimer.initialize();

        console.log("TokenClaimer initialized with token:", tokenAddress);
        console.log("Contract owner:", tokenClaimer.owner());

        console.log("\n=== Deployment Summary ===");
        console.log("Logic Contract Address:", address(logic));
        console.log("Proxy Contract Address:", address(proxy));
        console.log("TokenClaimer Interface:", address(tokenClaimer));
        console.log("Proxy Admin:", proxy.proxyAdmin());
        console.log("Implementation:", proxy.implementation());
    }

    // Function to deploy only the logic contract (for upgrades)
    function deployLogicOnly() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        deployer = vm.createWallet(deployerPrivateKey).addr;

        console.log("=== TokenClaimer Logic Deployment ===");
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        console.log("\n--- Deploying New Logic Contract ---");
        TokenClaimerUpgradeable newLogic = new TokenClaimerUpgradeable(
            tokenAddress
        );
        console.log("New Logic Contract:", address(newLogic));

        vm.stopBroadcast();
    }
}
