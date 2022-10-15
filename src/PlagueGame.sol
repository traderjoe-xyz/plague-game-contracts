// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "openzeppelin/access/Ownable2Step.sol";
import "openzeppelin/utils/structs/EnumerableSet.sol";
import "openzeppelin/token/ERC721//extensions/IERC721Enumerable.sol";
import "chainlink/VRFConsumerBaseV2.sol";
import "chainlink/interfaces/VRFCoordinatorV2Interface.sol";

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
    mapping(uint256 => bool) public epochEnded;

    bool public isGameOver;
    bool public gameStarted;
    uint256 public prizePot;

    uint256[] public infectionPercentagePerRound;
    uint256 public immutable totalRoundNumber;
    mapping(uint256 => uint256) public infectedDoctorsPerEpoch;

    uint256 public currentEpoch;
    bool public epochLocked;
    uint256 public epochDuration;
    uint256 public epochStartTime;

    EnumerableSet.UintSet healthyVillagers;

    mapping(uint256 => bool) withdrewPrize;

    uint256 private immutable villagerNumber;

    bool prizeWithdrawalAllowed;

    uint64 subscriptionId;
    bytes32 keyHash;
    uint32 maxGas;

    modifier gameOn() {
        if (isGameOver || !gameStarted) {
            revert("game over");
        }
        _;
    }

    constructor(
        IERC721Enumerable _villagers,
        IERC721Enumerable _potions,
        uint256[] memory _rounds,
        uint256 _playerNumberToEndGame,
        uint256 _epochDuration,
        VRFCoordinatorV2Interface _vrfCoordinator,
        uint64 _subscriptionId,
        bytes32 _keyHash,
        uint32 _maxGas
    ) VRFConsumerBaseV2(address(_vrfCoordinator)) {
        villagers = _villagers;
        vrfCoordinator = _vrfCoordinator;
        villagerNumber = _villagers.totalSupply();
        playerNumberToEndGame = _playerNumberToEndGame;

        if (villagerNumber > 2000) {
            revert("Collection too big");
        }

        for (uint256 i = 0; i < _rounds.length; i++) {
            if (_rounds[i] > BASIS_POINT) {
                revert("Invalid infection percentage");
            }
        }

        potions = _potions;
        infectionPercentagePerRound = _rounds;
        totalRoundNumber = _rounds.length;
        epochDuration = _epochDuration;

        subscriptionId = _subscriptionId;
        keyHash = _keyHash;
        maxGas = _maxGas;
    }

    function getHealthyVillagersNumber() external view returns (uint256 healthyVillagersNumber) {
        healthyVillagersNumber = healthyVillagers.length();
    }

    function initializeGame(uint256 _amount) external {
        uint256 lastVillagerUpdated = healthyVillagers.length();

        if (lastVillagerUpdated + _amount > villagerNumber) {
            revert("Too many doctors intialized");
        }

        uint256 lastIndex = lastVillagerUpdated + _amount;
        for (uint256 i = lastVillagerUpdated; i < lastIndex; i++) {
            villagerStatus[i] = Status.Healthy;
            healthyVillagers.add(i);
        }
    }

    function allowPrizeWithdraw(bool _status) external onlyOwner {
        if (_status == prizeWithdrawalAllowed) {
            revert("Prize withdrawal not allowed");
        }

        if (!isGameOver) {
            revert("Game not over");
        }

        prizeWithdrawalAllowed = _status;
    }

    function startGame() external onlyOwner {
        if (healthyVillagers.length() < villagerNumber) {
            revert("Game not ready");
        }

        if (gameStarted) {
            revert("Game already started");
        }

        gameStarted = true;
        _requestRandomWords();
    }

    function startEpoch() public gameOn {
        ++currentEpoch;
        uint256[] memory randomNumbers = epochVRFNumber[epochVRFRequest[currentEpoch]];

        if (randomNumbers.length == 0) {
            revert("need to ask for VRF");
        }

        if (epochStarted[currentEpoch] == true) {
            revert("epoch already started");
        }

        epochStarted[currentEpoch] = true;
        epochStartTime = block.timestamp;

        uint256 healthyVillagersNumber = healthyVillagers.length();
        uint256 toMakeSick = healthyVillagersNumber * infectionPercentagePerRound[currentEpoch - 1] / BASIS_POINT;

        _infectRandomVillagers(healthyVillagersNumber, toMakeSick, randomNumbers);
    }

    function endEpoch() external gameOn {
        if (block.timestamp < epochStartTime + epochDuration) {
            revert("epoch not ended");
        }

        if (epochEnded[currentEpoch] == true) {
            revert("epoch already ended");
        }

        epochEnded[currentEpoch] = true;

        uint256 dead;
        for (uint256 i = 0; i < villagerNumber; ++i) {
            if (villagerStatus[i] == Status.Infected) {
                villagerStatus[i] = Status.Dead;
                // emit Dead(i);
                ++dead;
            }
        }

        if (healthyVillagers.length() <= 10 || currentEpoch == 12) {
            isGameOver = true;
            return;
        }

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

    function withdrawPrize(uint256 _villagerId) external {
        if (!prizeWithdrawalAllowed) {
            revert("withdrawal not open");
        }

        if (
            villagerStatus[_villagerId] != Status.Healthy || villagers.ownerOf(_villagerId) != msg.sender
                || withdrewPrize[_villagerId]
        ) {
            revert("not owner or not healthy");
        }

        withdrewPrize[_villagerId] = true;

        uint256 prize = prizePot / healthyVillagers.length();

        (bool succes,) = payable(msg.sender).call{value: prize}("");

        if (!succes) {
            revert("transfer failed");
        }
    }

    receive() external payable {
        prizePot += msg.value;
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
        uint256 randomNumberId;
        uint256 healthyVillagerId;
        uint256 randomNumberSliceOffset;

        while (madeSick < _toMakeSick) {
            healthyVillagerId =
                _sliceRandomNumber(_randomNumbers[randomNumberId], randomNumberSliceOffset++) % _healthyVillagersNumber;
            villagerId = healthyVillagers.at(healthyVillagerId);

            healthyVillagers.remove(villagerId);

            villagerStatus[villagerId] = Status.Infected;

            // emit Sick(villagerId);

            --_healthyVillagersNumber;
            ++madeSick;

            if (randomNumberSliceOffset == 8) {
                randomNumberSliceOffset = 0;
                ++randomNumberId;
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
        if (epochVRFNumber[epochVRFRequest[currentEpoch + 1]].length != 0) {
            revert("request locked");
        }

        uint256 infectedDoctors = healthyVillagers.length() * infectionPercentagePerRound[currentEpoch] / BASIS_POINT;
        infectedDoctorsPerEpoch[currentEpoch + 1] = infectedDoctors;
        uint32 wordsNumber = uint32(infectedDoctors / 8 + 1);

        epochVRFRequest[currentEpoch + 1] =
            vrfCoordinator.requestRandomWords(keyHash, subscriptionId, 3, maxGas, wordsNumber);
    }

    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal override {
        if (requestId != epochVRFRequest[currentEpoch + 1]) {
            revert("wrong request");
        }

        if (epochVRFNumber[epochVRFRequest[currentEpoch + 1]].length != 0) {
            revert("request locked");
        }

        epochVRFNumber[requestId] = randomWords;

        emit RandomWordsFulfilled(currentEpoch + 1, requestId);
    }
}
