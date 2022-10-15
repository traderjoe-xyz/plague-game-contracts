// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import "src/PlagueGame.sol";
import "test/mocks/ERC721.sol";
import "chainlink/interfaces/VRFCoordinatorV2Interface.sol";

contract DeployScript is Script {
    uint256 playerNumberToEndGame = 10;
    uint256[] public infectedDoctorsPerEpoch =
        [2_000, 2_000, 2_000, 3_000, 3_000, 3_000, 4_000, 4_000, 4_000, 5_000, 5_000, 5_000];
    uint256 epochDuration = 1 days;

    ERC721Mock villagers = ERC721Mock(0x6a0e6AA00A85d544f2F6bC6D940aDFBd4FD8b4b9);
    ERC721Mock potions = ERC721Mock(0xd7C046164bd7D84Db761bD9F97A5AF8D16B93332);
    VRFCoordinatorV2Interface coordinator = VRFCoordinatorV2Interface(0x2eD832Ba664535e5886b75D64C46EB9a228C2610);

    uint64 subscriptionId = 139;
    bytes32 keyHash = 0x354d2f95da55398f44b7cff77da56283d9c6c829a4bdf1bbcaf2ad6a4d081f61;
    uint32 maxGas = 800_000;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);
        PlagueGame plagueGame = new PlagueGame(
            villagers,
            potions,
            infectedDoctorsPerEpoch,
            playerNumberToEndGame,
            epochDuration,
            coordinator,
            subscriptionId,
            keyHash,
            maxGas
        );

        coordinator.addConsumer(subscriptionId, address(plagueGame));
        plagueGame.startGame();
        vm.stopBroadcast();

        console.log("Contract deployed at address: ", address(plagueGame));
    }
}
