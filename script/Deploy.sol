// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {TimeTicketUpgradeable} from "../src/TimeTicket.sol";
import {TeamVault} from "../src/TeamVault.sol";
import {UpgradeableProxy} from "../src/UpgradeableProxy.sol";

contract Deploy is Script {
    address public deployer;

    function run() public {
        // Get environment variables
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        deployer = vm.createWallet(deployerPrivateKey).addr;

        console.log("=== TimeTicket Deployment ===");
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // deployTeamVault();
        deployTimeTicket();

        vm.stopBroadcast();
    }

    function deployTimeTicket() public {
        console.log("\n--- Deploying TimeTicket Logic ---");
        address teamVaultAddress = vm.envAddress("TEAM_VAULT_ADDR");
        address goatVrfAddress = vm.envAddress("GOAT_VRF_ADDR");
        uint256 startingTicketPrice = vm.envUint("STARTING_TICKET_PRICE");

        // Deploy the logic contract
        TimeTicketUpgradeable logic = new TimeTicketUpgradeable();
        console.log("Logic Contract:", address(logic));

        console.log("\n--- Deploying Proxy ---");

        // Deploy the proxy with the logic contract
        UpgradeableProxy proxy = new UpgradeableProxy(
            address(logic),
            deployer,
            abi.encodeWithSelector(
                TimeTicketUpgradeable.initialize.selector,
                startingTicketPrice,
                teamVaultAddress,
                goatVrfAddress
            )
        );
        console.log("Proxy Contract:", address(proxy));
        console.log("Proxy Admin:", proxy.proxyAdmin());

        console.log("\n--- Contract Initialized ---");

        // Cast proxy to the logic interface for verification
        TimeTicketUpgradeable timeTicket = TimeTicketUpgradeable(
            payable(address(proxy))
        );

        console.log("TimeTicket initialized with:");
        console.log(
            "  Starting Ticket Price:",
            timeTicket.startingTicketPrice()
        );
        console.log("  Vault Address:", timeTicket.vault());
        console.log("  GoatVRF Address:", address(timeTicket.goatVrf()));
        console.log("  Extension Per Ticket:", timeTicket.extensionPerTicket());
        console.log(
            "  Airdrop Winners Count:",
            timeTicket.airdropWinnersCount()
        );
        console.log("  Contract Owner:", timeTicket.owner());
        console.log("  Fee Recipient:", timeTicket.feeRecipient());

        console.log("\n=== Deployment Summary ===");
        console.log("Logic Contract Address:", address(logic));
        console.log("Proxy Contract Address:", address(proxy));
        console.log("TimeTicket Interface:", address(timeTicket));
        console.log("Proxy Admin:", proxy.proxyAdmin());
        console.log("Implementation:", proxy.implementation());
    }

    // Function to deploy only the logic contract (for upgrades)
    function deployLogicOnly() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        deployer = vm.createWallet(deployerPrivateKey).addr;

        console.log("=== TimeTicket Logic Deployment ===");

        console.log("\n--- Deploying New Logic Contract ---");
        TimeTicketUpgradeable newLogic = new TimeTicketUpgradeable();
        console.log("New Logic Contract:", address(newLogic));
    }

    // Function to deploy TeamVault if needed
    function deployTeamVault() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        deployer = vm.createWallet(deployerPrivateKey).addr;

        console.log("=== TeamVault Deployment ===");

        console.log("\n--- Deploying TeamVault ---");
        TeamVault vault = new TeamVault(deployer);
        console.log("TeamVault Contract:", address(vault));
        console.log("TeamVault Owner:", vault.owner());
    }
}
