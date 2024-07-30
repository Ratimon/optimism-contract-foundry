// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {console2 as console} from "@forge-std/console2.sol";
import {VmSafe} from "@forge-std/Vm.sol";


import {DeployScript, IDeployer} from "@script/deployer/DeployScript.sol";
import {DeployerFunctions} from "@script/deployer/DeployerFunctions.sol";

import {AddressManager} from "@main/legacy/AddressManager.sol";
import {ProxyAdmin} from "@main/universal/ProxyAdmin.sol";

contract DeployProxyAdminScript is DeployScript {
    using DeployerFunctions for IDeployer;

    address owner;

    function deploy() external returns (ProxyAdmin) {
        string memory mnemonic = vm.envString("MNEMONIC");
        uint256 ownerPrivateKey = vm.deriveKey(mnemonic, "m/44'/60'/0'/0/", 1); //  address = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8
        owner = vm.envOr("DEPLOYER", vm.addr(ownerPrivateKey));

        ProxyAdmin proxyAdmin = deployer.deploy_ProxyAdmin("ProxyAdmin", address(owner));
        require(proxyAdmin.owner() == address(owner));

        AddressManager addressManager = AddressManager(deployer.mustGetAddress("AddressManager"));

        // console.log("msg.sender: script");
        // console.log(msg.sender);

        // console.log("proxyAdmin.owner(): script");
        // console.log(proxyAdmin.owner());

        // console.log("addressManager.owner(): script");
        // console.log(addressManager.owner());


        (VmSafe.CallerMode mode ,address msgSender, ) = vm.readCallers();

        // console.log('msgSender');
        // console.log(msgSender);

        // if(mode != VmSafe.CallerMode.Broadcast) {
        //     vm.prank(owner);
        // }
        
        if (proxyAdmin.addressManager() != addressManager) {

             if(mode != VmSafe.CallerMode.Broadcast && msgSender != owner) {
                vm.prank(owner);
             } else {
                console.log("Broadcasting ...");
             }

            proxyAdmin.setAddressManager(addressManager);
        }

        return proxyAdmin;
    }
}
