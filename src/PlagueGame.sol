// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "openzeppelin/access/Ownable.sol";
import "chainlink/VRFConsumerBaseV2.sol";
import "chainlink/interfaces/VRFCoordinatorV2Interface.sol";

import "forge-std/console.sol";

import "./IPlagueGame.sol";

contract PlagueGame is IPlagueGame, Ownable, VRFConsumerBaseV2 {
    /// @notice Address of the doctor collection contract
    IERC721Enumerable public immutable override doctors;
    /// @notice Address of the potion collection contract
    IERC721Enumerable public immutable override potions;
    /// @notice Number of doctors still alive triggering the end of the game
    uint256 public immutable override playerNumberToEndGame;
    /// @notice Percentage of doctors that will be infected each epoch
    uint256[] public override infectionPercentagePerEpoch;
    /// @notice Total number of epochs with a defined infection percentage. If the game lasts longer, the last percentage defined will be used
    uint256 public immutable override totalDefinedEpochNumber;
    /// @dev Number of doctors in the collection
    uint256 private immutable doctorNumber;

    /// @notice Number of healthy doctors
    uint256 public healthyDoctorsNumber;

    /// @notice Current epoch. Epoch is incremented at the beginning of each epoch
    uint256 public override currentEpoch;
    /// @notice Duration of each epoch in seconds
    uint256 public immutable override epochDuration;
    /// @notice Start time of the latest epoch
    uint256 public override epochStartTime;

    /// @notice Stores the number of infected doctors at each epoch. This is purely for the front-end
    mapping(uint256 => uint256) public override infectedDoctorsPerEpoch;
    /// @notice Stores the number of dead doctors at each epoch. This is purely for the front-end
    mapping(uint256 => uint256) public override deadDoctorsPerEpoch;
    /// @notice Stores if a user already claimed his prize for a doctors he owns
    mapping(uint256 => bool) public override withdrewPrize;
    /// @notice VRF request IDs for each epoch
    mapping(uint256 => uint256) private epochVRFRequest;
    /// @notice VRF response for each epoch
    mapping(uint256 => uint256) private epochVRFNumber;
    /// @dev Stores if an epoch has ended
    mapping(uint256 => bool) private epochEnded;

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
    uint256[HEALTHY_DOCTOR_SET_SIZE] private healthyDoctorsSet;
    /// @dev Array containing the status of every doctor
    /// A doctor status is stored in a 2 bits integer.
    // 256 / 2 = 128 doctors per slot
    // 10k / 128 = 78.125 need 79 slots
    uint256 private constant DOCTORS_STATUS_SET_SIZE = 79;
    uint256[DOCTORS_STATUS_SET_SIZE] private doctorsStatusSet;
    /// @dev Used on contract initialization
    uint256 private lastHealthyDoctorsSetItemUpdated;

    /// @dev Address of the VRF coordinator
    VRFCoordinatorV2Interface private immutable vrfCoordinator;
    /// @dev VRF subscription ID
    uint64 private immutable subscriptionId;
    /// @dev VRF key hash
    bytes32 private immutable keyHash;
    /// @dev Max gas used on the VRF callback
    uint32 private immutable maxGas;

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
    /// @param _vrfCoordinator Address of the VRF coordinator
    /// @param _subscriptionId VRF subscription ID
    /// @param _keyHash VRF key hash
    /// @param _maxGas Max gas used on the VRF callback
    constructor(
        IERC721Enumerable _doctors,
        IERC721Enumerable _potions,
        uint256[] memory _infectionPercentagePerEpoch,
        uint256 _playerNumberToEndGame,
        uint256 _epochDuration,
        VRFCoordinatorV2Interface _vrfCoordinator,
        uint64 _subscriptionId,
        bytes32 _keyHash,
        uint32 _maxGas
    ) VRFConsumerBaseV2(address(_vrfCoordinator)) {
        if (_playerNumberToEndGame == 0) {
            revert InvalidPlayerNumberToEndGame();
        }

        if (_epochDuration == 0 || _epochDuration > 7 days) {
            revert InvalidEpochDuration();
        }

        for (uint256 i = 0; i < _infectionPercentagePerEpoch.length; i++) {
            if (_infectionPercentagePerEpoch[i] > BASIS_POINT) {
                revert InvalidInfectionPercentage();
            }
        }

        doctors = _doctors;
        vrfCoordinator = _vrfCoordinator;
        doctorNumber = _doctors.totalSupply();

        if (doctorNumber > 10_000) {
            revert CollectionTooBig();
        }

        playerNumberToEndGame = _playerNumberToEndGame;
        potions = _potions;
        infectionPercentagePerEpoch = _infectionPercentagePerEpoch;
        totalDefinedEpochNumber = _infectionPercentagePerEpoch.length;
        epochDuration = _epochDuration;

        // VRF setup
        subscriptionId = _subscriptionId;
        keyHash = _keyHash;
        maxGas = _maxGas;
    }

    /// @notice Initializes the game
    /// @dev This function is very expensive in gas, that's why it needs to be called several times
    /// @param _amount Amount of healthyDoctorsSet items to initialize
    function initializeGame(uint256 _amount) external override {
        uint256 lastHealthyDoctorsSetItemUpdatedCached = lastHealthyDoctorsSetItemUpdated;
        uint256 newlastHealthyDoctorsSetItemUpdated = lastHealthyDoctorsSetItemUpdatedCached + _amount;

        if (newlastHealthyDoctorsSetItemUpdated > HEALTHY_DOCTOR_SET_SIZE) {
            revert TooManyInitialized();
        }

        // Initialize the doctors status set on first call
        if (lastHealthyDoctorsSetItemUpdatedCached == 0) {
            for (uint256 j = 0; j < 79; ++j) {
                doctorsStatusSet[j] = 0x5555555555555555555555555555555555555555555555555555555555555555;
            }
        }

        for (uint256 j = lastHealthyDoctorsSetItemUpdatedCached; j < newlastHealthyDoctorsSetItemUpdated; j++) {
            uint256 doctorId;
            for (uint256 k = 0; k < 16; ++k) {
                doctorId += (k + 16 * j) << (k * 16);
            }

            healthyDoctorsSet[j] = doctorId;
        }

        lastHealthyDoctorsSetItemUpdated = newlastHealthyDoctorsSetItemUpdated;

        if (newlastHealthyDoctorsSetItemUpdated == HEALTHY_DOCTOR_SET_SIZE) {
            healthyDoctorsNumber = doctorNumber;
        }
    }

    function doctorStatus(uint256 _id) public view returns (Status) {
        uint256 bytesStatus = doctorsStatusSet[_id / 128];
        uint256 shift = (_id % 128) * 2;
        uint256 idDoctorStatus = (bytesStatus >> shift) & 3;

        if (idDoctorStatus == 0) {
            return Status.Dead;
        } else if (idDoctorStatus == 1) {
            return Status.Healthy;
        } else {
            return Status.Infected;
        }
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

    /// @notice Starts the game
    function startGame() external override onlyOwner {
        if (isGameStarted) {
            revert GameAlreadyStarted();
        }

        if (healthyDoctorsNumber < doctorNumber) {
            revert GameNotStarted();
        }

        isGameStarted = true;
        emit GameStarted();

        _requestRandomWords();
    }

    /// @notice Starts a new epoch if the conditions are met
    function startEpoch() external override gameOn {
        ++currentEpoch;

        uint256 randomNumber = epochVRFNumber[epochVRFRequest[currentEpoch]];
        if (randomNumber == 0) {
            revert VRFResponseMissing();
        }

        epochStartTime = block.timestamp;

        uint256 healthyDoctorsNumberCached = healthyDoctorsNumber;
        uint256 currentEpochCached = currentEpoch;

        uint256 toMakeSick = healthyDoctorsNumberCached * _getinfectionRate(currentEpochCached) / BASIS_POINT;

        // Need at least one doctor to be infected, otherwise the game will never end
        if (toMakeSick == 0) {
            toMakeSick = 1;
        }

        // Need at least one doctor left healthy, otherwise the game could end up with no winners
        if (toMakeSick == healthyDoctorsNumberCached) {
            toMakeSick -= 1;
        }

        infectedDoctorsPerEpoch[currentEpoch] = toMakeSick;

        _infectRandomDoctors(healthyDoctorsNumberCached, toMakeSick, randomNumber);

        emit DoctorsInfectedThisEpoch(currentEpochCached, toMakeSick);
    }

    /// @notice Ends the current epoch if the conditions are met
    function endEpoch() external override gameOn {
        uint256 currentEpochCached = currentEpoch;

        if (epochEnded[currentEpochCached] == true) {
            revert EpochAlreadyEnded();
        }

        if (block.timestamp < epochStartTime + epochDuration) {
            revert EpochNotReadyToEnd();
        }

        epochEnded[currentEpochCached] = true;

        uint256 deads;
        for (uint256 i = 0; i < doctorNumber; ++i) {
            if (doctorStatus(i) == Status.Infected) {
                _updateDoctorStatus(i, Status.Dead);
                ++deads;
                emit Dead(i);
            }
        }

        deadDoctorsPerEpoch[currentEpochCached] = deads;
        emit DoctorsDeadThisEpoch(currentEpochCached, deads);

        if (healthyDoctorsNumber <= playerNumberToEndGame) {
            isGameOver = true;
            emit GameOver();
            return;
        }

        _requestRandomWords();
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

        _updateDoctorStatus(_doctorId, Status.Healthy);
        _addDoctorToSet(_doctorId);
        _burnPotion(_potionId);

        emit Cured(_doctorId);
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

    function _updateDoctorStatus(uint256 _id, Status _newStatus) private {
        uint256 bytesStatus = doctorsStatusSet[_id / 128];
        uint256 shift = (_id % 128) * 2;

        bytesStatus &= ~(3 << shift);
        bytesStatus |= uint256(_newStatus) << shift;

        doctorsStatusSet[_id / 128] = bytesStatus;
    }

    function _removeDoctorFromSet(uint256 index) private returns (uint256) {
        // Get the last doctor Id
        uint256 lastDoctorId = _getDoctorIdFromSet(healthyDoctorsNumber - 1);

        // Get the doctor Id at the index
        uint256 bytesDoctorSet = healthyDoctorsSet[index / 16];
        uint256 doctorId = _getDoctorIdFromSet(index);

        // Mask the doctor Id at the index
        uint256 offset = (index % 16) * 16;
        bytesDoctorSet &= ~(0xffff << offset);
        // Replaces it by the last doctor Id of the array
        bytesDoctorSet |= (lastDoctorId << offset);
        healthyDoctorsSet[index / 16] = bytesDoctorSet;

        // Decrement the doctor number
        --healthyDoctorsNumber;

        return doctorId;
    }

    function _addDoctorToSet(uint256 _doctorId) private {
        uint256 bytesDoctorSet = healthyDoctorsSet[healthyDoctorsNumber / 16];
        uint256 offset = (healthyDoctorsNumber % 16) * 16;
        bytesDoctorSet &= ~(0xffff << offset);
        bytesDoctorSet |= (_doctorId << offset);
        healthyDoctorsSet[healthyDoctorsNumber / 16] = bytesDoctorSet;
        ++healthyDoctorsNumber;
    }

    function _getDoctorIdFromSet(uint256 _index) private view returns (uint256) {
        uint256 bytesDoctorSet = healthyDoctorsSet[_index / 16];

        return ((bytesDoctorSet >> (_index % 16) * 16) & 0xFFFF);
    }

    /// @dev Fetches the right infection rate for the current epoch
    /// If we passed the last defined epoch, we use the last used rate
    /// @param _epoch Epoch
    /// @return infectionRate Infection rate for the considered epoch
    function _getinfectionRate(uint256 _epoch) internal view returns (uint256 infectionRate) {
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
    function _infectRandomDoctors(uint256 _healthyDoctorsNumber, uint256 _toMakeSick, uint256 _randomNumber) private {
        uint256 madeSick;
        uint256 doctorId;
        uint256 healthyDoctorId;

        while (madeSick < _toMakeSick) {
            // Shuffles the random number to get a new one
            healthyDoctorId = uint256(keccak256(abi.encode(_randomNumber, madeSick))) % _healthyDoctorsNumber;
            // Removing the doctors from the healthy doctors list and infecting him
            doctorId = _removeDoctorFromSet(healthyDoctorId);
            _updateDoctorStatus(doctorId, Status.Infected);

            --_healthyDoctorsNumber;
            ++madeSick;

            emit Sick(doctorId);
        }
    }

    /// @dev Burns a potion NFT
    /// @param _potionId ID of the NFT to burn
    function _burnPotion(uint256 _potionId) internal {
        potions.transferFrom(msg.sender, address(0xdead), _potionId);
    }

    /// @dev Get one random number that will be shuffled as many times as needed to infect n random doctors
    function _requestRandomWords() private {
        uint256 nextEpochCached = currentEpoch + 1;
        // Extra safety check, but that shouldn't happen
        if (epochVRFNumber[epochVRFRequest[nextEpochCached]] != 0) {
            revert VRFRequestAlreadyAsked();
        }

        epochVRFRequest[nextEpochCached] = vrfCoordinator.requestRandomWords(keyHash, subscriptionId, 3, maxGas, 1);
    }

    /// @dev Callback function used by VRF Coordinator
    /// @param _requestId Request ID
    /// @param _randomWords Random numbers provided by VRF
    function fulfillRandomWords(uint256 _requestId, uint256[] memory _randomWords) internal override {
        uint256 nextEpochCached = currentEpoch + 1;
        uint256 epochVRFRequestCached = epochVRFRequest[nextEpochCached];
        if (_requestId != epochVRFRequestCached) {
            revert InvalidRequestId();
        }

        if (epochVRFNumber[epochVRFRequestCached] != 0) {
            revert VRFRequestAlreadyAsked();
        }

        epochVRFNumber[_requestId] = _randomWords[0];

        emit RandomWordsFulfilled(nextEpochCached, _requestId);
    }
}
