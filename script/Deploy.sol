pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";

import {PausableERC20Upgradeable} from "../src/PausableERC20Upgradeable.sol";
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
        PausableERC20Upgradeable deployingContract = new PausableERC20Upgradeable();
        UpgradeableProxy proxy = new UpgradeableProxy(
            address(deployingContract),
            admin,
            ""
        );
        deployingContract = PausableERC20Upgradeable(payable(proxy));
        deployingContract.initialize(
            admin,
            "El Salvador Bitcoin",
            "PausableERC20Upgradeable"
        );
        console.log(
            "deployingContract contract address: ",
            address(deployingContract)
        );
    }

    function deployLogic() public {
        // deploy contracts
        PausableERC20Upgradeable deployingContract = new PausableERC20Upgradeable();
        console.log(
            "deployingContract contract address: ",
            address(deployingContract)
        );
    }
}
