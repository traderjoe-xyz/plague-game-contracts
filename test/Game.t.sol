// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import "src/PlagueGame.sol";
import "src/IPlagueGame.sol";
import "./mocks/ERC721.sol";
import "./PlagueGameTest.sol";
import "chainlink/mocks/VRFCoordinatorV2Mock.sol";

contract GameTest is PlagueGameTest {
    uint256 cureFailedAttempts;

    function setUp() public override {
        super.setUp();

        potions.mint(collectionSize);
        potions.setApprovalForAll(address(plagueGame), true);

        _initializeGame();
    }

    function testVRFSafeGuards() public {
        plagueGame.startGame();

        vm.expectRevert(abi.encodeWithSelector(OnlyCoordinatorCanFulfill.selector, address(this), address(coordinator)));
        plagueGame.rawFulfillRandomWords(s_nextRequestId, randomWords);

        _mockVRFResponse();

        vm.prank(address(coordinator));
        vm.expectRevert(VRFAlreadyRequested.selector);
        plagueGame.rawFulfillRandomWords(s_nextRequestId - 1, randomWords);

        _computeInfectedDoctors();
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

        vm.expectRevert(InvalidStartTime.selector);
        plagueGame.updateGameStartTime(block.timestamp - 1);

        plagueGame.updateGameStartTime(block.timestamp + 120);
        assertEq(plagueGame.startTime(), block.timestamp + 120, "Start time should be updated");

        vm.expectRevert(GameNotStarted.selector);
        plagueGame.startGame();

        _initializeGame();

        vm.expectRevert(GameNotOver.selector);
        plagueGame.allowPrizeWithdraw(true);

        skip(300);

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

    function testNoSellout() public {
        doctors = new ERC721Mock();

        collectionSize /= 2;
        doctors.mint(collectionSize);

        _gameSetup();

        plagueGame.initializeGame(200);
        plagueGame.initializeGame(112);

        vm.expectRevert(GameNotStarted.selector);
        plagueGame.startGame();

        plagueGame.initializeGame(1);

        vm.expectRevert(TooManyInitialized.selector);
        plagueGame.initializeGame(1);

        doctors.mint(10);
        uint256 extraMintedDoctorId = collectionSize;

        assertEq(
            uint256(plagueGame.doctorStatus(extraMintedDoctorId - 1)),
            uint256(IPlagueGame.Status.Healthy),
            "Last doctor of the set should be healthy"
        );
        assertEq(
            uint256(plagueGame.doctorStatus(extraMintedDoctorId)),
            uint256(IPlagueGame.Status.Dead),
            "Extra doctors minted after game start should be considered dead"
        );

        skip(300);

        testFullGame(0);

        assertEq(
            uint256(plagueGame.doctorStatus(extraMintedDoctorId)),
            uint256(IPlagueGame.Status.Dead),
            "Extra doctors minted after game start should still be dead at the end of the game"
        );
    }

    function testCureDoctor() public {
        plagueGame.startGame();
        _mockVRFResponse();
        _computeInfectedDoctors();
        plagueGame.startEpoch();

        uint256 doctorID = 178;
        uint256 potionUsed;

        while (plagueGame.getCureSuccessRate(plagueGame.potionUsed(doctorID)) == 65_535) {
            _forceDoctorStatus(doctorID, IPlagueGame.Status.Infected);

            plagueGame.drinkPotion(doctorID, lastPotionUsed++);

            assertEq(
                uint256(plagueGame.doctorStatus(doctorID)),
                uint256(IPlagueGame.Status.Healthy),
                "Doctor should be healthy after a successful cure"
            );

            assertEq(++potionUsed, plagueGame.potionUsed(doctorID), "Potion used should be incremented");

            vm.expectRevert(DoctorNotInfected.selector);
            plagueGame.drinkPotion(doctorID, lastPotionUsed);
        }

        _forceDoctorStatus(doctorID, IPlagueGame.Status.Infected);
        plagueGame.drinkPotion(doctorID, lastPotionUsed++);

        assertEq(++potionUsed, plagueGame.potionUsed(doctorID), "Potion used should be incremented");

        assertEq(
            uint256(plagueGame.doctorStatus(doctorID)),
            uint256(IPlagueGame.Status.Infected),
            "Doctor should remain infected since we're waiting for the VRF response"
        );

        // Can't drink potion while waiting for VRF response
        vm.expectRevert(VRFAlreadyRequested.selector);
        plagueGame.drinkPotion(doctorID, lastPotionUsed++);

        // Testing failed attempt
        uint256[] memory randomNumber = new uint256[](1);
        while (
            uint256(keccak256(abi.encode(randomNumber[0]))) % 65_535
                < plagueGame.getCureSuccessRate(plagueGame.potionUsed(doctorID) - 1)
        ) {
            randomNumber[0]++;
        }

        coordinator.fulfillRandomWordsWithOverride(s_nextRequestId++, address(plagueGame), randomNumber);

        assertEq(uint256(plagueGame.doctorStatus(doctorID)), uint256(IPlagueGame.Status.Infected), "Cure should fail");

        // Tries again and cure succeeds
        _forceDoctorStatus(doctorID, IPlagueGame.Status.Infected);
        plagueGame.drinkPotion(doctorID, lastPotionUsed++);

        assertEq(++potionUsed, plagueGame.potionUsed(doctorID), "Potion used should be incremented");

        while (
            uint256(keccak256(abi.encode(randomNumber[0]))) % 65_535
                >= plagueGame.getCureSuccessRate(plagueGame.potionUsed(doctorID) - 1)
        ) {
            randomNumber[0]++;
        }

        coordinator.fulfillRandomWordsWithOverride(s_nextRequestId++, address(plagueGame), randomNumber);

        assertEq(uint256(plagueGame.doctorStatus(doctorID)), uint256(IPlagueGame.Status.Healthy), "Cure should succeed");
    }

    function testGame() public {
        assertEq(plagueGame.currentEpoch(), 0, "starting epoch should be 0");
        assertEq(plagueGame.healthyDoctorsNumber(), collectionSize, "all doctors should be healthy");
        assertEq(plagueGame.isGameStarted(), false, "game should not be started");
        assertEq(plagueGame.isGameOver(), false, "game should not be over");

        plagueGame.startGame();

        vm.expectRevert(VRFResponseMissing.selector);
        plagueGame.computeInfectedDoctors(collectionSize);

        vm.expectRevert(InfectionNotComputed.selector);
        plagueGame.startEpoch();

        _mockVRFResponse();

        assertEq(plagueGame.isGameStarted(), true, "game should be started");

        uint256 i;
        while (true) {
            cureFailedAttempts = 0;

            uint256 healthyDoctorsEndOfEpoch = plagueGame.healthyDoctorsNumber();

            vm.expectRevert(InfectionNotComputed.selector);
            plagueGame.startEpoch();

            _computeInfectedDoctors();

            vm.expectRevert(NothingToCompute.selector);
            plagueGame.computeInfectedDoctors(collectionSize);

            plagueGame.startEpoch();

            assertEq(plagueGame.currentEpoch(), i + 1, "should be the correct epoch");

            // Epoch can't be started twice
            vm.expectRevert(VRFResponseMissing.selector);
            plagueGame.computeInfectedDoctors(collectionSize);
            vm.expectRevert(InfectionNotComputed.selector);
            plagueGame.startEpoch();

            uint256 expectedInfections = healthyDoctorsEndOfEpoch * _getInfectedDoctorsPerEpoch(i + 1) / 10_000;
            assertEq(
                healthyDoctorsEndOfEpoch - plagueGame.healthyDoctorsNumber(),
                expectedInfections,
                "correct number of the doctors should have been removed from the healthy doctors set"
            );
            assertEq(
                plagueGame.infectedDoctorsPerEpoch(i + 1),
                expectedInfections,
                "correct number of the doctors should be infected"
            );
            assertEq(
                _fetchDoctorsToStatus(IPlagueGame.Status.Infected).length,
                expectedInfections,
                "The expected number of doctors is infected"
            );

            uint256 doctorsToCure = curedDoctorsPerEpoch[i];
            _cureDoctors(doctorsToCure);

            assertEq(
                healthyDoctorsEndOfEpoch - plagueGame.healthyDoctorsNumber(),
                expectedInfections - doctorsToCure + cureFailedAttempts,
                "Some doctors should have been put back in the healthy doctors set"
            );

            assertEq(
                _fetchDoctorsToStatus(IPlagueGame.Status.Infected).length,
                expectedInfections - doctorsToCure + cureFailedAttempts,
                "The expected number of doctors is infected"
            );

            // If there is enough cure attempts, we can epxect that some of them will succeed
            if (doctorsToCure > 20) {
                assertLt(cureFailedAttempts, doctorsToCure, "All the curing attempts failed");
            }

            uint256[] memory healthyDoctors = _fetchDoctorsToStatus(IPlagueGame.Status.Healthy);
            for (uint256 j = 0; j < healthyDoctors.length; j++) {
                vm.expectRevert(DoctorNotInfected.selector);
                plagueGame.drinkPotion(healthyDoctors[j], lastPotionUsed);
            }

            vm.expectRevert(EpochNotReadyToEnd.selector);
            plagueGame.endEpoch();

            skip(epochDuration);
            plagueGame.endEpoch();

            if (plagueGame.isGameOver()) {
                vm.expectRevert(GameIsClosed.selector);
                plagueGame.endEpoch();

                vm.expectRevert(GameIsClosed.selector);
                plagueGame.startEpoch();

                assertEq(plagueGame.isGameOver(), true, "Game should be over");

                assertLe(healthyDoctors.length, playerNumberToEndGame, "There should be less than 10 players");

                // All remaining doctors should in the healthy doctors set
                uint256 numberOfWinners = plagueGame.healthyDoctorsNumber();

                uint256 firstStorageSlotForSet = 19;
                uint256 setSlot = uint256(vm.load(address(plagueGame), bytes32(firstStorageSlotForSet)));

                for (uint256 j = 0; j < numberOfWinners; j++) {
                    uint256 offset = (j % 16) * 16;

                    uint256 doctorId = ((setSlot >> offset) & 0xFFFF);

                    assertEq(
                        uint256(plagueGame.doctorStatus(doctorId)),
                        uint256(IPlagueGame.Status.Healthy),
                        "Doctor should be healthy"
                    );
                }

                break;
            } else {
                // Epoch can't be ended twice
                vm.expectRevert(EpochAlreadyEnded.selector);
                plagueGame.endEpoch();

                assertEq(plagueGame.isGameOver(), false, "Game should not be over");

                vm.expectRevert(VRFResponseMissing.selector);
                plagueGame.computeInfectedDoctors(collectionSize);

                _mockVRFResponse();
            }

            assertEq(
                plagueGame.infectedDoctorsPerEpoch(plagueGame.currentEpoch())
                    - plagueGame.curedDoctorsPerEpoch(plagueGame.currentEpoch()),
                expectedInfections - doctorsToCure + cureFailedAttempts,
                "The expected number of doctors is dead"
            );

            assertEq(_fetchDoctorsToStatus(IPlagueGame.Status.Infected).length, 0, "No more infected doctors");

            ++i;
        }
    }

    function testPrizeWithdrawal() public {
        testFullGame(0);

        uint256 aliveDoctors = plagueGame.healthyDoctorsNumber();
        uint256[] memory winners = _fetchDoctorsToStatus(IPlagueGame.Status.Healthy);

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

        while (true) {
            _computeInfectedDoctors();
            plagueGame.startEpoch();

            _cureRandomDoctors(_randomnessSeed);

            skip(epochDuration);
            plagueGame.endEpoch();

            if (plagueGame.isGameOver()) {
                break;
            }
            _mockVRFResponse();
        }

        uint256[] memory winners = _fetchDoctorsToStatus(IPlagueGame.Status.Healthy);

        assertGt(winners.length, 0, "There should at least 1 winner");

        assertLe(winners.length, playerNumberToEndGame, "There should no more than the expected amount of winners");
    }

    function testGetCureSuccessRate() public {
        for (uint256 i = 0; i < 3; i++) {
            assertEq(
                plagueGame.getCureSuccessRate(i),
                type(uint16).max,
                "The success rate should be 100% for the first 3 potions"
            );
        }

        uint256 previousRate = type(uint16).max;
        for (uint256 i = 3; i < 600; i++) {
            uint256 currentRate = plagueGame.getCureSuccessRate(i);

            assertLe(currentRate, previousRate, "The success rate should decrease over time");
            assertGe(currentRate * 100_000 / type(uint16).max, 239, "The success rate should tend to 0.239%");

            previousRate = currentRate;
        }
    }

    function _computeInfectedDoctors() private {
        uint256 toInfect = plagueGame.infectedDoctorsPerEpoch(plagueGame.currentEpoch() + 1);
        uint256 i;
        while (i < toInfect) {
            plagueGame.computeInfectedDoctors(1e3);
            i += 1e3;
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
            if (lastPotionUsed < collectionSize * 8_000 / 10_000) {
                while (
                    plagueGame.doctorStatus(indexSearchForInfected) != IPlagueGame.Status.Infected
                        && indexSearchForInfected < collectionSize
                ) {
                    ++indexSearchForInfected;
                }
                if (indexSearchForInfected == collectionSize) {
                    break;
                }

                _cureDoctor(indexSearchForInfected);
            }
        }
    }

    function _cureDoctor(uint256 _doctorId) private {
        address owner = doctors.ownerOf(_doctorId);
        potions.transferFrom(address(this), owner, lastPotionUsed);

        (, uint64 reqCount,,) = coordinator.getSubscription(subscriptionId);

        vm.startPrank(owner);
        potions.approve(address(plagueGame), lastPotionUsed);
        plagueGame.drinkPotion(_doctorId, lastPotionUsed++);
        vm.stopPrank();

        (, uint64 newReqCount,,) = coordinator.getSubscription(subscriptionId);
        if (newReqCount > reqCount) {
            _mockVRFResponse();

            if (plagueGame.doctorStatus(_doctorId) == IPlagueGame.Status.Infected) {
                ++cureFailedAttempts;
            }
        }
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

    function _fetchDoctorsToStatus(IPlagueGame.Status _status) private returns (uint256[] memory doctorsFromStatus) {
        for (uint256 i = 0; i < collectionSize; i++) {
            if (plagueGame.doctorStatus(i) == _status) {
                doctorsArray.push(i);
            }
        }

        doctorsFromStatus = doctorsArray;
        doctorsArray = new uint256[](0);
    }

    function _getInfectedDoctorsPerEpoch(uint256 _epoch) private view returns (uint256 infectedDoctors) {
        uint256 numberEpochSet = infectionPercentages.length;
        infectedDoctors =
            _epoch > numberEpochSet ? infectionPercentages[numberEpochSet - 1] : infectionPercentages[_epoch - 1];
    }
}
