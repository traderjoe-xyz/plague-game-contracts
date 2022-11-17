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
    uint8 public difficulty = 100;

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
            vm.warp(block.timestamp + apothecary.EPOCH_DURATION() + 1);

            unchecked {
                ++i;
            }
        }

        // console.log(brewsCount);
        // console.log(apothecary.getTotalBrewsCount());
        assertEq(apothecary.getTotalBrewsCount(), brewsCount);
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

            vm.warp(block.timestamp + apothecary.EPOCH_DURATION() + 1);
            unchecked {
                ++i;
            }
        }

        assertEq(apothecary.getBrewLogs(doctorA, MAX_EPOCH_ATTEMPTS).length, doctorABrewsCount);
        assertEq(apothecary.getBrewLogs(doctorB, MAX_EPOCH_ATTEMPTS).length, doctorBBrewsCount);
        assertEq(apothecary.getTotalBrewsCount(), doctorABrewsCount + doctorBBrewsCount);

        IApothecary.BrewLog memory nthBrewResult;

        for (uint256 i = 0; i < doctorABrewsCount;) {
            nthBrewResult = apothecary.getBrewLogs(doctorA, MAX_EPOCH_ATTEMPTS)[i];
            assertEq(nthBrewResult.brewPotion, doctorABrewResults[i]);

            unchecked {
                ++i;
            }
        }

        for (uint256 i = 0; i < doctorBBrewsCount;) {
            nthBrewResult = apothecary.getBrewLogs(doctorB, MAX_EPOCH_ATTEMPTS)[i];
            assertEq(nthBrewResult.brewPotion, doctorBBrewResults[i]);

            unchecked {
                ++i;
            }
        }
    }

    function testGetTimeToNextEpoch() public {
        assertEq(uint256(apothecary.getTimeToNextEpoch()), 0);

        uint256 doctorId = doctors.tokenOfOwnerByIndex(PLAYER_1, 0);
        vm.prank(PLAYER_1);
        apothecary.makePotion(doctorId);
        _mockVRFResponse(address(apothecary));
        vm.warp(block.timestamp + (apothecary.EPOCH_DURATION() / 2));

        assertEq(uint256(apothecary.getTimeToNextEpoch()), apothecary.EPOCH_DURATION() / 2);

        vm.warp(block.timestamp + apothecary.EPOCH_DURATION() + 1);

        assertEq(apothecary.getTimeToNextEpoch(), 0);
    }

    function testGetPotionsLeft() public {
        uint256 initialBalance = potions.balanceOf(address(apothecary));
        assertEq(initialBalance, apothecary.getPotionsLeft());

        // brew with a difficulty of [1] (guarantees plague doctor will get a potion)
        vm.prank(ADMIN);
        apothecary.setDifficulty(1);

        uint256 doctorId = doctors.tokenOfOwnerByIndex(PLAYER_1, 0);
        vm.prank(PLAYER_1);
        apothecary.makePotion(doctorId);
        _mockVRFResponse(address(apothecary));

        assertEq(initialBalance - 1, apothecary.getPotionsLeft());
    }

    function testGetVRFForEpoch() public {
        uint256[] memory fakeRandomWords = new uint256[](1);
        fakeRandomWords[0] = 1;

        uint256 doctorId = doctors.tokenOfOwnerByIndex(PLAYER_1, 0);
        vm.prank(PLAYER_1);
        apothecary.makePotion(doctorId);
        vrfCoordinator.fulfillRandomWordsWithOverride(s_nextRequestId++, address(apothecary), fakeRandomWords);

        assertEq(apothecary.getVRFForEpoch(apothecary.getLatestEpochTimestamp()), fakeRandomWords[0]);
    }

    function testGetDifficulty() public {
        assertEq(apothecary.getDifficulty(), difficulty);

        uint8 newDifficulty = 50;
        vm.prank(ADMIN);
        apothecary.setDifficulty(newDifficulty);

        assertEq(apothecary.getDifficulty(), newDifficulty);
    }

    function testGetLatestEpochTimestamp() public {
        assertEq(uint256(apothecary.getLatestEpochTimestamp()), 0);

        // latestEpochTimestamp is tracked on first brew attempt
        uint256 doctorId = doctors.tokenOfOwnerByIndex(PLAYER_1, 0);
        vm.prank(PLAYER_1);
        apothecary.makePotion(doctorId);
        _mockVRFResponse(address(apothecary));

        uint112 timestampForFirstBrew = uint112(block.timestamp);
        assertEq(uint256(apothecary.getLatestEpochTimestamp()), timestampForFirstBrew);

        // attempt brew again in next epoch to track latestEpochTimestamp
        vm.warp(block.timestamp + apothecary.EPOCH_DURATION() + 1);
        vm.prank(PLAYER_1);
        apothecary.makePotion(doctorId);
        _mockVRFResponse(address(apothecary));

        assertEq(
            uint256(apothecary.getLatestEpochTimestamp()), uint256(timestampForFirstBrew) + apothecary.EPOCH_DURATION()
        );

        // forward the block.timestamp by 3 epochs
        vm.warp(block.timestamp + (apothecary.EPOCH_DURATION() * 3));
        assertEq(
            uint256(apothecary.getLatestEpochTimestamp()), uint256(timestampForFirstBrew) + apothecary.EPOCH_DURATION()
        );
    }

    function testGetTriedInEpoch() public {
        uint256 doctorA = doctors.tokenOfOwnerByIndex(PLAYER_1, 0);
        uint256 doctorB = doctors.tokenOfOwnerByIndex(PLAYER_2, 0);

        vm.prank(PLAYER_1);
        apothecary.makePotion(doctorA);
        _mockVRFResponse(address(apothecary));

        assertEq(apothecary.getTriedInEpoch(apothecary.getLatestEpochTimestamp(), doctorA), true);
        assertEq(apothecary.getTriedInEpoch(apothecary.getLatestEpochTimestamp(), doctorB), false);

        vm.warp(block.timestamp + apothecary.EPOCH_DURATION() + 1);

        vm.prank(PLAYER_2);
        apothecary.makePotion(doctorB);
        _mockVRFResponse(address(apothecary));

        assertEq(apothecary.getTriedInEpoch(apothecary.getLatestEpochTimestamp(), doctorA), false);
        assertEq(apothecary.getTriedInEpoch(apothecary.getLatestEpochTimestamp(), doctorB), true);
    }

    function testSetDifficulty() public {
        uint8 newDifficulty = 10;

        vm.prank(ADMIN);
        apothecary.setDifficulty(newDifficulty);

        assertEq(apothecary.getDifficulty(), newDifficulty);
    }

    function testCannotSetDifficultyGt100() public {
        uint8 newDifficulty = 101;

        vm.expectRevert(InvalidDifficulty.selector);
        vm.prank(ADMIN);
        apothecary.setDifficulty(newDifficulty);
    }

    function testCannotSetDifficultyLt1() public {
        uint8 newDifficulty = 0;

        vm.expectRevert(InvalidDifficulty.selector);
        vm.prank(ADMIN);
        apothecary.setDifficulty(newDifficulty);
    }

    function testFailSetDifficultyIfNotOwner() public {
        uint8 newDifficulty = 10;

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

        assertEq(potions.balanceOf(ADMIN), --adminInitialBalance);
        assertEq(potions.balanceOf(address(apothecary)), ++apothecaryInitialBalance);
        assertEq(potions.ownerOf(potionId), address(apothecary));
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

        assertEq(potions.balanceOf(ADMIN), adminInitialBalance + potionIds.length);
        assertEq(potions.balanceOf(address(apothecary)), apothecaryInitialBalance - potionIds.length);

        assertEq(potions.ownerOf(potionA), ADMIN);
        assertEq(potions.ownerOf(potionB), ADMIN);
    }

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
