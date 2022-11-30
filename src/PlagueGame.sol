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
    uint256[] public override infectionPercentages;
    /// @dev Potions cure success rates, stored on 2 bytes each. 0xffff (i.e. 65_535) means 100% of success, 0x0000 means 0%
    /// @dev The formula used is: success rate = 1 / (log(potionDrank) ** min(potionDrank / 6, 3.3))
    bytes private constant _cureSuccessRates =
        "\xff\xff\xff\xff\xff\xff\xf4\x3c\xcd\xe7\xac\x30\x8e\xdf\x75\xbd\x60\x73\x4e\x99\x3f\xc2\x33\x82\x29\x75\x21\x42\x1a\x99\x15\x36\x10\xdf\x0d\x63\x0a\x9a\x08\x60\x06\xd9\x06\x7e\x06\x2d\x05\xe4\x05\xa3\x05\x67\x05\x31\x04\xff\x04\xd2\x04\xa8\x04\x81\x04\x5d\x04\x3c\x04\x1d\x03\xff\x03\xe4\x03\xcb\x03\xb2\x03\x9c\x03\x86\x03\x72\x03\x5f\x03\x4d\x03\x3b\x03\x2b\x03\x1b\x03\x0c\x02\xfe\x02\xf0\x02\xe3\x02\xd7\x02\xcb\x02\xbf\x02\xb4\x02\xa9\x02\x9f\x02\x95\x02\x8c\x02\x82\x02\x7a\x02\x71\x02\x69\x02\x61\x02\x59\x02\x52\x02\x4a\x02\x43\x02\x3c\x02\x36\x02\x2f\x02\x29\x02\x23\x02\x1d\x02\x18\x02\x12\x02\x0d\x02\x07\x02\x02\x01\xfd\x01\xf8\x01\xf3\x01\xef\x01\xea\x01\xe6\x01\xe2\x01\xdd\x01\xd9\x01\xd5\x01\xd1\x01\xcd\x01\xca\x01\xc6\x01\xc2\x01\xbf\x01\xbb\x01\xb8\x01\xb5\x01\xb1\x01\xae\x01\xab\x01\xa8\x01\xa5\x01\xa2\x01\x9f\x01\x9c\x01\x99\x01\x97\x01\x94\x01\x91\x01\x8f\x01\x8c\x01\x8a\x01\x87\x01\x85\x01\x82\x01\x80\x01\x7e\x01\x7b\x01\x79\x01\x77\x01\x75\x01\x73\x01\x71\x01\x6f\x01\x6d\x01\x6b\x01\x69\x01\x67\x01\x65\x01\x63\x01\x61\x01\x5f\x01\x5d\x01\x5c\x01\x5a\x01\x58\x01\x56\x01\x55\x01\x53\x01\x51\x01\x50\x01\x4e\x01\x4d\x01\x4b\x01\x4a\x01\x48\x01\x47\x01\x45\x01\x44\x01\x42\x01\x41\x01\x3f\x01\x3e\x01\x3d\x01\x3b\x01\x3a\x01\x39\x01\x37\x01\x36\x01\x35\x01\x33\x01\x32\x01\x31\x01\x30\x01\x2f\x01\x2d\x01\x2c\x01\x2b\x01\x2a\x01\x29\x01\x28\x01\x27\x01\x25\x01\x24\x01\x23\x01\x22\x01\x21\x01\x20\x01\x1f\x01\x1e\x01\x1d\x01\x1c\x01\x1b\x01\x1a\x01\x19\x01\x18\x01\x17\x01\x16\x01\x15\x01\x14\x01\x13\x01\x12\x01\x12\x01\x11\x01\x10\x01\x0f\x01\x0e\x01\x0d\x01\x0c\x01\x0c\x01\x0b\x01\x0a\x01\x09\x01\x08\x01\x07\x01\x07\x01\x06\x01\x05\x01\x04\x01\x03\x01\x03\x01\x02\x01\x01\x01\x00\x01\x00\x00\xff\x00\xfe\x00\xfe\x00\xfd\x00\xfc\x00\xfb\x00\xfb\x00\xfa\x00\xf9\x00\xf9\x00\xf8\x00\xf7\x00\xf7\x00\xf6\x00\xf5\x00\xf5\x00\xf4\x00\xf3\x00\xf3\x00\xf2\x00\xf2\x00\xf1\x00\xf0\x00\xf0\x00\xef\x00\xee\x00\xee\x00\xed\x00\xed\x00\xec\x00\xec\x00\xeb\x00\xea\x00\xea\x00\xe9\x00\xe9\x00\xe8\x00\xe8\x00\xe7\x00\xe6\x00\xe6\x00\xe5\x00\xe5\x00\xe4\x00\xe4\x00\xe3\x00\xe3\x00\xe2\x00\xe2\x00\xe1\x00\xe1\x00\xe0\x00\xe0\x00\xdf\x00\xdf\x00\xde\x00\xde\x00\xdd\x00\xdd\x00\xdc\x00\xdc\x00\xdb\x00\xdb\x00\xda\x00\xda\x00\xda\x00\xd9\x00\xd9\x00\xd8\x00\xd8\x00\xd7\x00\xd7\x00\xd6\x00\xd6\x00\xd6\x00\xd5\x00\xd5\x00\xd4\x00\xd4\x00\xd3\x00\xd3\x00\xd3\x00\xd2\x00\xd2\x00\xd1\x00\xd1\x00\xd1\x00\xd0\x00\xd0\x00\xcf\x00\xcf\x00\xcf\x00\xce\x00\xce\x00\xcd\x00\xcd\x00\xcd\x00\xcc\x00\xcc\x00\xcc\x00\xcb\x00\xcb\x00\xca\x00\xca\x00\xca\x00\xc9\x00\xc9\x00\xc9\x00\xc8\x00\xc8\x00\xc8\x00\xc7\x00\xc7\x00\xc7\x00\xc6\x00\xc6\x00\xc5\x00\xc5\x00\xc5\x00\xc4\x00\xc4\x00\xc4\x00\xc3\x00\xc3\x00\xc3\x00\xc2\x00\xc2\x00\xc2\x00\xc2\x00\xc1\x00\xc1\x00\xc1\x00\xc0\x00\xc0\x00\xc0\x00\xbf\x00\xbf\x00\xbf\x00\xbe\x00\xbe\x00\xbe\x00\xbe\x00\xbd\x00\xbd\x00\xbd\x00\xbc\x00\xbc\x00\xbc\x00\xbb\x00\xbb\x00\xbb\x00\xbb\x00\xba\x00\xba\x00\xba\x00\xb9\x00\xb9\x00\xb9\x00\xb9\x00\xb8\x00\xb8\x00\xb8\x00\xb8\x00\xb7\x00\xb7\x00\xb7\x00\xb6\x00\xb6\x00\xb6\x00\xb6\x00\xb5\x00\xb5\x00\xb5\x00\xb5\x00\xb4\x00\xb4\x00\xb4\x00\xb4\x00\xb3\x00\xb3\x00\xb3\x00\xb3\x00\xb2\x00\xb2\x00\xb2\x00\xb2\x00\xb1\x00\xb1\x00\xb1\x00\xb1\x00\xb0\x00\xb0\x00\xb0\x00\xb0\x00\xaf\x00\xaf\x00\xaf\x00\xaf\x00\xae\x00\xae\x00\xae\x00\xae\x00\xae\x00\xad\x00\xad\x00\xad\x00\xad\x00\xac\x00\xac\x00\xac\x00\xac\x00\xac\x00\xab\x00\xab\x00\xab\x00\xab\x00\xaa\x00\xaa\x00\xaa\x00\xaa\x00\xaa\x00\xa9\x00\xa9\x00\xa9\x00\xa9\x00\xa9\x00\xa8\x00\xa8\x00\xa8\x00\xa8\x00\xa8\x00\xa7\x00\xa7\x00\xa7\x00\xa7\x00\xa6\x00\xa6\x00\xa6\x00\xa6\x00\xa6\x00\xa6\x00\xa5\x00\xa5\x00\xa5\x00\xa5\x00\xa5\x00\xa4\x00\xa4\x00\xa4\x00\xa4\x00\xa4\x00\xa3\x00\xa3\x00\xa3\x00\xa3\x00\xa3\x00\xa2\x00\xa2\x00\xa2\x00\xa2\x00\xa2\x00\xa2\x00\xa1\x00\xa1\x00\xa1\x00\xa1\x00\xa1\x00\xa0\x00\xa0\x00\xa0\x00\xa0\x00\xa0\x00\xa0\x00\x9f\x00\x9f\x00\x9f\x00\x9f\x00\x9f\x00\x9f\x00\x9e\x00\x9e\x00\x9e\x00\x9e\x00\x9e\x00\x9e";
    /// @dev Number of doctors in the collection
    uint256 private immutable _doctorNumber;

    /// @notice Number of healthy doctors
    uint256 public override healthyDoctorsNumber;
    /// @notice Number of potions a doctor already drank
    mapping(uint256 => uint256) public override potionUsed;

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

    enum VRFRequestType {
        Unknown,
        Cure,
        Infection
    }

    /// @dev VRF request type
    mapping(uint256 => VRFRequestType) private _vrfRequestType;
    /// @dev VRF request IDs for each epoch
    mapping(uint256 => uint256) private _epochVRFRequest;
    /// @dev VRF response for each epoch
    mapping(uint256 => uint256) private _epochVRFNumber;
    /// @dev Doctor related to a VRF request
    mapping(uint256 => uint256) private _vrfRequestDoctor;
    /// @dev Blocks VRF requests from a doctor that already has one pending
    mapping(uint256 => bool) private _vrfRequestPending;
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
    /// @dev Basis point in bytes2 to calulate percentages
    uint256 private constant BYTES2_BASIS_POINT = type(uint16).max;

    modifier gameOn() {
        if (isGameOver || !isGameStarted) {
            revert GameIsClosed();
        }
        _;
    }

    /// @dev Constructor
    /// @param _doctors Address of the doctor collection contract
    /// @param _potions Address of the potion collection contract
    /// @param _infectionPercentages Percentage of doctors that will  be infected each epoch
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
        uint256[] memory _infectionPercentages,
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

        for (uint256 i = 0; i < _infectionPercentages.length; i++) {
            if (_infectionPercentages[i] > BASIS_POINT) {
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
        infectionPercentages = _infectionPercentages;
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

        uint256 potionUsedByDoctor = potionUsed[_doctorId]++;

        if (getCureSuccessRate(potionUsedByDoctor) == BYTES2_BASIS_POINT) {
            uint256 currentEpochCached = currentEpoch;
            curedDoctorsPerEpoch[currentEpochCached] += 1;
            _updateDoctorStatusStorage(_doctorId, Status.Healthy);
            _addDoctorToHealthySet(_doctorId);

            emit DoctorCured(_doctorId, currentEpochCached);
        } else {
            if (_vrfRequestPending[_doctorId]) {
                revert VRFAlreadyRequested();
            }

            _vrfRequestPending[_doctorId] = true;

            uint256 requestID = _vrfCoordinator.requestRandomWords(_keyHash, _subscriptionId, 3, _maxGas, 1);
            _vrfRequestDoctor[requestID] = _doctorId;
            _vrfRequestType[requestID] = VRFRequestType.Cure;
        }

        _burnPotion(_potionId);
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

    /// @dev Fetches the right cure success rate for the amount of potion the doctor already drank
    /// If we passed the last defined amount of potions, we use the last used rate
    /// @param _potionsDrank Amount of potion the doctor already drank
    /// @return cureSuccessRate Cure success rate for the considered epoch
    function getCureSuccessRate(uint256 _potionsDrank) public pure returns (uint256 cureSuccessRate) {
        if (_potionsDrank > _cureSuccessRates.length / 2 - 1) {
            _potionsDrank = _cureSuccessRates.length / 2 - 1;
        }

        bytes2 firstByte = bytes2(_cureSuccessRates[_potionsDrank * 2]);
        bytes2 secondByte = bytes2(_cureSuccessRates[_potionsDrank * 2 + 1]);

        cureSuccessRate = uint256(uint16(firstByte | secondByte >> 8));
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

        // Extra safety check, but that shouldn't happen
        if (_epochVRFNumber[_epochVRFRequest[_nextEpoch]] != 0) {
            revert VRFAlreadyRequested();
        }

        uint256 requestID = _vrfCoordinator.requestRandomWords(_keyHash, _subscriptionId, 3, _maxGas, 1);
        _epochVRFRequest[_nextEpoch] = requestID;
        _vrfRequestType[requestID] = VRFRequestType.Infection;
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
        uint256 infectionPercentagesLength = infectionPercentages.length;
        infectionRate = _epoch > infectionPercentagesLength
            ? infectionPercentages[infectionPercentagesLength - 1]
            : infectionPercentages[_epoch - 1];
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

    /// @dev Callback function used by VRF Coordinator
    /// @param _requestId Request ID
    /// @param _randomWords Random numbers provided by VRF
    function fulfillRandomWords(uint256 _requestId, uint256[] memory _randomWords) internal override {
        VRFRequestType requestType = _vrfRequestType[_requestId];

        if (requestType == VRFRequestType.Cure) {
            uint256 doctorID = _vrfRequestDoctor[_requestId];
            uint256 potionDrank = potionUsed[doctorID];
            uint256 successRate = getCureSuccessRate(potionDrank - 1);

            _vrfRequestPending[doctorID] = false;

            if (uint256(keccak256(abi.encode(_randomWords[0]))) % BYTES2_BASIS_POINT < successRate) {
                uint256 epoch = currentEpoch;
                curedDoctorsPerEpoch[epoch] += 1;

                _updateDoctorStatusStorage(doctorID, Status.Healthy);
                _addDoctorToHealthySet(doctorID);

                emit DoctorCured(doctorID, epoch);
            }
        } else if (requestType == VRFRequestType.Infection) {
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
        } else {
            revert VRFUnknownRequest();
        }
    }
}
