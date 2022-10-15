// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import "src/PlagueGame.sol";
import "./mocks/ERC721.sol";
import "chainlink/mocks/VRFCoordinatorV2Mock.sol";

contract PlagueGameTest is Test {
    // Collection configuration
    uint256 collectionSize = 1000;
    uint256 roundNumber = 12;
    uint256 playerNumberToEndGame = 10;
    uint256[] infectedDoctorsPerEpoch =
        [2_000, 2_000, 2_000, 3_000, 3_000, 3_000, 4_000, 4_000, 4_000, 5_000, 5_000, 5_000];
    uint256 epochDuration = 1 days;
    uint256 prizePot = 100 ether;

    // Test configuration
    uint256[] curedDoctorsPerEpoch = [120, 110, 100, 90, 50, 40, 30, 20, 15, 10, 5, 2];

    // VRF configuration
    uint64 subscriptionId;
    bytes32 keyHash = "";
    uint32 maxGas = 1_500_000;
    uint256 s_nextRequestId = 1;
    uint96 lastSubscriptionBalance = 100 ether;

    // Test variables
    address BOB = address(0xb0b);

    PlagueGame plagueGame;
    ERC721Mock villagers;
    ERC721Mock potions;
    VRFCoordinatorV2Mock coordinator;

    uint256 lastPotionUsed;
    uint256 randomnessSeedIndex;
    uint256[] winnersArray;

    function setUp() public {
        villagers = new ERC721Mock();
        potions = new ERC721Mock();
        coordinator = new VRFCoordinatorV2Mock(0,1);

        villagers.mint(collectionSize);
        potions.mint(collectionSize);

        // VRF setup
        subscriptionId = coordinator.createSubscription();
        coordinator.fundSubscription(subscriptionId, lastSubscriptionBalance);

        plagueGame = new PlagueGame(
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

        _initializeGame();

        coordinator.addConsumer(subscriptionId, address(plagueGame));
        (bool success,) = payable(plagueGame).call{value: prizePot}("");
        assert(success);
    }

    function testVRFSafeGuards() public {
        plagueGame.startGame();
        _mockVRFResponse();

        vm.expectRevert();
        _mockVRFResponse();
        --s_nextRequestId;

        plagueGame.startEpoch();
        vm.expectRevert();
        _mockVRFResponse();
        --s_nextRequestId;

        skip(epochDuration);
        plagueGame.endEpoch();

        vm.expectRevert();
        coordinator.fulfillRandomWords(s_nextRequestId - 1, address(plagueGame));

        _mockVRFResponse();
    }

    function testGame() public {
        assertEq(plagueGame.currentEpoch(), 0, "starting epoch should be 0");
        assertEq(plagueGame.getHealthyVillagersNumber(), collectionSize, "all villagers should be healthy");
        assertEq(plagueGame.gameStarted(), false, "game should not be started");
        assertEq(plagueGame.isGameOver(), false, "game should not be over");

        plagueGame.startGame();
        _mockVRFResponse();

        // Game can't be started twice
        vm.expectRevert();
        plagueGame.startGame();

        assertEq(plagueGame.gameStarted(), true, "game should be started");

        for (uint256 i = 0; i < roundNumber; ++i) {
            uint256 healthyVillagersEndOfRound = plagueGame.getHealthyVillagersNumber();
            uint256 deadVillagersEndOfRound = _fetchDoctorsToStatus(PlagueGame.Status.Dead);

            plagueGame.startEpoch();

            assertEq(plagueGame.currentEpoch(), i + 1, "should be the correct epoch");

            // Epoch can't be started twice
            vm.expectRevert();
            plagueGame.startEpoch();

            uint256 expectedInfections = healthyVillagersEndOfRound * infectedDoctorsPerEpoch[i] / 10_000;
            assertEq(
                healthyVillagersEndOfRound - plagueGame.getHealthyVillagersNumber(),
                expectedInfections,
                "correct number of the villagers should have been removed from the healthy villagers set"
            );
            assertEq(
                plagueGame.infectedDoctorsPerEpoch(i + 1),
                expectedInfections,
                "correct number of the villagers should be infected"
            );
            assertEq(
                _fetchDoctorsToStatus(PlagueGame.Status.Infected),
                expectedInfections,
                "The expected number of villagers is infected"
            );

            uint256 doctorsToCure = curedDoctorsPerEpoch[i];
            _cureDoctors(doctorsToCure);

            assertEq(
                healthyVillagersEndOfRound - plagueGame.getHealthyVillagersNumber(),
                expectedInfections - doctorsToCure,
                "Doctors should have been put back in the healthy villagers set"
            );

            assertEq(
                _fetchDoctorsToStatus(PlagueGame.Status.Infected),
                expectedInfections - doctorsToCure,
                "The expected number of villagers is infected"
            );

            skip(epochDuration);
            plagueGame.endEpoch();

            // Epoch can't be ended twice
            vm.expectRevert();
            plagueGame.endEpoch();

            if (i == roundNumber - 1) {
                assertEq(plagueGame.isGameOver(), true, "game should be over");
            } else {
                assertEq(plagueGame.isGameOver(), false, "game should not be over");
                _mockVRFResponse();
            }

            assertEq(
                _fetchDoctorsToStatus(PlagueGame.Status.Dead) - deadVillagersEndOfRound,
                expectedInfections - doctorsToCure,
                "The expected number of villagers is dead"
            );

            assertEq(_fetchDoctorsToStatus(PlagueGame.Status.Infected), 0, "No more infected villagers");
        }
    }

    function testPrizeWithdrawal() public {
        testFullGame(0);
        plagueGame.allowPrizeWithdraw(true);

        uint256 aliveDoctors = plagueGame.getHealthyVillagersNumber();

        uint256[] memory winners = _loadWinners();
        assertEq(winners.length, aliveDoctors, "The winners array should be the same size as the number of winners");
        assertEq(aliveDoctors, 71, "We should have 71 winners");

        assertEq(prizePot, address(plagueGame).balance, "The prize pot should be equal to the contract balance");

        uint256 prize = address(plagueGame).balance / aliveDoctors;

        for (uint256 i = 0; i < winners.length; i++) {
            uint256 winner = winners[i];

            vm.prank(BOB);
            vm.expectRevert();
            plagueGame.withdrawPrize(winner);

            uint256 balanceBefore = address(this).balance;
            plagueGame.withdrawPrize(winner);
            assertEq(address(this).balance, balanceBefore + prize, "The prize should have been withdrawn");

            vm.expectRevert();
            plagueGame.withdrawPrize(winner);
        }
    }

    function testFullGame(uint256 _randomnessSeed) public {
        plagueGame.startGame();
        _mockVRFResponse();

        for (uint256 i = 0; i < roundNumber; i++) {
            plagueGame.startEpoch();
            _cureRandomDoctors(_randomnessSeed);
            skip(epochDuration);
            plagueGame.endEpoch();
            if (plagueGame.getHealthyVillagersNumber() <= 10) {
                break;
            }
            if (i != roundNumber - 1) {
                _mockVRFResponse();
            }
        }

        uint256[] memory winners = _loadWinners();

        // assertLe(winners.length, playerNumberToEndGame, "There should be no more then 10 winners");
        assertGt(winners.length, 0, "There should at least 1 winner");
    }

    function _cureRandomDoctors(uint256 _randomnessSeed) private {
        uint256 randomNumberOfDoctorsToCure =
            _getRandomNumber(_randomnessSeed, plagueGame.infectedDoctorsPerEpoch(plagueGame.currentEpoch()));

        _cureDoctors(randomNumberOfDoctorsToCure);
    }

    function _cureDoctors(uint256 _numberCured) private {
        uint256 indexSearchForInfected;
        for (uint256 i = 0; i < _numberCured; i++) {
            if (lastPotionUsed < collectionSize * 8_000 / 10_000) {
                while (plagueGame.villagerStatus(indexSearchForInfected) != PlagueGame.Status.Infected) {
                    ++indexSearchForInfected;
                }

                address owner = villagers.ownerOf(indexSearchForInfected);
                potions.transferFrom(address(this), owner, lastPotionUsed);

                vm.startPrank(owner);
                potions.approve(address(plagueGame), lastPotionUsed);
                plagueGame.drinkPotion(indexSearchForInfected, lastPotionUsed++);
                vm.stopPrank();
                // console.log(lastPotionUsed);
            }
        }

        // console.log("end round");
    }

    function _getRandomNumber(uint256 _randomnessSeed, uint256 _bound) private returns (uint256 randomNumber) {
        if (_bound != 0) {
            randomNumber = uint256(keccak256(abi.encode(_randomnessSeed, randomnessSeedIndex++))) % _bound;
        }
    }

    function _mockVRFResponse() private {
        coordinator.fulfillRandomWords(s_nextRequestId++, address(plagueGame));
        _checkVRFCost();
    }

    // Safety check to be sure we have a 50% margin on VRF requests for max gas used
    function _checkVRFCost() private {
        (uint96 vrfBalance,,,) = coordinator.getSubscription(subscriptionId);

        assertLt(
            (lastSubscriptionBalance - vrfBalance) * 15_000 / 10_000, maxGas, "Too much gas has been consumed by VRF"
        );
        lastSubscriptionBalance = vrfBalance;
    }

    function _fetchDoctorsToStatus(PlagueGame.Status _status) private view returns (uint256 doctors) {
        for (uint256 i = 0; i < collectionSize; i++) {
            if (plagueGame.villagerStatus(i) == _status) {
                ++doctors;
            }
        }
    }

    function _initializeGame() private {
        for (uint256 i = 0; i < 10; i++) {
            plagueGame.initializeGame(collectionSize / 10);
        }
    }

    function _loadWinners() private returns (uint256[] memory winners) {
        for (uint256 i = 0; i < collectionSize; i++) {
            if (plagueGame.villagerStatus(i) == PlagueGame.Status.Healthy) {
                winnersArray.push(i);
            }
        }

        winners = winnersArray;
        winnersArray = new uint256[](0);
    }

    receive() external payable {}
}
