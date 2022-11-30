// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import "src/PlagueGame.sol";
import "src/IPlagueGame.sol";
import "./mocks/ERC721.sol";
import "./mocks/Launchpeg.sol";
import "chainlink/mocks/VRFCoordinatorV2Mock.sol";

error OnlyCoordinatorCanFulfill(address have, address want);

contract PlagueGameTest is Test {
    // Collection configuration
    uint256 collectionSize = 10_000;
    uint256 epochNumber = 12;
    uint256 playerNumberToEndGame = 10;
    uint256[] infectionPercentages =
        [2_000, 2_000, 2_000, 3_000, 3_000, 3_000, 4_000, 4_000, 4_000, 5_000, 5_000, 5_000];
    uint256 epochDuration = 1 days;
    uint256 prizePot = 100 ether;
    uint256 gameStartTime = block.timestamp + 24 hours;

    // Test configuration
    uint256[] curedDoctorsPerEpoch = [1200, 1100, 1000, 900, 500, 400, 300, 200, 150, 100, 50, 20, 1, 1, 1, 0, 0, 0];
    uint256[] randomWords = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];

    // VRF configuration
    uint64 subscriptionId;
    bytes32 keyHash = "";
    uint32 maxGas = 600_000;
    uint256 s_nextRequestId = 1;
    uint96 lastSubscriptionBalance = 100 ether;

    // Test variables
    address public constant ALICE = address(0xa);
    address public constant BOB = address(0xb);

    PlagueGame plagueGame;
    ERC721Mock doctors;
    Launchpeg potions;
    VRFCoordinatorV2Mock coordinator;

    uint256 lastPotionUsed;
    uint256 randomnessSeedIndex;
    uint256[] doctorsArray;

    function setUp() public virtual {
        doctors = new ERC721Mock();
        potions = new Launchpeg();
        coordinator = new VRFCoordinatorV2Mock(0,1);

        doctors.mint(collectionSize);

        // VRF setup
        subscriptionId = coordinator.createSubscription();
        coordinator.fundSubscription(subscriptionId, lastSubscriptionBalance);

        _gameSetup();
    }

    function _gameSetup() internal {
        plagueGame = new PlagueGame(
            doctors,
            potions,
            gameStartTime,
            playerNumberToEndGame,
            infectionPercentages,
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

    function _initializeGame() internal {
        plagueGame.initializeGame(200);
        plagueGame.initializeGame(200);
        plagueGame.initializeGame(225);

        vm.expectRevert(TooManyInitialized.selector);
        plagueGame.initializeGame(1);

        vm.expectRevert(GameNotStarted.selector);
        plagueGame.startGame();

        vm.warp(gameStartTime);
    }

    function _checkVRFCost() internal {
        (uint96 vrfBalance,,,) = coordinator.getSubscription(subscriptionId);

        assertLt(
            (lastSubscriptionBalance - vrfBalance) * 15_000 / 10_000, maxGas, "Too much gas has been consumed by VRF"
        );
        lastSubscriptionBalance = vrfBalance;
    }

    function _forceDoctorStatus(uint256 _doctorID, IPlagueGame.Status _status) internal {
        uint256 firstStorageSlotForStatus = 644;

        uint256 storageSlot = firstStorageSlotForStatus + (_doctorID / 128);
        uint256 statusItem =
            uint256(vm.load(address(plagueGame), bytes32(firstStorageSlotForStatus + (_doctorID / 128))));

        uint256 shift = (_doctorID % 128) * 2;
        uint256 mask = ~(0x03 << shift);

        statusItem &= mask;
        statusItem |= uint256(_status) << shift;

        vm.store(address(plagueGame), bytes32(storageSlot), bytes32(statusItem));

        assertEq(
            uint256(plagueGame.doctorStatus(_doctorID)), uint256(_status), "Doctor should be at the correct status"
        );
    }

    function _forceDoctorStatuses(uint256[] memory _doctorsIds, IPlagueGame.Status _status) internal {
        for (uint256 i = 0; i < _doctorsIds.length; i++) {
            _forceDoctorStatus(_doctorsIds[i], _status);
        }
    }

    receive() external payable {}
}
