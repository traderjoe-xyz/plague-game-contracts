// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "openzeppelin/access/Ownable2Step.sol";
import "openzeppelin/utils/structs/EnumerableSet.sol";
import "openzeppelin/token/ERC721//extensions/IERC721Enumerable.sol";
import "chainlink/VRFConsumerBaseV2.sol";
import "chainlink/interfaces/VRFCoordinatorV2Interface.sol";

import "forge-std/console.sol";

contract PlagueGame is Ownable2Step, VRFConsumerBaseV2 {
    event Sick(uint256 indexed villagerId);
    event Cured(uint256 indexed villagerId);
    event Dead(uint256 indexed villagerId);
    event RandomWordsFulfilled(uint256 epoch, uint256 requestId);

    using EnumerableSet for EnumerableSet.UintSet;

    enum Status {
        Unknown,
        Healthy,
        Infected,
        Dead
    }

    IERC721Enumerable public immutable villagers;
    IERC721Enumerable public immutable potions;
    VRFCoordinatorV2Interface private immutable vrfCoordinator;
    uint256 public immutable playerNumberToEndGame;

    uint256 private constant BASIS_POINT = 10_000;

    mapping(uint256 => Status) public villagerStatus;
    mapping(uint256 => uint256) public epochVRFRequest;
    mapping(uint256 => uint256[]) public epochVRFNumber;
    mapping(uint256 => bool) public epochStarted;

    bool public isGameOver;
    bool public canWithdraw;
    uint256 public prizePot;
    // mapping(uint256 => uint256) public infectionPercentagePerRound;

    uint256[] public infectionPercentagePerRound;
    uint256 public immutable totalRoundNumber;
    mapping(uint256 => uint256) public infectedDoctorsPerEpoch;

    uint256 public currentEpoch;
    bool public epochLocked;

    EnumerableSet.UintSet healthyVillagers;

    uint256 private immutable villagerNumber;
    uint256 public lastVillagerUpdated;

    modifier gameOn() {
        if (isGameOver) {
            revert("game over");
        }
        _;
    }

    constructor(
        IERC721Enumerable _villagers,
        IERC721Enumerable _potions,
        uint256[] memory _rounds,
        uint256 _playerNumberToEndGame,
        VRFCoordinatorV2Interface _vrfCoordinator
    ) VRFConsumerBaseV2(address(_vrfCoordinator)) {
        villagers = _villagers;
        vrfCoordinator = _vrfCoordinator;
        villagerNumber = _villagers.totalSupply();
        playerNumberToEndGame = _playerNumberToEndGame;

        for (uint256 i = 0; i < villagerNumber; i++) {
            healthyVillagers.add(i);
            villagerStatus[i] = Status.Healthy;
        }

        if (villagerNumber > 1000) {
            revert();
        }

        for (uint256 i = 0; i < _rounds.length; i++) {
            if (_rounds[i] > BASIS_POINT) {
                revert();
            }
        }

        potions = _potions;
        infectionPercentagePerRound = _rounds;
        totalRoundNumber = _rounds.length;
    }

    function getHealthyVillagersNumber() external view returns (uint256 healthyVillagersNumber) {
        healthyVillagersNumber = healthyVillagers.length();
    }

    function startGame() external onlyOwner {
        ++currentEpoch;
        _requestRandomWords();
    }

    function startEpoch() public gameOn {
        uint256[] memory randomNumbers = epochVRFNumber[epochVRFRequest[currentEpoch]];

        if (randomNumbers.length == 0) {
            revert("need to ask for VRF");
        }

        if (epochStarted[currentEpoch] == true) {
            revert("epoch already started");
        }

        epochStarted[currentEpoch] = true;

        uint256 healthyVillagersNumber = healthyVillagers.length();
        uint256 toMakeSick = healthyVillagersNumber * infectionPercentagePerRound[currentEpoch] / BASIS_POINT;

        _infectRandomVillagers(healthyVillagersNumber, toMakeSick, randomNumbers);
    }

    function endEpoch() external gameOn {
        for (uint256 i = 0; i < villagerNumber; i++) {
            if (villagerStatus[i] == Status.Infected) {
                villagerStatus[i] = Status.Dead;
                // emit Dead(i);
            }
        }

        if (healthyVillagers.length() <= 10 || currentEpoch == 12) {
            isGameOver = true;
            return;
        }

        ++currentEpoch;
        _requestRandomWords();
    }

    function drinkPotion(uint256 _villagerId, uint256 _potionId) external {
        if (villagerStatus[_villagerId] != Status.Infected) {
            revert();
        }

        villagerStatus[_villagerId] = Status.Healthy;
        healthyVillagers.add(_villagerId);

        _burnPotion(_potionId);

        // emit Cured(_villagerId);
    }

    // Loops through the healthy villagers and infects them
    // until the number of infected villagers is equal to the
    // requested number
    function _infectRandomVillagers(
        uint256 _healthyVillagersNumber,
        uint256 _toMakeSick,
        uint256[] memory _randomNumbers
    ) private {
        uint256 madeSick;
        uint256 villagerId;
        uint256 randomNumber;
        uint256 randomNumberId;
        uint256 healthyVillagerId;
        uint256 randomNumberSliceOffset;

        while (madeSick < _toMakeSick) {
            randomNumber = _randomNumbers[randomNumberId];
            healthyVillagerId =
                _sliceRandomNumber(_randomNumbers[randomNumberId], randomNumberSliceOffset++) % _healthyVillagersNumber;
            villagerId = healthyVillagers.at(healthyVillagerId);

            healthyVillagers.remove(villagerId);
            villagerStatus[villagerId] = Status.Infected;
            --_healthyVillagersNumber;
            // emit Sick(villagerId);

            ++madeSick;
            if (randomNumberSliceOffset == 8) {
                randomNumberSliceOffset = 0;
                ++randomNumberId;
            } else {
                ++randomNumberSliceOffset;
            }
        }
    }

    function _burnPotion(uint256 _potionId) internal {
        potions.transferFrom(msg.sender, address(0xdead), _potionId);
    }

    function _sliceRandomNumber(uint256 _randomNumber, uint256 _offset)
        internal
        pure
        returns (uint32 slicedRadomNumber)
    {
        unchecked {
            slicedRadomNumber = uint32(_randomNumber >> 32 * _offset);
        }
    }

    // Random numbers will be sliced into uint32 to reduce the amount of random numbers needed
    // Since the array to select the random villager will be at most 1k, uint32 numbers are enough
    // to get sufficiently random numbers
    function _requestRandomWords() private {
        if (epochVRFNumber[epochVRFRequest[currentEpoch]].length != 0) {
            revert("request locked");
        }
        uint256 infectedDoctors = healthyVillagers.length() * infectionPercentagePerRound[currentEpoch] / BASIS_POINT;
        infectedDoctorsPerEpoch[currentEpoch] = infectedDoctors;
        uint32 wordsNumber = uint32(infectedDoctors / 8 + 1);

        epochVRFRequest[currentEpoch] = vrfCoordinator.requestRandomWords("", 1, 5, 800_000, wordsNumber);
    }

    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal override {
        // Checks if this is the correct request
        if (requestId != epochVRFRequest[currentEpoch]) {
            revert("wrong request");
        }

        epochVRFNumber[requestId] = randomWords;

        emit RandomWordsFulfilled(currentEpoch, requestId);

        // startEpoch();
    }
}
