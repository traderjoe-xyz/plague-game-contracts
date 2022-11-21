// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import "src/PlagueGame.sol";
import "src/IPlagueGame.sol";
import "./mocks/ERC721.sol";
import "chainlink/mocks/VRFCoordinatorV2Mock.sol";

error OnlyCoordinatorCanFulfill(address have, address want);

contract PlagueGameTest is Test {
    // Collection configuration
    uint256 collectionSize = 10_000;
    uint256 epochNumber = 12;
    uint256 playerNumberToEndGame = 10;
    uint256[] infectionPercentagePerEpoch =
        [2_000, 2_000, 2_000, 3_000, 3_000, 3_000, 4_000, 4_000, 4_000, 5_000, 5_000, 5_000];
    uint256 epochDuration = 1 days;
    uint256 prizePot = 100 ether;

    // Test configuration
    uint256[] curedDoctorsPerEpoch = [1200, 1100, 1000, 900, 500, 400, 300, 200, 150, 100, 50, 20, 0, 0, 0, 0, 0, 0];
    uint256[] randomWords = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];

    // VRF configuration
    uint64 subscriptionId;
    bytes32 keyHash = "";
    uint32 maxGas = 1_800_000;
    uint256 s_nextRequestId = 1;
    uint96 lastSubscriptionBalance = 100 ether;

    // Test variables
    address public constant ALICE = address(0xa);
    address public constant BOB = address(0xb);

    PlagueGame plagueGame;
    ERC721Mock doctors;
    ERC721Mock potions;
    VRFCoordinatorV2Mock coordinator;

    uint256 lastPotionUsed;
    uint256 randomnessSeedIndex;
    uint256[] doctorsArray;

    function setUp() public virtual {
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

    function _initializeGame() internal {
        plagueGame.initializeGame(200);
        plagueGame.initializeGame(200);
        plagueGame.initializeGame(225);

        vm.expectRevert(TooManyInitialized.selector);
        plagueGame.initializeGame(1);

        vm.expectRevert(GameNotStarted.selector);
        plagueGame.startGame();

        skip(300);
    }

    function _gameSetup() internal {
        plagueGame = new PlagueGame(
            doctors,
            potions,
            block.timestamp + 120,
            playerNumberToEndGame,
            infectionPercentagePerEpoch,
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

    function _checkVRFCost() internal {
        (uint96 vrfBalance,,,) = coordinator.getSubscription(subscriptionId);

        assertLt(
            (lastSubscriptionBalance - vrfBalance) * 15_000 / 10_000, maxGas, "Too much gas has been consumed by VRF"
        );
        lastSubscriptionBalance = vrfBalance;
    }

    receive() external payable {}
}
