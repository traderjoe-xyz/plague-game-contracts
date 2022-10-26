// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import "src/PlagueGame.sol";
import "./mocks/ERC721.sol";
import "chainlink/mocks/VRFCoordinatorV2Mock.sol";

error OnlyCoordinatorCanFulfill(address have, address want);

contract PlagueGameTest is Test {
    // Collection configuration
    uint256 collectionSize = 1200;
    uint256 epochNumber = 12;
    uint256 playerNumberToEndGame = 10;
    uint256[] infectedDoctorsPerEpoch =
        [2_000, 2_000, 2_000, 3_000, 3_000, 3_000, 4_000, 4_000, 4_000, 5_000, 5_000, 5_000];
    uint256 epochDuration = 1 days;
    uint256 prizePot = 100 ether;

    // Test configuration
    uint256[] curedDoctorsPerEpoch = [120, 110, 100, 90, 50, 40, 30, 20, 15, 10, 5, 2];
    uint256[] randomWords = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];

    // VRF configuration
    uint64 subscriptionId;
    bytes32 keyHash = "";
    uint32 maxGas = 1_800_000;
    uint256 s_nextRequestId = 1;
    uint96 lastSubscriptionBalance = 100 ether;

    // Test variables
    address BOB = address(0xb0b);

    PlagueGame plagueGame;
    ERC721Mock doctors;
    ERC721Mock potions;
    VRFCoordinatorV2Mock coordinator;

    uint256 lastPotionUsed;
    uint256 randomnessSeedIndex;
    uint256[] doctorsArray;

    function setUp() public {
        doctors = new ERC721Mock();
        potions = new ERC721Mock();
        coordinator = new VRFCoordinatorV2Mock(0,1);

        doctors.mint(collectionSize);
        potions.mint(collectionSize);

        // VRF setup
        subscriptionId = coordinator.createSubscription();
        coordinator.fundSubscription(subscriptionId, lastSubscriptionBalance);

        _gameSetup();
        _initializeGame();
    }

    function testVRFSafeGuards() public {
        plagueGame.startGame();

        vm.expectRevert(abi.encodeWithSelector(OnlyCoordinatorCanFulfill.selector, address(this), address(coordinator)));
        plagueGame.rawFulfillRandomWords(s_nextRequestId, randomWords);

        _mockVRFResponse();

        vm.prank(address(coordinator));
        vm.expectRevert(VRFRequestAlreadyAsked.selector);
        plagueGame.rawFulfillRandomWords(s_nextRequestId - 1, randomWords);

        plagueGame.startEpoch();

        vm.prank(address(coordinator));
        vm.expectRevert(InvalidRequestId.selector);
        plagueGame.rawFulfillRandomWords(s_nextRequestId - 1, randomWords);

        skip(epochDuration);
        plagueGame.endEpoch();

        vm.prank(address(coordinator));
        vm.expectRevert(InvalidRequestId.selector);
        plagueGame.rawFulfillRandomWords(s_nextRequestId - 1, randomWords);

        _mockVRFResponse();
    }

    function testConfigFunctions() public {
        _gameSetup();

        vm.expectRevert(GameNotStarted.selector);
        plagueGame.startGame();

        _initializeGame();

        vm.expectRevert(GameNotOver.selector);
        plagueGame.allowPrizeWithdraw(true);

        testFullGame(0);

        vm.expectRevert(GameAlreadyStarted.selector);
        plagueGame.startGame();

        plagueGame.allowPrizeWithdraw(true);
        assertEq(plagueGame.prizeWithdrawalAllowed(), true, "Withdrawals should be allowed");

        vm.expectRevert(UpdateToSameStatus.selector);
        plagueGame.allowPrizeWithdraw(true);

        plagueGame.allowPrizeWithdraw(false);
        assertEq(plagueGame.prizeWithdrawalAllowed(), false, "Withdrawals should be closed");
    }

    function testGame() public {
        assertEq(plagueGame.currentEpoch(), 0, "starting epoch should be 0");
        assertEq(plagueGame.getHealthyDoctorsNumber(), collectionSize, "all doctors should be healthy");
        assertEq(plagueGame.isGameStarted(), false, "game should not be started");
        assertEq(plagueGame.isGameOver(), false, "game should not be over");

        plagueGame.startGame();

        vm.expectRevert(VRFResponseMissing.selector);
        plagueGame.startEpoch();

        _mockVRFResponse();

        assertEq(plagueGame.isGameStarted(), true, "game should be started");

        for (uint256 i = 0; i < epochNumber; ++i) {
            uint256 healthyDoctorsEndOfEpoch = plagueGame.getHealthyDoctorsNumber();
            uint256[] memory deadDoctorsEndOfEpoch = _fetchDoctorsToStatus(PlagueGame.Status.Dead);

            plagueGame.startEpoch();

            assertEq(plagueGame.currentEpoch(), i + 1, "should be the correct epoch");

            // Epoch can't be started twice
            vm.expectRevert(VRFResponseMissing.selector);
            plagueGame.startEpoch();

            uint256 expectedInfections = healthyDoctorsEndOfEpoch * infectedDoctorsPerEpoch[i] / 10_000;
            assertEq(
                healthyDoctorsEndOfEpoch - plagueGame.getHealthyDoctorsNumber(),
                expectedInfections,
                "correct number of the doctors should have been removed from the healthy doctors set"
            );
            assertEq(
                plagueGame.infectedDoctorsPerEpoch(i + 1),
                expectedInfections,
                "correct number of the doctors should be infected"
            );
            assertEq(
                _fetchDoctorsToStatus(PlagueGame.Status.Infected).length,
                expectedInfections,
                "The expected number of doctors is infected"
            );

            uint256 doctorsToCure = curedDoctorsPerEpoch[i];
            _cureDoctors(doctorsToCure);

            assertEq(
                healthyDoctorsEndOfEpoch - plagueGame.getHealthyDoctorsNumber(),
                expectedInfections - doctorsToCure,
                "Doctors should have been put back in the healthy doctors set"
            );

            assertEq(
                _fetchDoctorsToStatus(PlagueGame.Status.Infected).length,
                expectedInfections - doctorsToCure,
                "The expected number of doctors is infected"
            );

            uint256[] memory deadDoctors = _fetchDoctorsToStatus(PlagueGame.Status.Dead);
            for (uint256 j = 0; j < deadDoctors.length; j++) {
                vm.expectRevert(DoctorNotInfected.selector);
                plagueGame.drinkPotion(deadDoctors[j], lastPotionUsed);
            }

            uint256[] memory healthyDoctors = _fetchDoctorsToStatus(PlagueGame.Status.Healthy);
            for (uint256 j = 0; j < healthyDoctors.length; j++) {
                vm.expectRevert(DoctorNotInfected.selector);
                plagueGame.drinkPotion(healthyDoctors[j], lastPotionUsed);
            }

            vm.expectRevert(EpochNotReadyToEnd.selector);
            plagueGame.endEpoch();

            skip(epochDuration);
            plagueGame.endEpoch();

            if (i == epochNumber - 1) {
                vm.expectRevert(GameIsClosed.selector);
                plagueGame.endEpoch();

                vm.expectRevert(GameIsClosed.selector);
                plagueGame.startEpoch();

                assertEq(plagueGame.isGameOver(), true, "game should be over");
            } else {
                // Epoch can't be ended twice
                vm.expectRevert(EpochAlreadyEnded.selector);
                plagueGame.endEpoch();

                assertEq(plagueGame.isGameOver(), false, "game should not be over");

                vm.expectRevert(VRFResponseMissing.selector);
                plagueGame.startEpoch();

                _mockVRFResponse();
            }

            assertEq(
                _fetchDoctorsToStatus(PlagueGame.Status.Dead).length - deadDoctorsEndOfEpoch.length,
                expectedInfections - doctorsToCure,
                "The expected number of doctors is dead"
            );

            assertEq(_fetchDoctorsToStatus(PlagueGame.Status.Infected).length, 0, "No more infected doctors");
        }
    }

    function testPrizeWithdrawal() public {
        testFullGame(0);

        uint256 aliveDoctors = plagueGame.getHealthyDoctorsNumber();
        uint256[] memory winners = _fetchDoctorsToStatus(PlagueGame.Status.Healthy);

        assertEq(winners.length, aliveDoctors, "The winners array should be the same size as the number of winners");
        assertEq(prizePot, address(plagueGame).balance, "The prize pot should be equal to the contract balance");

        vm.expectRevert(WithdrawalClosed.selector);
        plagueGame.withdrawPrize(winners[0]);

        plagueGame.allowPrizeWithdraw(true);

        uint256 prize = address(plagueGame).balance / aliveDoctors;

        for (uint256 i = 0; i < winners.length; i++) {
            uint256 winner = winners[i];

            vm.prank(BOB);
            vm.expectRevert(NotAWinner.selector);
            plagueGame.withdrawPrize(winner);

            plagueGame.allowPrizeWithdraw(false);

            vm.expectRevert(WithdrawalClosed.selector);
            plagueGame.withdrawPrize(winner);

            plagueGame.allowPrizeWithdraw(true);

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

        for (uint256 i = 0; i < epochNumber; i++) {
            plagueGame.startEpoch();
            _cureRandomDoctors(_randomnessSeed);
            skip(epochDuration);
            plagueGame.endEpoch();
            if (plagueGame.getHealthyDoctorsNumber() <= 10) {
                break;
            }
            if (i != epochNumber - 1) {
                _mockVRFResponse();
            }
        }

        uint256[] memory winners = _fetchDoctorsToStatus(PlagueGame.Status.Healthy);

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
                while (plagueGame.doctorStatus(indexSearchForInfected) != PlagueGame.Status.Infected) {
                    ++indexSearchForInfected;
                }

                _cureDoctor(indexSearchForInfected);
            }
        }
    }

    function _cureDoctor(uint256 _doctorId) private {
        address owner = doctors.ownerOf(_doctorId);
        potions.transferFrom(address(this), owner, lastPotionUsed);

        vm.startPrank(owner);
        potions.approve(address(plagueGame), lastPotionUsed);
        plagueGame.drinkPotion(_doctorId, lastPotionUsed++);
        vm.stopPrank();
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

    function _fetchDoctorsToStatus(PlagueGame.Status _status) private returns (uint256[] memory doctorsFromStatus) {
        for (uint256 i = 0; i < collectionSize; i++) {
            if (plagueGame.doctorStatus(i) == _status) {
                doctorsArray.push(i);
            }
        }

        doctorsFromStatus = doctorsArray;
        doctorsArray = new uint256[](0);
    }

    function _initializeGame() private {
        for (uint256 i = 0; i < 10; i++) {
            plagueGame.initializeGame(collectionSize / 10);
        }

        vm.expectRevert(TooManyInitialized.selector);
        plagueGame.initializeGame(collectionSize / 10);
    }

    function _gameSetup() private {
        plagueGame = new PlagueGame(
            doctors,
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
        (bool success,) = payable(plagueGame).call{value: prizePot}("");
        assert(success);
    }

    receive() external payable {}
}
