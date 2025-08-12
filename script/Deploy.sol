pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";

import {UpgradeableProxy} from "../src/UpgradeableProxy.sol";

contract Deploy is Script {
    address public deployer;
    address public admin;

    function run() public {
        admin = vm.envAddress("ADMIN_ADDR");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        deployer = vm.createWallet(deployerPrivateKey).addr;
        vm.startBroadcast(deployerPrivateKey);

        deploy();
        // deployLogic();

        vm.stopBroadcast();
    }

    function deploy() public {
        // deploy contracts
    }
}
