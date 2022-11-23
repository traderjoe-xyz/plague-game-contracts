// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "openzeppelin/access/Ownable.sol";
import "chainlink/VRFConsumerBaseV2.sol";
import "chainlink/interfaces/VRFCoordinatorV2Interface.sol";
import "./IApothecary.sol";
import "./IPlagueGame.sol";

import "forge-std/console.sol";

/// @author Trader Joe
/// @title Apothecary
/// @notice Contract for alive plague doctors to attempt to brew a potion at each epoch
contract Apothecary is Ownable, VRFConsumerBaseV2 {
    struct BrewLog {
        uint256 timestamp;
        uint256 doctorId;
        bool brewPotion;
    }

    /// @notice Contract address of plague game
    IPlagueGame public immutable plagueGame;
    /// @notice Contract address of potions NFT
    ILaunchpeg public immutable potions;
    /// @notice Contract address of plague doctors NFT
    IERC721 public immutable doctors;

    /// @notice Timestamp for Apothecary to allow plague doctors brew potions
    uint256 public claimStartTime;
    /// @dev Probability for a doctor to receive a potion when he tries to brew one.
    /// @dev difficulty decreases from 1 (100% probability) to 100,000 (0.001% probability)
    uint256[] private _difficultyPerEpoch;
    /// @notice Amount of dead doctors necessary to try to brew a potion
    uint256 public constant AMOUNT_OF_DEAD_DOCTORS_TO_BREW = 5;

    /// @notice Used to check if a doctor already minted its first potion
    mapping(uint256 => bool) public hasMintedFirstPotion;
    /// @notice Keep track if plague doctor has tried to brew in an epoch
    /// @dev Mapping from an epoch timestamp to plague doctor ID to tried state
    mapping(uint256 => mapping(uint256 => bool)) public triedBrewInEpoch;

    /// @notice Total number of all plague doctors brew attempts
    uint256 public totalBrewsCount;
    /// @notice Total number of succesful brews
    uint256 public totalPotionsMinted;
    /// @notice Number of latest brew logs to keep track of
    uint256 public constant RECENT_BREW_LOGS_COUNT = 100;
    /// @notice Ordered brew logs of all plague doctors
    BrewLog[] public allBrewLogs;
    /// @notice Track brew logs of plague doctors
    mapping(uint256 => BrewLog[]) private _doctorBrewLogs;

    /// @dev Potions owner by the contract
    uint256[] private _potionsOwnedByContract;

    /// @notice VRF numbers generated for epochs
    mapping(uint256 => uint256) private _epochVRFNumber;
    /// @notice epoch start timestamp to VRF request id
    mapping(uint256 => uint256) private _epochRequestId;
    /// @dev Address of VRF coordinator
    VRFCoordinatorV2Interface private immutable _vrfCoordinator;
    /// @dev VRF subscription ID
    uint64 private immutable _subscriptionId;
    /// @dev VRF key hash
    bytes32 private immutable _keyHash;
    /// @dev Max gas used on the VRF callback
    uint32 private immutable _maxGas;

    event PotionClaimed(uint256 indexed doctorId);
    event SentPotion(uint256 indexed doctorId);
    event PotionsAdded(uint256[] potions);
    event PotionsRemoved(uint256 amount);

    /**
     * Constructor *
     */

    /// @dev constructor
    /// @param _plagueGame Address of plague game contract
    /// @param _potions Address of potions collection contract
    /// @param _doctors Address of doctors collection contract
    /// @param _claimStartTime Timestamp for Apothecary to allow plague doctors to claim their potion
    /// @param difficultyPerEpoch_ Probability of a doctor to receive a potion on brew
    /// @param vrfCoordinator_ Address of VRF coordinator contract
    /// @param subscriptionId_ VRF subscription ID
    /// @param keyHash_ VRF key hash
    /// @param maxGas_ Max gas used on the VRF callback
    constructor(
        IPlagueGame _plagueGame,
        ILaunchpeg _potions,
        IERC721Enumerable _doctors,
        uint256 _claimStartTime,
        uint256[] memory difficultyPerEpoch_,
        VRFCoordinatorV2Interface vrfCoordinator_,
        uint64 subscriptionId_,
        bytes32 keyHash_,
        uint32 maxGas_
    ) VRFConsumerBaseV2(address(vrfCoordinator_)) {
        if (_claimStartTime < block.timestamp) {
            revert InvalidStartTime();
        }

        /// There will be no dead doctors in epoch 1, so we don't need to check for that
        uint256 difficultyPerEpochLength = difficultyPerEpoch_.length;
        for (uint256 i = 1; i < difficultyPerEpochLength; i++) {
            if (difficultyPerEpoch_[i] < 1 || difficultyPerEpoch_[i] > 100_000) {
                revert InvalidDifficulty();
            }
        }

        plagueGame = _plagueGame;
        potions = _potions;
        doctors = _doctors;
        claimStartTime = _claimStartTime;
        _difficultyPerEpoch = difficultyPerEpoch_;

        // VRF setup
        _vrfCoordinator = vrfCoordinator_;
        _subscriptionId = subscriptionId_;
        _keyHash = keyHash_;
        _maxGas = maxGas_;
    }

    /**
     * External Functions *
     */

    /// @notice Claims the intial potion for an array of doctors
    /// @param _doctorIds Array of doctor IDs
    function claimPotions(uint256[] calldata _doctorIds) external {
        if (block.timestamp < claimStartTime) {
            revert ClaimNotStarted();
        }

        uint256 doctorIdsLength = _doctorIds.length;

        for (uint256 i = 0; i < doctorIdsLength; ++i) {
            uint256 doctorId = _doctorIds[i];

            if (hasMintedFirstPotion[doctorId]) {
                revert DoctorAlreadyClaimed();
            }

            hasMintedFirstPotion[doctorId] = true;

            potions.devMint(1);
            potions.transferFrom(address(this), doctors.ownerOf(doctorId), potions.totalSupply() - 1);

            emit PotionClaimed(doctorId);
        }
    }

    /// @notice Tries to brew a potion using 5 dead doctors
    /// @dev Can be used with several batches of 5 dead doctors
    /// @param _doctorIds Array of doctor token IDs
    function makePotions(uint256[] calldata _doctorIds) external {
        if (!plagueGame.isGameStarted()) {
            revert GameNotStarted();
        }

        if (plagueGame.isGameOver()) {
            revert GameEnded();
        }

        uint256 currentEpoch = plagueGame.currentEpoch();
        uint256 randomNumber = _epochVRFNumber[currentEpoch];
        if (randomNumber == 0) {
            revert VrfResponseNotReceived();
        }

        uint256 doctorIdsLength = _doctorIds.length;
        if (doctorIdsLength == 0 || doctorIdsLength % AMOUNT_OF_DEAD_DOCTORS_TO_BREW != 0) {
            revert InvalidDoctorIdsLength();
        }

        // Try brewing for every doctor
        for (uint256 i = 0; i < doctorIdsLength; ++i) {
            if (doctors.ownerOf(_doctorIds[i]) != msg.sender) {
                revert DoctorNotOwnedBySender();
            }

            if (plagueGame.doctorStatus(_doctorIds[i]) != IPlagueGame.Status.Dead) {
                revert DoctorNotDead();
            }

            if (triedBrewInEpoch[currentEpoch][_doctorIds[i]]) {
                revert DoctorAlreadyBrewed();
            }

            _tryBrew(_doctorIds[i], currentEpoch, randomNumber);
        }
    }

    /**
     * Private and Internal Functions *
     */

    /// @notice Compute random chance for a plague doctor to win a free potion
    /// @dev Should be called by functions that perform safety checks like plague
    /// @dev doctor is alive and has not brewed in current epoch
    /// @param _doctorId Token ID of plague doctor
    function _tryBrew(uint256 _doctorId, uint256 _currentEpoch, uint256 _randomNumber) private {
        BrewLog memory brewLog;
        brewLog.doctorId = _doctorId;
        brewLog.timestamp = block.timestamp;

        ++totalBrewsCount;
        triedBrewInEpoch[_currentEpoch][_doctorId] = true;

        uint256 randomNumber = uint256(keccak256(abi.encode(_randomNumber, _doctorId)));

        // Difficulty is considered by batches of 5 doctors
        // So we multiply the difficulty by 5 to get the difficulty of a single doctor
        if (randomNumber % (getDifficulty(_currentEpoch) * AMOUNT_OF_DEAD_DOCTORS_TO_BREW) == 0) {
            if (_getPotionsLeft() == 0) {
                revert PotionsNotEnough(0);
            }

            brewLog.brewPotion = true;
            ++totalPotionsMinted;

            _sendPotion(doctors.ownerOf(_doctorId));
            emit SentPotion(_doctorId);
        } else {
            brewLog.brewPotion = false;
        }

        _doctorBrewLogs[_doctorId].push(brewLog);
        allBrewLogs.push(brewLog);
    }

    /// @notice Callback by VRFConsumerBaseV2 to pass VRF results
    /// @dev See Chainlink {VRFConsumerBaseV2-fulfillRandomWords}
    /// @param _randomWords Random numbers provided by VRF
    function fulfillRandomWords(uint256 _requestId, uint256[] memory _randomWords) internal override {
        uint256 currentEpoch = plagueGame.currentEpoch();

        if (_epochRequestId[currentEpoch] != _requestId) {
            revert InvalidVrfRequestId();
        }

        _epochVRFNumber[currentEpoch] = _randomWords[0];
    }

    /// @dev Sends a potion to the designated recipient
    /// @param _recipient Address of the recipient
    function _sendPotion(address _recipient) private {
        uint256 potionId = _getPotionId();
        potions.transferFrom(address(this), _recipient, potionId);

        _potionsOwnedByContract.pop();
    }

    /// @notice Returns number of potions owned by Apothecary contract
    /// @return potionsLeft Number of potions owned by contract
    function _getPotionsLeft() private view returns (uint256 potionsLeft) {
        potionsLeft = potions.balanceOf(address(this));
    }

    /// @notice Returns first token ID of potions owned by Apothecary contract
    /// @dev Reverts if no potions is owned by Apothecary contract
    /// @return potionId First potion ID owned by Apothecary contract
    function _getPotionId() private view returns (uint256 potionId) {
        if (_getPotionsLeft() == 0) {
            revert NoPotionLeft();
        }
        potionId = _potionsOwnedByContract[_potionsOwnedByContract.length - 1];
    }

    /// @notice Returns the total number of brew attempts from a plague doctor
    /// @param _doctorId Token ID of plague doctor
    /// @return doctorBrewsCount Number of brew attempts from plague doctor
    function _getTotalBrewsCount(uint256 _doctorId) private view returns (uint256 doctorBrewsCount) {
        doctorBrewsCount = _doctorBrewLogs[_doctorId].length;
    }

    /// @notice Fetches the right infection rate for the current epoch
    /// If we passed the last defined epoch, we use the last used rate
    /// @param _epoch Epoch
    /// @return difficulty Infection rate for the considered epoch
    function getDifficulty(uint256 _epoch) public view returns (uint256 difficulty) {
        if (_epoch == 0) {
            return difficulty = 0;
        }

        uint256 difficultyPerEpochLength = _difficultyPerEpoch.length;
        difficulty = _epoch > difficultyPerEpochLength - 1
            ? _difficultyPerEpoch[difficultyPerEpochLength - 1]
            : _difficultyPerEpoch[_epoch - 1];
    }

    /// @notice Request a random number from VRF for the current epoch
    function requestVRFforCurrentEpoch() external {
        uint256 currentEpoch = plagueGame.currentEpoch();

        if (_epochRequestId[currentEpoch] != 0) {
            revert VrfResponsePending();
        }

        _epochRequestId[currentEpoch] = _vrfCoordinator.requestRandomWords(_keyHash, _subscriptionId, 3, _maxGas, 1);
    }

    /**
     * Owner Functions *
     */

    /// @notice Sets the start timestamp for brewing potions
    /// @dev Start time can only be set if initial start time has not reached
    /// @param _startTime Start timestamp for brewing potions
    function setClaimStartTime(uint256 _startTime) external onlyOwner {
        if (block.timestamp >= claimStartTime) {
            revert BrewHasStarted();
        }
        if (_startTime < block.timestamp) {
            revert InvalidStartTime();
        }

        claimStartTime = _startTime;
    }

    /// @notice Sets the difficulty of brewing a free potion
    /// @dev Probability is calculated as inverse of difficulty. (1 / difficulty)
    /// @param difficultyPerEpoch_ Difficulty of brewing a free potion
    function setDifficulty(uint256[] calldata difficultyPerEpoch_) external onlyOwner {
        uint256 difficultyPerEpochLength = difficultyPerEpoch_.length;
        for (uint256 i = 1; i < difficultyPerEpochLength; ++i) {
            if (difficultyPerEpoch_[i] < 1 || difficultyPerEpoch_[i] > 100_000) {
                revert InvalidDifficulty();
            }
        }
        _difficultyPerEpoch = difficultyPerEpoch_;
    }

    /// @notice Transfer potions from owner to Apothecary contract
    /// @dev Potion IDs should be approved before this function is called
    /// @param _potionIds Potion IDs to be transferred from owner to Apothecary contract
    function addPotions(uint256[] calldata _potionIds) external onlyOwner {
        for (uint256 i = 0; i < _potionIds.length; ++i) {
            potions.transferFrom(msg.sender, address(this), _potionIds[i]);
            _potionsOwnedByContract.push(_potionIds[i]);
        }
        emit PotionsAdded(_potionIds);
    }

    /// @notice Transfers potions from Apothecary contract to owner
    /// @dev Potion IDs should be owned by Apothecary contract
    /// @param _amount Number of potions to be transferred from Apothecary contract to owner
    function removePotions(uint256 _amount) external onlyOwner {
        for (uint256 i = 0; i < _amount; ++i) {
            _sendPotion(msg.sender);
        }
        emit PotionsRemoved(_amount);
    }

    /**
     * View Functions *
     */

    /// @notice Returns the total number of brew attempts from a plague doctor
    /// @param _doctorId Token ID of plague doctor
    /// @return doctorBrewsCount Number of brew attempts from plague doctor
    function getTotalBrewsCount(uint256 _doctorId) external view returns (uint256 doctorBrewsCount) {
        doctorBrewsCount = _getTotalBrewsCount(_doctorId);
    }

    /// @notice Returns the latest brew logs
    /// @return lastBrewLogs Latest brew logs
    function getlatestBrewLogs() external view returns (BrewLog[] memory lastBrewLogs) {
        uint256 allLogsCount = allBrewLogs.length;
        uint256 length = allLogsCount > RECENT_BREW_LOGS_COUNT ? RECENT_BREW_LOGS_COUNT : allLogsCount;
        lastBrewLogs = new BrewLog[](length);

        for (uint256 i = 0; i < length; ++i) {
            lastBrewLogs[i] = allBrewLogs[allLogsCount - i - 1];
        }
    }

    /// @notice Returns the [n] brew logs of a plague doctor
    /// @dev Returns [n] number of brew logs if plague doctor has brewed up to [n] times
    /// @param _doctorId Token ID of plague doctor
    /// @param _count Number of latest brew logs to return
    /// @return lastNBrewLogs Last [n] brew logs of plague doctor
    function getBrewLogs(uint256 _doctorId, uint256 _count) external view returns (BrewLog[] memory) {
        uint256 totalDoctorBrews = _getTotalBrewsCount(_doctorId);
        uint256 checkedLength = _count < totalDoctorBrews ? _count : totalDoctorBrews;
        BrewLog[] memory lastNBrewLogs = new BrewLog[](checkedLength);

        uint256 j = totalDoctorBrews;
        for (uint256 i = checkedLength; i > 0;) {
            unchecked {
                --i;
                --j;
            }

            lastNBrewLogs[i] = _doctorBrewLogs[_doctorId][j];
        }

        return lastNBrewLogs;
    }
}
