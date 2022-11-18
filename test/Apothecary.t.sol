// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "src/IPlagueGame.sol";

import "forge-std/Test.sol";
import "src/Apothecary.sol";
import "src/PlagueGame.sol";
import "./mocks/ERC721.sol";
import "chainlink/mocks/VRFCoordinatorV2Mock.sol";
import "chainlink/interfaces/VRFCoordinatorV2Interface.sol";

contract ApothecaryTest is Test {
    Apothecary public apothecary;
    PlagueGame public plagueGame;
    ERC721Mock public potions;
    ERC721Mock public doctors;
    VRFCoordinatorV2Mock public vrfCoordinator;
    uint256 s_nextRequestId = 1;

    // Test variables
    address public constant ADMIN = address(0xa);
    address public constant PLAYER_1 = address(0xb);
    address public constant PLAYER_2 = address(0xc);

    // Apothecary config
    uint256 public difficulty = 100;

    // PlagueGame init config
    uint256 public constant PLAGUE_DOCTORS_COUNT = 100;
    uint256 epochDuration = 6 hours;
    uint256 playerNumberToEndGame = 10;
    uint256[] infectionPercentagePerEpoch =
        [2_000, 2_000, 2_000, 3_000, 3_000, 3_000, 4_000, 4_000, 4_000, 5_000, 5_000, 5_000];

    // VRF config
    uint64 subscriptionId;
    bytes32 keyHash = "";
    uint32 maxGas = 1_800_000;
    uint96 lastSubscriptionBalance = 100 ether;

    function setUp() public {
        vm.startPrank(ADMIN);
        potions = new ERC721Mock();
        doctors = new ERC721Mock();
        vrfCoordinator = new VRFCoordinatorV2Mock(0, 1);
        vm.stopPrank();

        uint256 collectionSize = 1000;

        _mintDoctorsToPlayer(PLAYER_1, PLAGUE_DOCTORS_COUNT / 2);
        _mintDoctorsToPlayer(PLAYER_2, PLAGUE_DOCTORS_COUNT / 2);

        vm.startPrank(ADMIN);

        subscriptionId = vrfCoordinator.createSubscription();
        vrfCoordinator.fundSubscription(subscriptionId, lastSubscriptionBalance);

        plagueGame = new PlagueGame(
            IERC721Enumerable(doctors),
            IERC721Enumerable(potions),
            infectionPercentagePerEpoch,
            playerNumberToEndGame,
            epochDuration,
            VRFCoordinatorV2Interface(vrfCoordinator),
            subscriptionId,
            keyHash,
            maxGas
        );
        vrfCoordinator.addConsumer(subscriptionId, address(plagueGame));
        vm.deal(address(plagueGame), 1 ether);

        for (uint256 i = 0; i < 10;) {
            plagueGame.initializeGame(PLAGUE_DOCTORS_COUNT / 10);
            unchecked {
                ++i;
            }
        }

        plagueGame.startGame();
        _mockVRFResponse(address(plagueGame));

        plagueGame.startEpoch();

        apothecary = new Apothecary(
            IPlagueGame(plagueGame),
            IERC721Enumerable(potions),
            IERC721Enumerable(doctors),
            difficulty,
            VRFCoordinatorV2Interface(vrfCoordinator),
            subscriptionId,
            keyHash,
            maxGas
        );
        vrfCoordinator.addConsumer(subscriptionId, address(apothecary));
        vm.stopPrank();
        uint256 APOTHECARY_POTIONS_COUNT = 100;
        _mintPotionsToApothecary(APOTHECARY_POTIONS_COUNT);
    }

    function testGetTotalBrewsCount() public {
        uint256 MAX_EPOCH_ATTEMPTS = 10;

        uint256 i;
        uint256 doctorId;
        uint256 brewsCount;
        while (i < MAX_EPOCH_ATTEMPTS) {
            // brew potions for all alive doctors owned by player1
            for (uint256 j = 0; j < doctors.balanceOf(PLAYER_1);) {
                doctorId = doctors.tokenOfOwnerByIndex(PLAYER_1, j);

                if (plagueGame.doctorStatus(doctorId) != IPlagueGame.Status.Dead) {
                    vm.prank(PLAYER_1);
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

    function testGetBrewLogs() public {
        uint256 MAX_EPOCH_ATTEMPTS = 10;
        uint256 doctorA = doctors.tokenOfOwnerByIndex(PLAYER_1, 0);
        bool[] memory doctorABrewResults = new bool[](MAX_EPOCH_ATTEMPTS);
        uint256 doctorABrewsCount;

        uint256 doctorB = doctors.tokenOfOwnerByIndex(PLAYER_2, 0);
        bool[] memory doctorBBrewResults = new bool[](MAX_EPOCH_ATTEMPTS);
        uint256 doctorBBrewsCount;

        bytes32 hash;
        for (uint256 i = 0; i < MAX_EPOCH_ATTEMPTS;) {
            if (plagueGame.doctorStatus(doctorA) != IPlagueGame.Status.Dead) {
                vm.prank(PLAYER_1);
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
                vm.prank(PLAYER_2);
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

        uint256 doctorId = doctors.tokenOfOwnerByIndex(PLAYER_1, 0);
        vm.prank(PLAYER_1);
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
        vm.prank(ADMIN);
        apothecary.setDifficulty(1);

        uint256 doctorId = doctors.tokenOfOwnerByIndex(PLAYER_1, 0);
        vm.prank(PLAYER_1);
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

        uint256 doctorId = doctors.tokenOfOwnerByIndex(PLAYER_1, 0);
        vm.prank(PLAYER_1);
        apothecary.makePotion(doctorId);
        vrfCoordinator.fulfillRandomWordsWithOverride(s_nextRequestId++, address(apothecary), fakeRandomWords);

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
        vm.prank(ADMIN);
        apothecary.setDifficulty(newDifficulty);

        assertEq(apothecary.getDifficulty(), newDifficulty, "Difficulty should be equal to new difficulty set");
    }

    function testGetLatestEpochTimestamp() public {
        assertEq(
            apothecary.getLatestEpochTimestamp(), 0, "Latest epoch timestamp should be zero before any brew attempts"
        );

        // latestEpochTimestamp is tracked on first brew attempt
        uint256 doctorId = doctors.tokenOfOwnerByIndex(PLAYER_1, 0);
        vm.prank(PLAYER_1);
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
        vm.prank(PLAYER_1);
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
        uint256 doctorA = doctors.tokenOfOwnerByIndex(PLAYER_1, 0);
        uint256 doctorB = doctors.tokenOfOwnerByIndex(PLAYER_2, 0);

        vm.prank(PLAYER_1);
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

        vm.prank(PLAYER_2);
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

    function testSetDifficulty() public {
        uint256 newDifficulty = 10;

        vm.prank(ADMIN);
        apothecary.setDifficulty(newDifficulty);

        assertEq(apothecary.getDifficulty(), newDifficulty, "It should set difficulty to new difficulty");
    }

    function testCannotSetDifficultyGt100_000() public {
        uint256 newDifficulty = 100_001;

        vm.expectRevert(InvalidDifficulty.selector);
        vm.prank(ADMIN);
        apothecary.setDifficulty(newDifficulty);
    }

    function testCannotSetDifficultyLt1() public {
        uint256 newDifficulty = 0;

        vm.expectRevert(InvalidDifficulty.selector);
        vm.prank(ADMIN);
        apothecary.setDifficulty(newDifficulty);
    }

    function testFailSetDifficultyIfNotOwner() public {
        uint256 newDifficulty = 10;

        apothecary.setDifficulty(newDifficulty);
    }

    function testAddPotions() public {
        vm.startPrank(ADMIN);
        potions.mint(1);
        uint256 potionId = potions.tokenOfOwnerByIndex(ADMIN, 0);

        potions.approve(address(apothecary), potionId);

        uint256 apothecaryInitialBalance = potions.balanceOf(address(apothecary));
        uint256 adminInitialBalance = potions.balanceOf(ADMIN);

        uint256[] memory potionIds = new uint256[](1);
        potionIds[0] = potionId;
        apothecary.addPotions(potionIds);
        vm.stopPrank();

        assertEq(
            potions.balanceOf(ADMIN),
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

    function testRemovePotions() public {
        uint256 potionA = potions.tokenOfOwnerByIndex(address(apothecary), 0);
        uint256 potionB = potions.tokenOfOwnerByIndex(address(apothecary), 1);

        uint256 apothecaryInitialBalance = potions.balanceOf(address(apothecary));
        uint256 adminInitialBalance = potions.balanceOf(ADMIN);

        uint256[] memory potionIds = new uint256[](2);
        potionIds[0] = potionA;
        potionIds[1] = potionB;

        vm.prank(ADMIN);
        apothecary.removePotions(potionIds);

        assertEq(
            potions.balanceOf(ADMIN),
            adminInitialBalance + potionIds.length,
            "Potions balance of ADMIN should increase by number of potions sent"
        );
        assertEq(
            potions.balanceOf(address(apothecary)),
            apothecaryInitialBalance - potionIds.length,
            "Potions balance of APOTHECARY should reduce by number of potions sent"
        );

        assertEq(potions.ownerOf(potionA), ADMIN, "PotionA should be owned by ADMIN");
        assertEq(potions.ownerOf(potionB), ADMIN, "PotionB should be owned by ADMIN");
    }

    function testMakePotion() public {
        uint256 doctorId = doctors.tokenOfOwnerByIndex(PLAYER_1, 0);

        vm.prank(PLAYER_1);
        apothecary.makePotion(doctorId);
        _mockVRFResponse(address(apothecary));

        assertEq(
            apothecary.getTriedInEpoch(apothecary.getLatestEpochTimestamp(), doctorId),
            true,
            "Should prove that doctor Id has attempted brew in current epoch"
        );
    }

    function testCannotMakePotionIfDoctorIsDead() public {
        uint256 doctorId = doctors.tokenOfOwnerByIndex(PLAYER_1, 0);

        while (plagueGame.doctorStatus(doctorId) != IPlagueGame.Status.Dead) {
            skip(apothecary.EPOCH_DURATION() + 1);
            plagueGame.endEpoch();
            _mockVRFResponse(address(plagueGame));

            plagueGame.startEpoch();
        }

        vm.expectRevert(DoctorIsDead.selector);
        vm.prank(PLAYER_1);
        apothecary.makePotion(doctorId);
    }

    function testCannotMakePotionIfDoctorHasBrewedInLatestEpoch() public {
        uint256 doctorId = doctors.tokenOfOwnerByIndex(PLAYER_1, 0);

        vm.prank(PLAYER_1);
        apothecary.makePotion(doctorId);
        _mockVRFResponse(address(apothecary));

        // attempt to brew potion again in same epoch
        vm.expectRevert(abi.encodeWithSelector(DoctorHasBrewed.selector, apothecary.getLatestEpochTimestamp()));
        vm.prank(PLAYER_1);
        apothecary.makePotion(doctorId);
    }

    function testCannotMakePotionInBetweenVRFResponse() public {
        uint256 doctorA = doctors.tokenOfOwnerByIndex(PLAYER_1, 0);
        uint256 doctorB = doctors.tokenOfOwnerByIndex(PLAYER_2, 0);

        vm.prank(PLAYER_1);
        apothecary.makePotion(doctorA);

        vm.expectRevert(abi.encodeWithSelector(VrfRequestPending.selector, s_nextRequestId));
        vm.prank(PLAYER_2);
        apothecary.makePotion(doctorB);
    }

    // function testCannotMakePotionWithInvalidVRFRequestId() public {
    //     uint256 doctorId = doctors.tokenOfOwnerByIndex(PLAYER_1, 0);
    // 	uint256[] memory mockRandomWords = new uint256[](1);
    //     mockRandomWords[0] = 1;

    //     vm.prank(PLAYER_1);
    //     apothecary.makePotion(doctorId);

    // 	vm.expectRevert(InvalidVrfRequestId.selector);
    // 	vrfCoordinator.fulfillRandomWords(s_nextRequestId - 1, address(apothecary));
    // }

    /**
     * Helper Functions *
     */
    function _mintPotionsToApothecary(uint256 _count) private {
        vm.prank(address(apothecary));
        potions.mint(_count);
    }

    function _mintDoctorsToPlayer(address _player, uint256 _count) private {
        vm.prank(_player);
        doctors.mint(_count);
    }

    function _mockVRFResponse(address _consumer) private {
        vrfCoordinator.fulfillRandomWords(s_nextRequestId++, _consumer);
        _checkVRFCost();
    }

    // Safety check to be sure we have a 50% margin on VRF requests for max gas used
    function _checkVRFCost() private {
        (uint96 vrfBalance,,,) = vrfCoordinator.getSubscription(subscriptionId);

        assertLt(
            (lastSubscriptionBalance - vrfBalance) * 15_000 / 10_000, maxGas, "Too much gas has been consumed by VRF"
        );
        lastSubscriptionBalance = vrfBalance;
    }
}
