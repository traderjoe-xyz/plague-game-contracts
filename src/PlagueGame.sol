// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "openzeppelin/access/Ownable.sol";
import "chainlink/VRFConsumerBaseV2.sol";
import "chainlink/interfaces/VRFCoordinatorV2Interface.sol";

import "./IPlagueGame.sol";

contract PlagueGame is IPlagueGame, Ownable, VRFConsumerBaseV2 {
    /// @notice Address of the doctor collection contract
    IERC721Enumerable public immutable override doctors;
    /// @notice Address of the potion collection contract
    IERC721Enumerable public immutable override potions;
    /// @notice Start time of the game, timestamp in seconds
    uint256 public override startTime;
    /// @notice Number of doctors still alive triggering the end of the game
    uint256 public immutable override playerNumberToEndGame;
    /// @notice Percentage of doctors that will be infected each epoch
    uint256[] public override infectionPercentagePerEpoch;
    /// @notice Total number of epochs with a defined infection percentage. If the game lasts longer, the last percentage defined will be used
    uint256 public immutable override totalDefinedEpochNumber;
    /// @dev Number of doctors in the collection
    uint256 private immutable _doctorNumber;

    /// @notice Number of healthy doctors
    uint256 public override healthyDoctorsNumber;

    /// @notice Current epoch. Epoch is incremented at the beginning of each epoch
    uint256 public override currentEpoch;
    /// @notice Duration of each epoch in seconds
    uint256 public immutable override epochDuration;
    /// @notice Start time of the latest epoch
    uint256 public override epochStartTime;

    /// @notice Stores the number of infected doctors at each epoch. This is purely for the front-end
    mapping(uint256 => uint256) public override infectedDoctorsPerEpoch;
    /// @notice Stores the number of cured doctors at each epoch. This is purely for the front-end
    mapping(uint256 => uint256) public override curedDoctorsPerEpoch;
    /// @notice Stores if a user already claimed his prize for a doctors he owns
    mapping(uint256 => bool) public override withdrewPrize;
    /// @notice VRF request IDs for each epoch
    mapping(uint256 => uint256) private _epochVRFRequest;
    /// @notice VRF response for each epoch
    mapping(uint256 => uint256) private _epochVRFNumber;
    /// @dev Stores if an epoch has ended
    mapping(uint256 => bool) private _epochEnded;

    /// @notice Whether the game is over (true), or not (false)
    bool public override isGameOver;
    /// @notice Whether the game has started (true), or not (false)
    bool public override isGameStarted;
    /// @notice Prize pot that will be distributed to the winners at the end of the game
    uint256 public override prizePot;
    /// @notice States if the withdrawal is open. Set by the contract owner
    bool public override prizeWithdrawalAllowed;

    /// @dev Array containing the Ids of all the healthy doctors
    /// A doctor ID is stored in a 16 bits integer.
    // 16 * 16 = 256 -> 16 doctors IDs per slot
    // 10k / 16 = 625 -> For 10k, need 625 slots
    uint256 private constant HEALTHY_DOCTOR_SET_SIZE = 625;
    uint256[HEALTHY_DOCTOR_SET_SIZE] private _healthyDoctorsSet;
    uint256 private constant DOCTOR_ID_MASK = 0xFFFF;
    uint256 private constant HEALTHY_DOCTOR_BASE_RANGE = 0xf000e000d000c000b000a0009000800070006000500040003000200010000;
    uint256 private constant HEALTHY_DOCTOR_OFFSET = 0x10001000100010001000100010001000100010001000100010001000100010;
    /// @dev Array containing the status of every doctor
    /// A doctor status is stored in a 2 bits integer.
    // 256 / 2 = 128 doctors per slot
    // 10k / 128 = 78.125 need 79 slots
    uint256 private constant DOCTORS_STATUS_SET_SIZE = 79;
    uint256[DOCTORS_STATUS_SET_SIZE] private _doctorsStatusSet;
    uint256 private constant DOCTOR_STATUS_MASK = 0x03;
    /// @dev Used on contract initialization
    uint256 private _lastDoctorAdded;
    /// @dev Initialize all doctor statuses to healthy
    /// Equivalent to 0b01 repeated 128 times
    uint256 private constant HEALTHY_DOCTOR_ARRAY_ITEM =
        0x5555555555555555555555555555555555555555555555555555555555555555;

    /// @dev Keeps track of the doctors already infected for an epoch
    /// Used to paginate startEpoch
    mapping(uint256 => uint256) private _computedInfections;

    /// @dev Address of the VRF coordinator
    VRFCoordinatorV2Interface private immutable _vrfCoordinator;
    /// @dev VRF subscription ID
    uint64 private immutable _subscriptionId;
    /// @dev VRF key hash
    bytes32 private immutable _keyHash;
    /// @dev Max gas used on the VRF callback
    uint32 private immutable _maxGas;

    /// @dev Basis point to calulate percentages
    uint256 private constant BASIS_POINT = 10_000;

    modifier gameOn() {
        if (isGameOver || !isGameStarted) {
            revert GameIsClosed();
        }
        _;
    }

    /// @dev Constructor
    /// @param _doctors Address of the doctor collection contract
    /// @param _potions Address of the potion collection contract
    /// @param _infectionPercentagePerEpoch Percentage of doctors that will  be infected each epoch
    /// @param _playerNumberToEndGame Number of doctors still alive triggering the end of the game
    /// @param _epochDuration Duration of each epoch in seconds
    /// @param vrfCoordinator_ Address of the VRF coordinator
    /// @param subscriptionId_ VRF subscription ID
    /// @param keyHash_ VRF key hash
    /// @param maxGas_ Max gas used on the VRF callback
    constructor(
        IERC721Enumerable _doctors,
        IERC721Enumerable _potions,
        uint256 _startTime,
        uint256 _playerNumberToEndGame,
        uint256[] memory _infectionPercentagePerEpoch,
        uint256 _epochDuration,
        VRFCoordinatorV2Interface vrfCoordinator_,
        uint64 subscriptionId_,
        bytes32 keyHash_,
        uint32 maxGas_
    ) VRFConsumerBaseV2(address(vrfCoordinator_)) {
        if (_playerNumberToEndGame == 0) {
            revert InvalidPlayerNumberToEndGame();
        }

        if (_epochDuration == 0 || _epochDuration > 7 days) {
            revert InvalidEpochDuration();
        }

        if (_startTime < block.timestamp) {
            revert InvalidStartTime();
        }

        for (uint256 i = 0; i < _infectionPercentagePerEpoch.length; i++) {
            if (_infectionPercentagePerEpoch[i] > BASIS_POINT) {
                revert InvalidInfectionPercentage();
            }
        }

        doctors = _doctors;
        _vrfCoordinator = vrfCoordinator_;
        _doctorNumber = _doctors.totalSupply();

        if (_doctorNumber > 10_000 || _doctorNumber == 0) {
            revert InvalidCollection();
        }

        potions = _potions;
        startTime = _startTime;
        playerNumberToEndGame = _playerNumberToEndGame;
        infectionPercentagePerEpoch = _infectionPercentagePerEpoch;
        totalDefinedEpochNumber = _infectionPercentagePerEpoch.length;
        epochDuration = _epochDuration;

        // VRF setup
        _subscriptionId = subscriptionId_;
        _keyHash = keyHash_;
        _maxGas = maxGas_;
    }

    /// @notice Initializes the game
    /// @dev This function is very expensive in gas, that's why it needs to be called several times
    /// @param _amount Amount of _healthyDoctorsSet items to initialize
    function initializeGame(uint256 _amount) external override {
        uint256 currentLastDoctorInSet = _lastDoctorAdded;
        uint256 lastDoctorIdToAdd = currentLastDoctorInSet + _amount;

        if (lastDoctorIdToAdd > (_doctorNumber + 15) / 16) {
            revert TooManyInitialized();
        }

        // Initialize the doctors status set on first call
        if (currentLastDoctorInSet == 0) {
            uint256 arrayLengthToInitialize = (_doctorNumber / 128);
            for (uint256 j = 0; j < arrayLengthToInitialize; ++j) {
                _doctorsStatusSet[j] = HEALTHY_DOCTOR_ARRAY_ITEM;
            }

            _doctorsStatusSet[arrayLengthToInitialize] = HEALTHY_DOCTOR_ARRAY_ITEM >> (128 - (_doctorNumber % 128)) * 2;
        }

        for (uint256 j = currentLastDoctorInSet; j < lastDoctorIdToAdd; j++) {
            uint256 doctorIds = HEALTHY_DOCTOR_BASE_RANGE + HEALTHY_DOCTOR_OFFSET * j;
            _healthyDoctorsSet[j] = doctorIds;
        }

        _lastDoctorAdded = lastDoctorIdToAdd;

        if (lastDoctorIdToAdd == (_doctorNumber + 15) / 16) {
            healthyDoctorsNumber = _doctorNumber;
        }
    }

    /// @notice Starts the game
    function startGame() external override {
        if (isGameStarted) {
            revert GameAlreadyStarted();
        }

        if (healthyDoctorsNumber < _doctorNumber || block.timestamp < startTime) {
            revert GameNotStarted();
        }

        _initiateNewEpoch(1);

        isGameStarted = true;
        emit GameStarted();
    }

    /// @notice Infects doctors prior to the start of the next epoch
    /// @dev This function is very expensive in gas, that's why it needs to be called several times
    /// @param _amount Amount of infected doctors to compute
    function computeInfectedDoctors(uint256 _amount) external override gameOn {
        uint256 nextEpoch = currentEpoch + 1;

        uint256 healthyDoctorsNumberCached = healthyDoctorsNumber;

        uint256 randomNumber = _epochVRFNumber[_epochVRFRequest[nextEpoch]];
        if (randomNumber == 0) {
            revert VRFResponseMissing();
        }

        uint256 infectedDoctorsNextEpoch = infectedDoctorsPerEpoch[nextEpoch];
        uint256 computedInfectionsForNextEpoch = _computedInfections[nextEpoch];

        // Only infect the necessary amount of doctors
        if (computedInfectionsForNextEpoch + _amount > infectedDoctorsNextEpoch) {
            _amount = infectedDoctorsNextEpoch - computedInfectionsForNextEpoch;
        }

        if (_amount == 0) {
            revert NothingToCompute();
        }

        // Infect from offset to offset + _amount
        _infectRandomDoctors(healthyDoctorsNumberCached, computedInfectionsForNextEpoch, _amount, randomNumber);
        healthyDoctorsNumber = healthyDoctorsNumberCached - _amount;

        _computedInfections[nextEpoch] = computedInfectionsForNextEpoch + _amount;
    }

    /// @notice Starts a new epoch if the conditions are met
    function startEpoch() external override gameOn {
        uint256 nextEpoch = currentEpoch + 1;

        if (_computedInfections[nextEpoch] == 0 || _computedInfections[nextEpoch] < infectedDoctorsPerEpoch[nextEpoch])
        {
            revert InfectionNotComputed();
        }

        currentEpoch = nextEpoch;
        epochStartTime = block.timestamp;

        emit DoctorsInfectedThisEpoch(nextEpoch, infectedDoctorsPerEpoch[nextEpoch]);
    }

    /// @notice Ends the current epoch if the conditions are met
    function endEpoch() external override gameOn {
        uint256 currentEpochCached = currentEpoch;

        if (_epochEnded[currentEpochCached] == true) {
            revert EpochAlreadyEnded();
        }

        if (block.timestamp < epochStartTime + epochDuration) {
            revert EpochNotReadyToEnd();
        }

        _epochEnded[currentEpochCached] = true;

        // Updates the infected doctors statuses to Dead
        // 0x5555...555 means 0b01010101...01, all doctors are healthy
        // For infected doctors that have a 0b10 status, this sets the status to 0b00 (dead)
        // For healthy doctors that have a 0b01 status, this doesn't change the status
        // For dead doctors that have a 0b00 status, this doesn't change the status
        for (uint256 i = 0; i < DOCTORS_STATUS_SET_SIZE; ++i) {
            _doctorsStatusSet[i] &= HEALTHY_DOCTOR_ARRAY_ITEM;
        }

        emit EpochEnded(currentEpochCached);

        if (healthyDoctorsNumber <= playerNumberToEndGame) {
            isGameOver = true;
            emit GameOver();
        } else {
            _initiateNewEpoch(currentEpochCached + 1);
        }
    }

    /// @notice Burns a potion to cure a doctor
    /// @dev User needs to have given approval to the contract
    /// @param _doctorId ID of the doctor to cure
    /// @param _potionId ID of the potion to use
    function drinkPotion(uint256 _doctorId, uint256 _potionId) external override {
        if (block.timestamp > epochStartTime + epochDuration) {
            revert EpochAlreadyEnded();
        }

        if (doctorStatus(_doctorId) != Status.Infected) {
            revert DoctorNotInfected();
        }

        uint256 currentEpochCached = currentEpoch;
        curedDoctorsPerEpoch[currentEpochCached] += 1;
        _updateDoctorStatusStorage(_doctorId, Status.Healthy);
        _addDoctorToHealthySet(_doctorId);
        _burnPotion(_potionId);

        emit DoctorCured(_doctorId, _potionId, currentEpochCached);
    }

    /// @notice Updates the game start time
    /// @param _newStartTime New game start time
    function updateGameStartTime(uint256 _newStartTime) external override onlyOwner {
        if (_newStartTime < block.timestamp) {
            revert InvalidStartTime();
        }

        startTime = _newStartTime;
        emit GameStartTimeUpdated(_newStartTime);
    }

    /// @notice Starts and pauses the prize withdrawal
    /// @param _status True to allow the withdrawal of the prize
    function allowPrizeWithdraw(bool _status) external override onlyOwner {
        if (!isGameOver) {
            revert GameNotOver();
        }

        if (_status == prizeWithdrawalAllowed) {
            revert UpdateToSameStatus();
        }

        prizeWithdrawalAllowed = _status;

        emit PrizeWithdrawalAllowed(_status);
    }

    /// @notice Withdraws the prize for a winning doctor
    /// @param _doctorId ID of the doctor to withdraw the prize for
    function withdrawPrize(uint256 _doctorId) external override {
        if (!prizeWithdrawalAllowed) {
            revert WithdrawalClosed();
        }

        if (
            doctorStatus(_doctorId) != Status.Healthy || doctors.ownerOf(_doctorId) != msg.sender
                || withdrewPrize[_doctorId]
        ) {
            revert NotAWinner();
        }

        withdrewPrize[_doctorId] = true;

        uint256 prize = prizePot / healthyDoctorsNumber;

        (bool success,) = payable(msg.sender).call{value: prize}("");

        if (!success) {
            revert FundsTransferFailed();
        }

        emit PrizeWithdrawn(_doctorId, prize);
    }

    ///@notice Allows the contract owner to withdraw the funds
    function withdrawFunds() external override onlyOwner {
        (bool success,) = payable(msg.sender).call{value: address(this).balance}("");

        if (!success) {
            revert FundsTransferFailed();
        }

        emit FundsEmergencyWithdraw(address(this).balance);
    }

    /// @dev Send AVAX to the contract to increase the prize pot
    /// Only possible when the game is still on, to avoid uneven prize distribution
    receive() external payable {
        if (isGameOver) {
            revert CantAddPrizeIfGameIsOver();
        }
        prizePot += msg.value;
        emit PrizePotIncreased(msg.value);
    }

    function doctorStatus(uint256 _doctorId) public view override returns (Status) {
        uint256 statusSetItem = _doctorsStatusSet[_doctorId / 128];
        uint256 shift = (_doctorId % 128) * 2;
        uint256 doctorStatusUint = (statusSetItem >> shift) & DOCTOR_STATUS_MASK;

        if (doctorStatusUint == 2) {
            return Status.Infected;
        } else if (doctorStatusUint == 1) {
            return Status.Healthy;
        } else {
            return Status.Dead;
        }
    }

    /// @dev Requests a random number from Chainlink VRF and starts a new epoch
    /// Called on game start and endEpoch
    /// @param _nextEpoch Next epoch
    function _initiateNewEpoch(uint256 _nextEpoch) private {
        uint256 toMakeSick = healthyDoctorsNumber * _getinfectionRate(_nextEpoch) / BASIS_POINT;

        // Need at least one doctor to be infected, otherwise the game will never end
        if (toMakeSick == 0) {
            toMakeSick = 1;
        }

        // Need at least one doctor left healthy, otherwise the game could end up with no winners
        if (toMakeSick == healthyDoctorsNumber) {
            toMakeSick -= 1;
        }

        infectedDoctorsPerEpoch[_nextEpoch] = toMakeSick;

        _requestRandomWords();
    }

    /// @dev Updates the doctor status directly on storage
    /// @param _doctorId ID of the doctor to update
    /// @param _newStatus New status of the doctor
    function _updateDoctorStatusStorage(uint256 _doctorId, Status _newStatus) private {
        _doctorsStatusSet[_doctorId / 128] =
            _updateDoctorStatusArrayItem(_doctorsStatusSet[_doctorId / 128], _doctorId, _newStatus);
    }

    /// @dev Updates the doctor status in a cached array
    /// @param _doctorsStatusSetMemory Array of doctors statuses cached in memory
    /// @param _doctorId ID of the doctor to update
    /// @param _newStatus New status of the doctor
    function _updateDoctorStatusMemory(
        uint256[DOCTORS_STATUS_SET_SIZE] memory _doctorsStatusSetMemory,
        uint256 _doctorId,
        Status _newStatus
    ) private pure {
        _doctorsStatusSetMemory[_doctorId / 128] =
            _updateDoctorStatusArrayItem(_doctorsStatusSetMemory[_doctorId / 128], _doctorId, _newStatus);
    }

    /// @dev Updates the status of a doctor situated in the given array item
    /// @param _arrayItem The array item to update
    /// @param _doctorId The ID of the doctor to update
    /// @param _newStatus The new status of the doctor
    /// @return _arrayItem The updated array item
    function _updateDoctorStatusArrayItem(uint256 _arrayItem, uint256 _doctorId, Status _newStatus)
        private
        pure
        returns (uint256)
    {
        uint256 shift = (_doctorId % 128) * 2;

        // Mask the 2 bits of the doctor status
        _arrayItem &= ~(DOCTOR_STATUS_MASK << shift);
        // Sets the new status
        _arrayItem |= uint256(_newStatus) << shift;

        return _arrayItem;
    }

    /// @dev Removes a doctor from the set of healthy doctors cached in memory
    /// @param _healthyDoctorsSetMemory Array of doctors IDs cached in memory
    /// @param _healthyDoctorsNumber Total number of doctors in the array
    /// @param _index Index of the doctor to remove
    /// @return doctorId ID of the doctor removed
    function _removeDoctorFromSet(
        uint256[HEALTHY_DOCTOR_SET_SIZE] memory _healthyDoctorsSetMemory,
        uint256 _healthyDoctorsNumber,
        uint256 _index
    ) private pure returns (uint256) {
        // Get the last doctor ID
        uint256 lastDoctorId = _getDoctorIdFromSetMemory(_healthyDoctorsSetMemory, _healthyDoctorsNumber - 1);

        // Get the doctor ID at the index
        uint256 doctorSetItem = _healthyDoctorsSetMemory[_index / 16];
        uint256 doctorId = _getDoctorIdFromSetMemory(_healthyDoctorsSetMemory, _index);

        // Mask the doctor ID at the index
        uint256 offset = (_index % 16) * 16;
        doctorSetItem &= ~(DOCTOR_ID_MASK << offset);
        // Replaces it by the last doctor Id of the array
        doctorSetItem |= (lastDoctorId << offset);
        _healthyDoctorsSetMemory[_index / 16] = doctorSetItem;

        return doctorId;
    }

    /// @dev Adds back a doctor in the set of healthy doctors
    /// @param _doctorId ID of the doctor to add
    function _addDoctorToHealthySet(uint256 _doctorId) private {
        uint256 healthyDoctorsNumberCached = healthyDoctorsNumber;

        // Loads the array item containing the doctor Id
        uint256 lastDoctorSetItem = _healthyDoctorsSet[healthyDoctorsNumberCached / 16];
        // Mask the previous value located at the first unused index
        uint256 offset = (healthyDoctorsNumberCached % 16) * 16;
        lastDoctorSetItem &= ~(DOCTOR_ID_MASK << offset);
        // Add the new doctor Id
        lastDoctorSetItem |= (_doctorId << offset);
        //Update storage
        _healthyDoctorsSet[healthyDoctorsNumberCached / 16] = lastDoctorSetItem;

        healthyDoctorsNumber = healthyDoctorsNumberCached + 1;
    }

    /// @dev Gets the doctor Id from the set of healthy doctors cached in memory
    /// @param _healthyDoctorsSetMemory Array of doctors IDs cached in memory
    /// @param _index Index of the doctor to get from the array
    /// @return doctorId ID of the doctor
    function _getDoctorIdFromSetMemory(uint256[HEALTHY_DOCTOR_SET_SIZE] memory _healthyDoctorsSetMemory, uint256 _index)
        private
        pure
        returns (uint256)
    {
        uint256 doctorSetItem = _healthyDoctorsSetMemory[_index / 16];
        uint256 offset = (_index % 16) * 16;

        return ((doctorSetItem >> offset) & DOCTOR_ID_MASK);
    }

    /// @dev Fetches the right infection rate for the current epoch
    /// If we passed the last defined epoch, we use the last used rate
    /// @param _epoch Epoch
    /// @return infectionRate Infection rate for the considered epoch
    function _getinfectionRate(uint256 _epoch) private view returns (uint256 infectionRate) {
        infectionRate = _epoch > totalDefinedEpochNumber
            ? infectionPercentagePerEpoch[totalDefinedEpochNumber - 1]
            : infectionPercentagePerEpoch[_epoch - 1];
    }

    /// @dev Loops through the healthy doctors and infects them until
    /// the number of infected doctors is equal to the requested number
    /// @dev Each VRF random number is used 8 times
    /// @param _healthyDoctorsNumber Number of healthy doctors
    /// @param _toMakeSick Number of doctors to infect
    /// @param _randomNumber Random number provided by VRF, used to infect doctors
    function _infectRandomDoctors(
        uint256 _healthyDoctorsNumber,
        uint256 _offset,
        uint256 _toMakeSick,
        uint256 _randomNumber
    ) private {
        uint256 madeSick = _offset;
        uint256 doctorId;
        uint256 healthyDoctorId;

        uint256[HEALTHY_DOCTOR_SET_SIZE] memory healthyDoctorsSetCached = _healthyDoctorsSet;
        uint256[DOCTORS_STATUS_SET_SIZE] memory doctorsStatusSetCached = _doctorsStatusSet;

        while (madeSick < _offset + _toMakeSick) {
            // Shuffles the random number to get a new one
            healthyDoctorId = uint256(keccak256(abi.encode(_randomNumber, madeSick))) % _healthyDoctorsNumber;
            // Removing the doctors from the healthy doctors list and infecting him
            doctorId = _removeDoctorFromSet(healthyDoctorsSetCached, _healthyDoctorsNumber, healthyDoctorId);
            _updateDoctorStatusMemory(doctorsStatusSetCached, doctorId, Status.Infected);

            --_healthyDoctorsNumber;
            ++madeSick;
        }

        _healthyDoctorsSet = healthyDoctorsSetCached;
        _doctorsStatusSet = doctorsStatusSetCached;
    }

    /// @dev Burns a potion NFT
    /// @param _potionId ID of the NFT to burn
    function _burnPotion(uint256 _potionId) private {
        potions.transferFrom(msg.sender, address(0xdead), _potionId);
    }

    /// @dev Get one random number that will be shuffled as many times as needed to infect n random doctors
    function _requestRandomWords() private {
        uint256 nextEpochCached = currentEpoch + 1;
        // Extra safety check, but that shouldn't happen
        if (_epochVRFNumber[_epochVRFRequest[nextEpochCached]] != 0) {
            revert VRFAlreadyRequested();
        }

        _epochVRFRequest[nextEpochCached] = _vrfCoordinator.requestRandomWords(_keyHash, _subscriptionId, 3, _maxGas, 1);
    }

    /// @dev Callback function used by VRF Coordinator
    /// @param _requestId Request ID
    /// @param _randomWords Random numbers provided by VRF
    function fulfillRandomWords(uint256 _requestId, uint256[] memory _randomWords) internal override {
        uint256 nextEpochCached = currentEpoch + 1;
        uint256 epochVRFRequestCached = _epochVRFRequest[nextEpochCached];

        if (_requestId != epochVRFRequestCached) {
            revert InvalidRequestId();
        }

        if (_epochVRFNumber[epochVRFRequestCached] != 0) {
            revert VRFAlreadyRequested();
        }

        _epochVRFNumber[_requestId] = _randomWords[0];

        emit RandomWordsFulfilled(nextEpochCached, _requestId);
    }
}
