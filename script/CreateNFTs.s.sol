// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import "test/mocks/ERC721.sol";
import "test/mocks/Launchpeg.sol";

contract CreateNFTScript is Script {
    uint256 mintNumber = 5;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);
        ERC721Mock doctors = new ERC721Mock();
        Launchpeg potions = new Launchpeg();

        doctors.mint(mintNumber);
        potions.mint(mintNumber);
        vm.stopBroadcast();

        console.log("Doctors address: ", address(doctors));
        console.log("Potions address: ", address(potions));
    }
}
