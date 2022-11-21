// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "src/IPlagueGame.sol";

import "forge-std/Test.sol";
import "src/Apothecary.sol";
import "src/PlagueGame.sol";
import "./mocks/ERC721.sol";
import "./PlagueGameTest.sol";
import "chainlink/mocks/VRFCoordinatorV2Mock.sol";
import "chainlink/interfaces/VRFCoordinatorV2Interface.sol";

contract ApothecaryTest is PlagueGameTest {
    Apothecary apothecary;

    // // Apothecary config
    uint256 difficulty = 100;
    uint256 brewStartTime = block.timestamp + 5 minutes;

    uint256[] apothecaryPotionsIds;

    function setUp() public override {
        super.setUp();

        apothecary = new Apothecary(
            plagueGame,
            ILaunchpeg(address(potions)),
            IERC721Enumerable(doctors),
            difficulty,
            brewStartTime,
            VRFCoordinatorV2Interface(coordinator),
            subscriptionId,
            keyHash,
            maxGas
        );
        coordinator.addConsumer(subscriptionId, address(apothecary));

        _transferDocsToPlayers();

        potions.setApprovalForAll(address(apothecary), true);
        _addPotions(200);

        vm.warp(brewStartTime);

        for (uint256 i = 0; i < doctors.totalSupply(); i++) {
            apothecary.makePotion(i);
        }

        plagueGame.startGame();
        coordinator.fulfillRandomWords(s_nextRequestId++, address(plagueGame));
    }

    function _addPotions(uint256 _amount) private {
        uint256 totalSupply = potions.totalSupply();

        potions.mint(_amount);
        apothecaryPotionsIds = new uint256[](0);

        for (uint256 i = totalSupply; i < totalSupply + _amount; i++) {
            apothecaryPotionsIds.push(i);
        }

        apothecary.addPotions(apothecaryPotionsIds);
    }

    function testGetStartTime() public {
        assertEq(apothecary.getStartTime(), brewStartTime, "Start time should be equal to timestamp set at deployment");
    }

    function testGetTotalBrewsCount() public {
        uint256 MAX_EPOCH_ATTEMPTS = 10;

        uint256 i;
        uint256 doctorId;
        uint256 brewsCount;
        while (i < MAX_EPOCH_ATTEMPTS) {
            // brew potions for all alive doctors owned by player1
            for (uint256 j = 0; j < doctors.balanceOf(ALICE);) {
                doctorId = doctors.tokenOfOwnerByIndex(ALICE, j);

                if (plagueGame.doctorStatus(doctorId) != IPlagueGame.Status.Dead) {
                    vm.prank(ALICE);
                    apothecary.makePotion(doctorId);

                    // simulate VRF response if that's the first call in that epoch
                    if (j == 0) {
                        _mockVRFResponse(address(apothecary));
                    }

                    unchecked {
                        ++brewsCount;
                    }
                }

                unchecked {
                    ++j;
                }
            }
            skip(apothecary.EPOCH_DURATION() + 1);

            unchecked {
                ++i;
            }
        }

        assertEq(
            apothecary.getTotalBrewsCount(), brewsCount, "Total brews count should equal total number of brew attempts"
        );
    }

    function testGetlatestBrewLogs() public {
        // make sure the last 100 brews are in contract

        apothecary.setDifficulty(2);

        uint256 MAX_EPOCH_ATTEMPTS = 7;
        uint256 RECENT_BREW_LOGS_COUNT = apothecary.RECENT_BREW_LOGS_COUNT();
        uint256 doctorA = doctors.tokenOfOwnerByIndex(ALICE, 0);
        uint256 doctorB = doctors.tokenOfOwnerByIndex(BOB, 0);

        IApothecary.BrewLog[] memory doctorBrewResults = new IApothecary.BrewLog[](MAX_EPOCH_ATTEMPTS * 2);

        bytes32 hash;
        for (uint256 i = 0; i < MAX_EPOCH_ATTEMPTS * 2;) {
            if (plagueGame.doctorStatus(doctorA) != IPlagueGame.Status.Dead) {
                vm.prank(ALICE);
                apothecary.makePotion(doctorA);
                _mockVRFResponse(address(apothecary));
                hash = keccak256(
                    abi.encodePacked(apothecary.getVRFForEpoch(apothecary.getLatestEpochTimestamp()), doctorA)
                );
                IApothecary.BrewLog memory brewLog;
                brewLog.timestamp = block.timestamp;
                brewLog.doctorId = doctorA;
                brewLog.brewPotion = uint256(hash) % apothecary.getDifficulty() == 0;
                doctorBrewResults[i++] = brewLog;
            }

            if (plagueGame.doctorStatus(doctorB) != IPlagueGame.Status.Dead) {
                vm.prank(BOB);
                apothecary.makePotion(doctorB);
                hash = keccak256(
                    abi.encodePacked(apothecary.getVRFForEpoch(apothecary.getLatestEpochTimestamp()), doctorB)
                );
                IApothecary.BrewLog memory brewLog;
                brewLog.timestamp = block.timestamp;
                brewLog.doctorId = doctorB;
                brewLog.brewPotion = uint256(hash) % apothecary.getDifficulty() == 0;
                doctorBrewResults[i++] = brewLog;
            }

            skip(apothecary.EPOCH_DURATION() + 1);
        }

        uint256 offsetIndex =
            doctorBrewResults.length > RECENT_BREW_LOGS_COUNT ? doctorBrewResults.length - RECENT_BREW_LOGS_COUNT : 0;
        uint256 allLogsCount = doctorBrewResults.length;

        for (uint256 i = 0; i < allLogsCount;) {
            if (i == RECENT_BREW_LOGS_COUNT) {
                break;
            }

            assertEq(
                apothecary.getlatestBrewLogs()[i].timestamp,
                doctorBrewResults[offsetIndex + i].timestamp,
                "Timestamp for recent brew should be orderly tracked"
            );
            assertEq(
                apothecary.getlatestBrewLogs()[i].doctorId,
                doctorBrewResults[offsetIndex + i].doctorId,
                "Doctor ID for recent brew should be orderly tracked"
            );
            assertEq(
                apothecary.getlatestBrewLogs()[i].brewPotion,
                doctorBrewResults[offsetIndex + i].brewPotion,
                "Success for recent brew should be orderly tracked"
            );

            unchecked {
                ++i;
            }
        }
    }

    function testGetBrewLogs() public {
        uint256 MAX_EPOCH_ATTEMPTS = 10;
        uint256 doctorA = doctors.tokenOfOwnerByIndex(ALICE, 0);
        bool[] memory doctorABrewResults = new bool[](MAX_EPOCH_ATTEMPTS);
        uint256 doctorABrewsCount;

        uint256 doctorB = doctors.tokenOfOwnerByIndex(BOB, 0);
        bool[] memory doctorBBrewResults = new bool[](MAX_EPOCH_ATTEMPTS);
        uint256 doctorBBrewsCount;

        bytes32 hash;
        for (uint256 i = 0; i < MAX_EPOCH_ATTEMPTS;) {
            if (plagueGame.doctorStatus(doctorA) != IPlagueGame.Status.Dead) {
                vm.prank(ALICE);
                apothecary.makePotion(doctorA);
                _mockVRFResponse(address(apothecary));
                hash = keccak256(
                    abi.encodePacked(apothecary.getVRFForEpoch(apothecary.getLatestEpochTimestamp()), doctorA)
                );
                doctorABrewResults[i] = uint256(hash) % apothecary.getDifficulty() == 0;

                unchecked {
                    ++doctorABrewsCount;
                }
            }

            if (plagueGame.doctorStatus(doctorB) != IPlagueGame.Status.Dead) {
                vm.prank(BOB);
                apothecary.makePotion(doctorB);
                hash = keccak256(
                    abi.encodePacked(apothecary.getVRFForEpoch(apothecary.getLatestEpochTimestamp()), doctorB)
                );
                doctorBBrewResults[i] = uint256(hash) % apothecary.getDifficulty() == 0;

                unchecked {
                    ++doctorBBrewsCount;
                }
            }

            skip(apothecary.EPOCH_DURATION() + 1);
            unchecked {
                ++i;
            }
        }

        assertEq(
            apothecary.getBrewLogs(doctorA, MAX_EPOCH_ATTEMPTS).length,
            doctorABrewsCount,
            "Number of brew logs for a doctorA should equal number of brew attempts across all epochs"
        );
        assertEq(
            apothecary.getBrewLogs(doctorB, MAX_EPOCH_ATTEMPTS).length,
            doctorBBrewsCount,
            "Number of brew logs for a doctorB should equal number of brew attempts across all epochs"
        );
        assertEq(
            apothecary.getTotalBrewsCount(),
            doctorABrewsCount + doctorBBrewsCount,
            "Total number of brew logs should equal number of brew attemps from doctorA and doctorB accross all epochs"
        );

        IApothecary.BrewLog memory nthBrewResult;

        for (uint256 i = 0; i < doctorABrewsCount;) {
            nthBrewResult = apothecary.getBrewLogs(doctorA, MAX_EPOCH_ATTEMPTS)[i];
            assertEq(
                nthBrewResult.brewPotion, doctorABrewResults[i], "Brew logs for doctorA should be stored correctly"
            );

            unchecked {
                ++i;
            }
        }

        for (uint256 i = 0; i < doctorBBrewsCount;) {
            nthBrewResult = apothecary.getBrewLogs(doctorB, MAX_EPOCH_ATTEMPTS)[i];
            assertEq(
                nthBrewResult.brewPotion, doctorBBrewResults[i], "Brew logs for doctorB should be stored correctly"
            );

            unchecked {
                ++i;
            }
        }
    }

    function testGetTimeToNextEpoch() public {
        assertEq(
            apothecary.getTimeToNextEpoch(), 0, "Time to next epoch should be zero if no brew attempts has occured"
        );

        uint256 doctorId = doctors.tokenOfOwnerByIndex(ALICE, 0);
        vm.prank(ALICE);
        apothecary.makePotion(doctorId);
        _mockVRFResponse(address(apothecary));
        skip(apothecary.EPOCH_DURATION() / 2);

        assertEq(
            apothecary.getTimeToNextEpoch(),
            apothecary.EPOCH_DURATION() / 2,
            "Time to next epoch should be half an epoch's duration"
        );

        skip(apothecary.EPOCH_DURATION() + 1);

        assertEq(
            apothecary.getTimeToNextEpoch(),
            0,
            "Time to next epoch should be zero if an epoch duration has elapsed since lastEpochTimestamp"
        );
    }

    function testGetPotionsLeft() public {
        uint256 initialBalance = potions.balanceOf(address(apothecary));
        assertEq(
            initialBalance,
            apothecary.getPotionsLeft(),
            "Apothecary's potions balance should be equal to it's initial balance if no brew attempt has taken place"
        );

        // brew with a difficulty of [1] (guarantees plague doctor will get a potion)
        apothecary.setDifficulty(1);

        uint256 doctorId = doctors.tokenOfOwnerByIndex(ALICE, 0);
        vm.prank(ALICE);
        apothecary.makePotion(doctorId);
        _mockVRFResponse(address(apothecary));

        assertEq(
            initialBalance - 1,
            apothecary.getPotionsLeft(),
            "Apothecary's potions balance should be less than 1 if a potion is brewed successfully to a plague doctor"
        );
    }

    function testGetVRFForEpoch() public {
        uint256[] memory fakeRandomWords = new uint256[](1);
        fakeRandomWords[0] = 1;

        uint256 doctorId = doctors.tokenOfOwnerByIndex(ALICE, 0);
        vm.prank(ALICE);
        apothecary.makePotion(doctorId);
        coordinator.fulfillRandomWordsWithOverride(s_nextRequestId++, address(apothecary), fakeRandomWords);

        assertEq(
            apothecary.getVRFForEpoch(apothecary.getLatestEpochTimestamp()),
            fakeRandomWords[0],
            "VRF for an epoch stored in contract should be equal to VRF generated for that epoch"
        );
    }

    function testGetDifficulty() public {
        assertEq(
            apothecary.getDifficulty(),
            difficulty,
            "Difficulty should be equal to difficulty set at contract deployment"
        );

        uint256 newDifficulty = 50;
        apothecary.setDifficulty(newDifficulty);

        assertEq(apothecary.getDifficulty(), newDifficulty, "Difficulty should be equal to new difficulty set");
    }

    function testGetLatestEpochTimestamp() public {
        assertEq(
            apothecary.getLatestEpochTimestamp(), 0, "Latest epoch timestamp should be zero before any brew attempts"
        );

        // latestEpochTimestamp is tracked on first brew attempt
        uint256 doctorId = doctors.tokenOfOwnerByIndex(ALICE, 0);
        vm.prank(ALICE);
        apothecary.makePotion(doctorId);
        _mockVRFResponse(address(apothecary));

        uint256 timestampForFirstBrew = block.timestamp;
        assertEq(
            apothecary.getLatestEpochTimestamp(),
            timestampForFirstBrew,
            "Latest epoch timestamp should be time of first brew"
        );

        // attempt brew again in next epoch to track latestEpochTimestamp
        skip(apothecary.EPOCH_DURATION() + 1);
        vm.prank(ALICE);
        apothecary.makePotion(doctorId);
        _mockVRFResponse(address(apothecary));

        assertEq(
            apothecary.getLatestEpochTimestamp(),
            timestampForFirstBrew + apothecary.EPOCH_DURATION(),
            "Latest epoch timestamp should be one epoch farther from timestamp of first brew"
        );

        // forward the block.timestamp by 3 epochs
        skip((apothecary.EPOCH_DURATION() * 3));
        assertEq(
            apothecary.getLatestEpochTimestamp(),
            timestampForFirstBrew + apothecary.EPOCH_DURATION(),
            "Latest epoch timestamp should not change if no brew attempt occured in elapsed epochs"
        );
    }

    function testGetTriedInEpoch() public {
        uint256 doctorA = doctors.tokenOfOwnerByIndex(ALICE, 0);
        uint256 doctorB = doctors.tokenOfOwnerByIndex(BOB, 0);

        vm.prank(ALICE);
        apothecary.makePotion(doctorA);
        _mockVRFResponse(address(apothecary));

        assertEq(
            apothecary.getTriedInEpoch(apothecary.getLatestEpochTimestamp(), doctorA),
            true,
            "It should show that doctorA attempted brew in current epoch"
        );
        assertEq(
            apothecary.getTriedInEpoch(apothecary.getLatestEpochTimestamp(), doctorB),
            false,
            "It should show that doctorB did not attempt brew in current epoch"
        );

        skip(apothecary.EPOCH_DURATION() + 1);

        vm.prank(BOB);
        apothecary.makePotion(doctorB);
        _mockVRFResponse(address(apothecary));

        assertEq(
            apothecary.getTriedInEpoch(apothecary.getLatestEpochTimestamp(), doctorA),
            false,
            "It should show that doctorA did not attempt brew in current epoch"
        );
        assertEq(
            apothecary.getTriedInEpoch(apothecary.getLatestEpochTimestamp(), doctorB),
            true,
            "It should show that doctorB attempted brew in current epoch"
        );
    }

    function testSetStartTime() public {
        vm.warp(brewStartTime - 1);
        uint256 newStartTime = block.timestamp + 10 minutes;

        apothecary.setStartTime(newStartTime);

        assertEq(apothecary.getStartTime(), newStartTime, "Start time should be set to new start time");
    }

    function testCannotSetStartTimestamp() public {
        vm.warp(brewStartTime - 1);
        uint256 newStartTime = block.timestamp - 1;

        vm.expectRevert(InvalidStartTime.selector);
        apothecary.setStartTime(newStartTime);

        skip(1 minutes);
        newStartTime = block.timestamp + 10 minutes;

        vm.expectRevert(BrewHasStarted.selector);
        apothecary.setStartTime(newStartTime);
    }

    function testSetDifficulty() public {
        uint256 newDifficulty = 10;

        apothecary.setDifficulty(newDifficulty);

        assertEq(apothecary.getDifficulty(), newDifficulty, "It should set difficulty to new difficulty");
    }

    function testCannotSetDifficultyGt100_000() public {
        uint256 newDifficulty = 100_001;

        vm.expectRevert(InvalidDifficulty.selector);
        apothecary.setDifficulty(newDifficulty);
    }

    function testCannotSetDifficultyLt1() public {
        uint256 newDifficulty = 0;

        vm.expectRevert(InvalidDifficulty.selector);
        apothecary.setDifficulty(newDifficulty);
    }

    function testSetDifficultyIfNotOwner() public {
        uint256 newDifficulty = 10;

        vm.prank(BOB);
        vm.expectRevert("Ownable: caller is not the owner");
        apothecary.setDifficulty(newDifficulty);
    }

    function testAddPotions() public {
        potions.mint(1);
        uint256 potionId = potions.tokenOfOwnerByIndex(address(this), 0);

        potions.approve(address(apothecary), potionId);

        uint256 apothecaryInitialBalance = potions.balanceOf(address(apothecary));
        uint256 adminInitialBalance = potions.balanceOf(address(this));

        uint256[] memory potionIds = new uint256[](1);
        potionIds[0] = potionId;
        apothecary.addPotions(potionIds);

        assertEq(
            potions.balanceOf(address(this)),
            adminInitialBalance - potionIds.length,
            "Potions balance of ADMIN should reduce by one"
        );
        assertEq(
            potions.balanceOf(address(apothecary)),
            apothecaryInitialBalance + potionIds.length,
            "Potions balance of APOTHECARY should increase by one"
        );
        assertEq(potions.ownerOf(potionId), address(apothecary), "APOTHECARY should be the owner of the potion ID");
    }

    function testMakePotion() public {
        vm.warp(brewStartTime);
        uint256 doctorId = doctors.tokenOfOwnerByIndex(ALICE, 0);

        vm.prank(ALICE);
        apothecary.makePotion(doctorId);

        _mockVRFResponse(address(apothecary));

        assertEq(
            apothecary.getTriedInEpoch(apothecary.getLatestEpochTimestamp(), doctorId),
            true,
            "Should prove that doctor Id has attempted brew in current epoch"
        );
    }

    function testCannotMakePotionIfBrewNotStarted() public {
        vm.warp(brewStartTime - 1);

        uint256 doctorId = doctors.tokenOfOwnerByIndex(ALICE, 0);

        vm.expectRevert(BrewNotStarted.selector);
        vm.prank(ALICE);
        apothecary.makePotion(doctorId);
    }

    function testCannotMakePotionIfDoctorHasBrewedInLatestEpoch() public {
        uint256 doctorId = doctors.tokenOfOwnerByIndex(ALICE, 0);

        vm.prank(ALICE);
        apothecary.makePotion(doctorId);
        _mockVRFResponse(address(apothecary));

        // attempt to brew potion again in same epoch
        vm.expectRevert(abi.encodeWithSelector(DoctorHasBrewed.selector, apothecary.getLatestEpochTimestamp()));
        vm.prank(ALICE);
        apothecary.makePotion(doctorId);
    }

    function testCannotMakePotionInBetweenVRFResponse() public {
        uint256 doctorA = doctors.tokenOfOwnerByIndex(ALICE, 0);
        uint256 doctorB = doctors.tokenOfOwnerByIndex(BOB, 0);

        vm.prank(ALICE);
        apothecary.makePotion(doctorA);

        vm.expectRevert(abi.encodeWithSelector(VrfRequestPending.selector, s_nextRequestId));
        vm.prank(BOB);
        apothecary.makePotion(doctorB);
    }

    /**
     * Helper Functions *
     */

    function _mockVRFResponse(address _consumer) private {
        coordinator.fulfillRandomWords(s_nextRequestId++, _consumer);
        _checkVRFCost();
    }

    function _transferDocsToPlayers() private {
        for (uint256 i = 0; i < 10; i++) {
            doctors.transferFrom(address(this), ALICE, i);
        }

        for (uint256 i = 10; i < 20; i++) {
            doctors.transferFrom(address(this), BOB, i);
        }
    }
}
