// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import "src/PlagueGame.sol";
import "src/Apothecary.sol";
import "test/mocks/ERC721.sol";
import "chainlink/interfaces/VRFCoordinatorV2Interface.sol";

contract DeployScript is Script {
    uint256 startTime = 1668726000;
    uint256 epochDuration = 1 days;
    uint256 playerNumberToEndGame = 10;
    uint256[] infectedDoctorsPerEpoch =
        [2_000, 2_000, 2_000, 3_000, 3_000, 3_000, 4_000, 4_000, 4_000, 5_000, 5_000, 5_000];
    uint256[] difficultyPerEpoch = [0, 50, 50, 58, 58, 67, 67, 100, 100, 134, 134, 200, 200, 400, 400];

    // Fuji
    ERC721Mock doctors = ERC721Mock(0x4f34ef87836d2241c4D4f2cBB36574754Cf1aa50);
    ILaunchpeg potions = ILaunchpeg(0x24c60BFC0572f855f3F5289fca67fc26a7E7E5f1);
    VRFCoordinatorV2Interface coordinator = VRFCoordinatorV2Interface(0x2eD832Ba664535e5886b75D64C46EB9a228C2610);
    uint64 subscriptionId = 139;
    bytes32 keyHash = 0x354d2f95da55398f44b7cff77da56283d9c6c829a4bdf1bbcaf2ad6a4d081f61;
    uint32 maxGas = 800_000;

    // Mainnet
    ERC721Mock doctors_mainnet = ERC721Mock(0xaAcb33a17F99B838B8B9f9D129D21a2627199F4B);
    ILaunchpeg potions_mainnet = ILaunchpeg(0x838769c6d040744217827022A7628cCdfbA7c94c);
    VRFCoordinatorV2Interface coordinator_mainnet =
        VRFCoordinatorV2Interface(0x2eD832Ba664535e5886b75D64C46EB9a228C2610);
    uint64 subscriptionId_mainnet = 139;
    bytes32 keyHash_mainnet = 0x354d2f95da55398f44b7cff77da56283d9c6c829a4bdf1bbcaf2ad6a4d081f61;
    uint32 maxGas_mainnet = 800_000;

    function run() public {
        if (block.chainid == 43114) {
            console.log("Deploying on Avalanche Mainnet");

            doctors = doctors_mainnet;
            potions = potions_mainnet;
            coordinator = coordinator_mainnet;
            subscriptionId = subscriptionId_mainnet;
            keyHash = keyHash_mainnet;
            maxGas = maxGas_mainnet;
        }

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);
        PlagueGame plagueGame = new PlagueGame(
            doctors,
            potions,
            block.timestamp + 120,
            playerNumberToEndGame,
            infectedDoctorsPerEpoch,
            epochDuration,
            coordinator,
            subscriptionId,
            keyHash,
            maxGas
        );

        if (block.chainid != 43114) {
            coordinator.addConsumer(subscriptionId, address(plagueGame));
            plagueGame.transferOwnership(0xdB40a7b71642FE24CC546bdF4749Aa3c0B042f78);
        } else {
            console.log("Deploying on Avalanche Mainnet, don't forget to setup VRF");
        }

        Apothecary apothecary =
        new Apothecary(plagueGame, potions, doctors, block.timestamp + 120, difficultyPerEpoch,  coordinator, subscriptionId, keyHash, maxGas);

        if (block.chainid != 43114) {
            coordinator.addConsumer(subscriptionId, address(apothecary));
            apothecary.transferOwnership(0xdB40a7b71642FE24CC546bdF4749Aa3c0B042f78);
        }
        vm.stopBroadcast();

        console.log("Game deployed at address: ", address(plagueGame));
        console.log("Apothecary deployed at address: ", address(apothecary));
    }
}
