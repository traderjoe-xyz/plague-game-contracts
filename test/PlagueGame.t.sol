// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import "src/PlagueGame.sol";
import "./mocks/ERC721.sol";
import "chainlink/mocks/VRFCoordinatorV2Mock.sol";

contract PlagueGameTest is Test {
    uint256 collectionSize = 1000;
    uint256 roundNumber = 12;
    uint256 playerNumberToEndGame = 10;
    uint256[] public infectedDoctorsPerEpoch =
        [2_000, 2_000, 2_000, 3_000, 3_000, 3_000, 4_000, 4_000, 4_000, 5_000, 5_000, 5_000];

    PlagueGame plagueGame;
    ERC721Mock villagers;
    ERC721Mock potions;
    VRFCoordinatorV2Mock coordinator;

    uint256 s_nextRequestId = 1;
    uint256 lastPotionUsed;
    uint256 randomnessSeedIndex;

    function setUp() public {
        villagers = new ERC721Mock();
        potions = new ERC721Mock();
        coordinator = new VRFCoordinatorV2Mock(0,1);

        for (uint256 i = 0; i < collectionSize; i++) {
            villagers.mint();
            potions.mint();
        }

        plagueGame = new PlagueGame(
            villagers,
            potions,
            infectedDoctorsPerEpoch,
            playerNumberToEndGame,
            coordinator
        );

        // VRF setup
        uint64 subId = coordinator.createSubscription();
        coordinator.addConsumer(subId, address(plagueGame));
        coordinator.fundSubscription(subId, 100e18);
    }

    function testGame() public {
        assertEq(plagueGame.currentEpoch(), 0, "starting epoch should be 0");
        assertEq(plagueGame.getHealthyVillagersNumber(), collectionSize, "all villagers should be healthy");

        plagueGame.startGame();

        coordinator.fulfillRandomWords(s_nextRequestId++, address(plagueGame));

        assertEq(plagueGame.currentEpoch(), 1, "first epoch after starting game should be 1");

        plagueGame.startEpoch();

        assertEq(
            collectionSize - plagueGame.getHealthyVillagersNumber(),
            collectionSize * infectedDoctorsPerEpoch[0] / 10_000,
            "20% of the villagers should be unhealthy"
        );
        assertEq(
            plagueGame.infectedDoctorsPerEpoch(1),
            collectionSize * infectedDoctorsPerEpoch[0] / 10_000,
            "20% of the villagers should be infected"
        );

        plagueGame.endEpoch();
    }

    function testFullGame(uint256 _randomnessSeed) public {
        plagueGame.startGame();
        coordinator.fulfillRandomWords(s_nextRequestId++, address(plagueGame));

        for (uint256 i = 0; i < roundNumber; i++) {
            plagueGame.startEpoch();
            _cureRandomDoctors(_randomnessSeed);
            plagueGame.endEpoch();
            if (i != roundNumber - 1 || plagueGame.getHealthyVillagersNumber() <= 10) {
                break;
            }
            coordinator.fulfillRandomWords(s_nextRequestId++, address(plagueGame));
        }
    }

    function _cureRandomDoctors(uint256 _randomnessSeed) private {
        uint256 randomNumberOfDoctorsToCure =
            _getRandomNumber(_randomnessSeed, plagueGame.infectedDoctorsPerEpoch(plagueGame.currentEpoch()));

        _cureDoctors(randomNumberOfDoctorsToCure);
    }

    function _cureDoctors(uint256 _numberCured) private {
        uint256 indexSearchForInfected;
        for (uint256 i = 0; i < _numberCured; i++) {
            if (lastPotionUsed < collectionSize) {
                while (plagueGame.villagerStatus(indexSearchForInfected) != PlagueGame.Status.Infected) {
                    ++indexSearchForInfected;
                }

                address owner = villagers.ownerOf(indexSearchForInfected);
                potions.transferFrom(address(this), owner, lastPotionUsed);

                vm.startPrank(owner);
                potions.approve(address(plagueGame), lastPotionUsed);
                plagueGame.drinkPotion(indexSearchForInfected, lastPotionUsed++);
                vm.stopPrank();
            }
        }
    }

    function _getRandomNumber(uint256 _randomnessSeed, uint256 _bound) private returns (uint256 randomNumber) {
        if (_bound != 0) {
            randomNumber = uint256(keccak256(abi.encode(_randomnessSeed + randomnessSeedIndex++))) % _bound;
        }
    }
}
