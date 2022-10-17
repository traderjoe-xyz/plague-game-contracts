// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "openzeppelin/access/Ownable2Step.sol";
import "openzeppelin/utils/structs/EnumerableSet.sol";
import "openzeppelin/token/ERC721//extensions/IERC721Enumerable.sol";
import "chainlink/VRFConsumerBaseV2.sol";
import "chainlink/interfaces/VRFCoordinatorV2Interface.sol";

error InvalidInfectionPercentage();
error TooManyInitialized();
error CollectionTooBig();
error GameAlreadyStarted();
error GameNotStarted();
error GameNotOver();
error GameIsClosed();
error EpochNotReadyToEnd();
error EpochAlreadyEnded();
error DoctorNotInfected();
error UpdateToSameStatus();
error InvalidRequestId();
error VRFResponseMissing();
error VRFRequestAlreadyAsked();
error NotAWinner();
error WithdrawalClosed();
error FundsTransferFailed();

contract PlagueGame is Ownable2Step, VRFConsumerBaseV2 {
    using EnumerableSet for EnumerableSet.UintSet;

    /// Game events
    event GameStarted();
    event RandomWordsFulfilled(uint256 epoch, uint256 requestId);
    event DoctorsInfectedThisEpoch(uint256 indexed epoch, uint256 deadDoctors);
    event DoctorsDeadThisEpoch(uint256 indexed epoch, uint256 deadDoctors);
    event GameOver();
    event PrizeWithdrawn(uint256 indexed villagerId, uint256 prize);
    event PrizePotIncreased(uint256 amount);

    /// Individual events
    event Sick(uint256 indexed villagerId);
    event Cured(uint256 indexed villagerId);
    event Dead(uint256 indexed villagerId);

    /// @dev Different statuses a doctor can have
    enum Status {
        Dead,
        Healthy,
        Infected
    }

    /// @notice Address of the doctor collection contract
    IERC721Enumerable public immutable villagers;
    /// @notice Address of the potion collection contract
    IERC721Enumerable public immutable potions;
    /// @notice Number of doctors still alive triggering the end of the game
    uint256 public immutable playerNumberToEndGame;
    /// @notice Percentage of doctors that will  be infected each epoch
    uint256[] public infectionPercentagePerRound;
    /// @notice Total number of epochs
    uint256 public immutable totalRoundNumber;
    /// @dev Number of doctors in the collection
    uint256 private immutable villagerNumber;

    /// @notice Current epoch. Epoch is incremented at the beginning of each round
    uint256 public currentEpoch;
    /// @notice Duration of each epoch in seconds
    uint256 public epochDuration;
    /// @notice Start time of the latest epoch
    uint256 public epochStartTime;

    /// @notice Status of the villagers
    mapping(uint256 => Status) public villagerStatus;

    /// @notice Stores the number of doctors infect each round
    mapping(uint256 => uint256) public infectedDoctorsPerEpoch;
    /// @notice VRF request IDs for each epoch
    mapping(uint256 => uint256) public epochVRFRequest;
    /// @notice VRF response for each epoch
    mapping(uint256 => uint256[]) public epochVRFNumber;
    /// @notice Stores if a user already claimed his prize for a doctors he owns
    mapping(uint256 => bool) public withdrewPrize;
    /// @dev Stores if an epoch has started
    mapping(uint256 => bool) private epochStarted;
    /// @dev Stores if an epoch has started
    mapping(uint256 => bool) private epochEnded;

    /// @dev List of healthy villagers
    EnumerableSet.UintSet private healthyVillagers;

    /// @notice True is the game is over
    bool public isGameOver;
    /// @notice True is the game started
    bool public gameStarted;
    /// @notice Prize pot that will be distributed to the winners at the end of the game
    uint256 public prizePot;
    /// @notice States if the withdrawal is open. Set by the contract owner
    bool public prizeWithdrawalAllowed;

    /// @dev Address of the VRF coordinator
    VRFCoordinatorV2Interface private immutable vrfCoordinator;
    /// @dev VRF subscription ID
    uint64 private subscriptionId;
    /// @dev VRF key hash
    bytes32 private keyHash;
    /// @dev Max gas used on the VRF callback
    uint32 private maxGas;

    /// @dev Basis point to calulate percentages
    uint256 private constant BASIS_POINT = 10_000;

    modifier gameOn() {
        if (isGameOver || !gameStarted) {
            revert GameIsClosed();
        }
        _;
    }

    /// @dev Constructor
    /// @param _villagers Address of the doctor collection contract
    /// @param _potions Address of the potion collection contract
    /// @param _infectionPercentagePerRound Percentage of doctors that will  be infected each epoch
    /// @param _playerNumberToEndGame Number of doctors still alive triggering the end of the game
    /// @param _epochDuration Duration of each epoch in seconds
    /// @param _vrfCoordinator Address of the VRF coordinator
    /// @param _subscriptionId VRF subscription ID
    /// @param _keyHash VRF key hash
    /// @param _maxGas Max gas used on the VRF callback
    constructor(
        IERC721Enumerable _villagers,
        IERC721Enumerable _potions,
        uint256[] memory _infectionPercentagePerRound,
        uint256 _playerNumberToEndGame,
        uint256 _epochDuration,
        VRFCoordinatorV2Interface _vrfCoordinator,
        uint64 _subscriptionId,
        bytes32 _keyHash,
        uint32 _maxGas
    ) VRFConsumerBaseV2(address(_vrfCoordinator)) {
        for (uint256 i = 0; i < _infectionPercentagePerRound.length; i++) {
            if (_infectionPercentagePerRound[i] > BASIS_POINT) {
                revert InvalidInfectionPercentage();
            }
        }

        villagers = _villagers;
        vrfCoordinator = _vrfCoordinator;
        villagerNumber = _villagers.totalSupply();

        if (villagerNumber > 1200) {
            revert CollectionTooBig();
        }

        playerNumberToEndGame = _playerNumberToEndGame;
        potions = _potions;
        infectionPercentagePerRound = _infectionPercentagePerRound;
        totalRoundNumber = _infectionPercentagePerRound.length;
        epochDuration = _epochDuration;

        // VRF setup
        subscriptionId = _subscriptionId;
        keyHash = _keyHash;
        maxGas = _maxGas;
    }

    /// @notice Gets the number of healthy doctors
    /// @return healthyVillagersNumber Number of healthy doctors
    function getHealthyVillagersNumber() external view returns (uint256 healthyVillagersNumber) {
        healthyVillagersNumber = healthyVillagers.length();
    }

    /// @notice Initializes the game
    /// @dev This function is very expensive is gas, that's why it needs to be called several times
    /// @param _amount Amount of doctors to initialize
    function initializeGame(uint256 _amount) external {
        uint256 lastVillagerUpdated = healthyVillagers.length();

        if (lastVillagerUpdated + _amount > villagerNumber) {
            revert TooManyInitialized();
        }

        uint256 lastIndex = lastVillagerUpdated + _amount;
        for (uint256 i = lastVillagerUpdated; i < lastIndex; i++) {
            villagerStatus[i] = Status.Healthy;
            healthyVillagers.add(i);
        }
    }

    /// @notice Starts and pauses the prize withdrawal
    /// @param _status True to allow the withdrawal of the prize
    function allowPrizeWithdraw(bool _status) external onlyOwner {
        if (!isGameOver) {
            revert GameNotOver();
        }

        if (_status == prizeWithdrawalAllowed) {
            revert UpdateToSameStatus();
        }

        prizeWithdrawalAllowed = _status;
    }

    /// @notice Starts the game
    function startGame() external onlyOwner {
        if (gameStarted) {
            revert GameAlreadyStarted();
        }

        if (healthyVillagers.length() < villagerNumber) {
            revert GameNotStarted();
        }

        gameStarted = true;
        emit GameStarted();

        _requestRandomWords();
    }

    /// @notice Starts a new epoch if the conditions are met
    function startEpoch() external gameOn {
        ++currentEpoch;

        uint256[] memory randomNumbers = epochVRFNumber[epochVRFRequest[currentEpoch]];
        if (randomNumbers.length == 0) {
            revert VRFResponseMissing();
        }

        epochStarted[currentEpoch] = true;
        epochStartTime = block.timestamp;

        uint256 healthyVillagersNumber = healthyVillagers.length();
        uint256 toMakeSick = healthyVillagersNumber * infectionPercentagePerRound[currentEpoch - 1] / BASIS_POINT;

        _infectRandomVillagers(healthyVillagersNumber, toMakeSick, randomNumbers);

        emit DoctorsInfectedThisEpoch(currentEpoch, toMakeSick);
    }

    /// @notice Ends the current epoch if the conditions are met
    function endEpoch() external gameOn {
        if (epochEnded[currentEpoch] == true) {
            revert EpochAlreadyEnded();
        }

        if (block.timestamp < epochStartTime + epochDuration) {
            revert EpochNotReadyToEnd();
        }

        epochEnded[currentEpoch] = true;

        uint256 deads;
        for (uint256 i = 0; i < villagerNumber; ++i) {
            if (villagerStatus[i] == Status.Infected) {
                villagerStatus[i] = Status.Dead;
                ++deads;
                emit Dead(i);
            }
        }

        emit DoctorsDeadThisEpoch(currentEpoch, deads);

        if (healthyVillagers.length() <= 10 || currentEpoch == 12) {
            isGameOver = true;
            emit GameOver();
            return;
        }

        _requestRandomWords();
    }

    /// @notice Burns a potion to cure a doctor
    /// @dev User needs to have given approval to the contract
    /// @param _villagerId ID of the doctor to cure
    /// @param _potionId ID of the potion to use
    function drinkPotion(uint256 _villagerId, uint256 _potionId) external {
        if (villagerStatus[_villagerId] != Status.Infected) {
            revert DoctorNotInfected();
        }

        villagerStatus[_villagerId] = Status.Healthy;
        healthyVillagers.add(_villagerId);

        _burnPotion(_potionId);

        emit Cured(_villagerId);
    }

    /// @notice Withdraws the prize for a winning doctor
    /// @param _villagerId ID of the doctor to withdraw the prize for
    function withdrawPrize(uint256 _villagerId) external {
        if (!prizeWithdrawalAllowed) {
            revert WithdrawalClosed();
        }

        if (
            villagerStatus[_villagerId] != Status.Healthy || villagers.ownerOf(_villagerId) != msg.sender
                || withdrewPrize[_villagerId]
        ) {
            revert NotAWinner();
        }

        withdrewPrize[_villagerId] = true;

        uint256 prize = prizePot / healthyVillagers.length();

        (bool success,) = payable(msg.sender).call{value: prize}("");

        if (!success) {
            revert FundsTransferFailed();
        }

        emit PrizeWithdrawn(_villagerId, prize);
    }

    /// @dev Send AVAX to the contract to increase the prize pot
    receive() external payable {
        prizePot += msg.value;
        emit PrizePotIncreased(msg.value);
    }

    /// @dev Loops through the healthy villagers and infects them until
    /// the number of infected villagers is equal to the requested number
    /// @dev Each VRF random number is used 8 times
    /// @param _healthyVillagersNumber Number of healthy villagers
    /// @param _toMakeSick Number of villagers to infect
    /// @param _randomNumbers Random numbers provided by VRF to use to infect villagers
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
            // Slices the random number to get the random villager that will be infected
            healthyVillagerId =
                _sliceRandomNumber(_randomNumbers[randomNumberId], randomNumberSliceOffset++) % _healthyVillagersNumber;
            villagerId = healthyVillagers.at(healthyVillagerId);

            // Removing the villagers from the healthy villagers list and infecting him
            healthyVillagers.remove(villagerId);
            villagerStatus[villagerId] = Status.Infected;

            --_healthyVillagersNumber;
            ++madeSick;

            // IF the random number has been used 8 times, we get a new one
            if (randomNumberSliceOffset == 8) {
                randomNumberSliceOffset = 0;
                ++randomNumberId;
            }

            emit Sick(villagerId);
        }
    }

    /// @dev Burns a potion NFT
    /// @param _potionId ID of the NFT to burn
    function _burnPotion(uint256 _potionId) internal {
        potions.transferFrom(msg.sender, address(0xdead), _potionId);
    }

    /// @dev Slices a uint256 VRF random number to get a up to 8 uint32 random numbers
    /// @param _randomNumber Random number to slice
    /// @param _offset Offset of the slice
    function _sliceRandomNumber(uint256 _randomNumber, uint256 _offset)
        internal
        pure
        returns (uint32 slicedRadomNumber)
    {
        unchecked {
            slicedRadomNumber = uint32(_randomNumber >> 32 * _offset);
        }
    }

    /// @dev Random numbers will be sliced into uint32s to reduce the amount of random numbers needed
    /// Since the array to select the random villager will be at most 1k, uint32 numbers are enough
    /// to get sufficiently random numbers
    function _requestRandomWords() private {
        // Extra safety check, but that shouldn't happen
        if (epochVRFNumber[epochVRFRequest[currentEpoch + 1]].length != 0) {
            revert VRFRequestAlreadyAsked();
        }

        uint256 infectedDoctors = healthyVillagers.length() * infectionPercentagePerRound[currentEpoch] / BASIS_POINT;
        infectedDoctorsPerEpoch[currentEpoch + 1] = infectedDoctors;
        uint32 wordsNumber = uint32(infectedDoctors / 8 + 1);

        epochVRFRequest[currentEpoch + 1] =
            vrfCoordinator.requestRandomWords(keyHash, subscriptionId, 3, maxGas, wordsNumber);
    }

    /// @dev Callback function used by VRF Coordinator
    /// @param _requestId Request ID
    /// @param _randomWords Random numbers provided by VRF
    function fulfillRandomWords(uint256 _requestId, uint256[] memory _randomWords) internal override {
        if (_requestId != epochVRFRequest[currentEpoch + 1]) {
            revert InvalidRequestId();
        }

        if (epochVRFNumber[epochVRFRequest[currentEpoch + 1]].length != 0) {
            revert VRFRequestAlreadyAsked();
        }

        epochVRFNumber[_requestId] = _randomWords;

        emit RandomWordsFulfilled(currentEpoch + 1, _requestId);
    }
}
