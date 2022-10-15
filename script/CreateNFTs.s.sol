// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import "test/mocks/ERC721.sol";

contract CreateNFTScript is Script {
    uint256 mintNumber = 5;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);
        ERC721Mock villagers = new ERC721Mock();
        ERC721Mock potions = new ERC721Mock();

        villagers.mint(mintNumber);
        potions.mint(mintNumber);
        vm.stopBroadcast();
    }
}
