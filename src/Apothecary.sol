// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "openzeppelin/access/Ownable.sol";
import "openzeppelin/security/ReentrancyGuard.sol";

import "chainlink/VRFConsumerBaseV2.sol";
import "chainlink/interfaces/VRFCoordinatorV2Interface.sol";

import "./IApothecary.sol";
import "./IPlagueGame.sol";

/// @author Trader Joe
/// @title Apothecary
/// @notice Contract used to distribute potions to doctors
contract Apothecary is IApothecary, Ownable, ReentrancyGuard, VRFConsumerBaseV2 {
    /// @notice Contract address of the plague game
    IPlagueGame public override plagueGame;
    /// @notice Contract address of the potion NFTs
    ILaunchpeg public immutable override potions;
    /// @notice Contract address of the plague doctor NFTs
    IERC721 public immutable override doctors;

    /// @notice Timestamp for Apothecary to allow plague doctors to brew potions
    uint256 public override claimStartTime;
    /// @notice Amount of dead doctors necessary to try to brew a potion
    uint256 public constant override AMOUNT_OF_DEAD_DOCTORS_TO_BREW = 5;
    /// @dev Probability for a doctor to receive a potion when he tries to brew one.
    /// @dev difficulty decreases from 1 (100% probability) to 100,000 (0.001% probability)
    uint256[] private _difficultyPerEpoch;

    /// @notice Used to check if a doctor already minted its first potion
    mapping(uint256 => bool) public override hasMintedFirstPotion;
    /// @notice Keep track if a plague doctor has tried to brew in an epoch
    /// @dev Mapping from the epoch index to plague doctor ID to tried state
    mapping(uint256 => mapping(uint256 => bool)) public override triedBrewInEpoch;

    /// @notice Total number of plague doctors brew attempts
    uint256 public override totalBrewsCount;
    /// @notice Total number of succesful brews
    uint256 public override totalPotionsBrewed;
    /// @dev Ordered brew logs of all plague doctors
    BrewLog[] private _allBrewLogs;
    /// @dev Brew logs of the plague doctors
    mapping(uint256 => BrewLog[]) private _doctorBrewLogs;
    /// @dev Number of latest brew logs to keep track of
    uint256 private constant RECENT_BREW_LOGS_COUNT = 100;

    /// @dev Potions owned by the contract
    uint256[] private _potionsOwnedByContract;

    /// @notice VRF numbers generated for epochs
    mapping(uint256 => uint256) private _epochVRFNumber;
    /// @notice Epoch index to VRF request id
    mapping(uint256 => uint256) private _epochRequestID;
    /// @dev Address of the VRF coordinator
    VRFCoordinatorV2Interface private immutable _vrfCoordinator;
    /// @dev VRF subscription ID
    uint64 private immutable _subscriptionId;
    /// @dev VRF key hash
    bytes32 private immutable _keyHash;
    /// @dev Max gas used on the VRF callback
    uint32 private immutable _maxGas;

    /**
     * Constructor *
     */

    /// @dev constructor
    /// @param _plagueGame Address of the plague game contract
    /// @param _potions Address of the potions contract
    /// @param _doctors Address of the doctors contract
    /// @param _claimStartTime Start time for plague doctors to claim potions
    /// @param difficultyPerEpoch_ Probability for a group of 5 doctors to receive a potion on brew
    /// @param vrfCoordinator_ Address of the VRF coordinator contract
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
        setClaimStartTime(_claimStartTime);
        setDifficulty(difficultyPerEpoch_);
        setGameAddress(_plagueGame);

        potions = _potions;
        doctors = _doctors;

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
    /// @param _doctorIDs Array of doctor IDs
    function claimFirstPotions(uint256[] calldata _doctorIDs) external override nonReentrant {
        if (block.timestamp < claimStartTime) {
            revert ClaimNotStarted();
        }

        uint256 doctorIDsLength = _doctorIDs.length;
        uint256 potionTotalSupply = potions.totalSupply();

        for (uint256 i = 0; i < doctorIDsLength; ++i) {
            uint256 doctorID = _doctorIDs[i];

            if (hasMintedFirstPotion[doctorID]) {
                revert DoctorAlreadyClaimed();
            }

            hasMintedFirstPotion[doctorID] = true;

            potions.devMint(1);
            potions.transferFrom(address(this), doctors.ownerOf(doctorID), potionTotalSupply++);

            emit PotionClaimed(doctorID);
        }
    }

    /// @notice Tries to brew a potion using 5 dead doctors
    /// @dev Can be used with several batches of 5 dead doctors
    /// @param _doctorIDs Array of doctor IDs
    function makePotions(uint256[] calldata _doctorIDs) external override nonReentrant {
        if (!plagueGame.isGameStarted()) {
            revert GameNotStarted();
        }

        if (plagueGame.isGameOver()) {
            revert GameEnded();
        }

        uint256 currentEpoch = plagueGame.currentEpoch();
        uint256 randomNumber = _epochVRFNumber[currentEpoch];
        if (randomNumber == 0) {
            revert VRFResponseMissing();
        }

        uint256 doctorIDsLength = _doctorIDs.length;
        if (doctorIDsLength == 0 || doctorIDsLength % AMOUNT_OF_DEAD_DOCTORS_TO_BREW != 0) {
            revert InvalidDoctorIdsLength();
        }

        // Try brewing for every doctor
        for (uint256 i = 0; i < doctorIDsLength; ++i) {
            if (doctors.ownerOf(_doctorIDs[i]) != msg.sender) {
                revert DoctorNotOwnedBySender();
            }

            if (plagueGame.doctorStatus(_doctorIDs[i]) != IPlagueGame.Status.Dead) {
                revert DoctorNotDead();
            }

            if (triedBrewInEpoch[currentEpoch][_doctorIDs[i]]) {
                revert DoctorAlreadyBrewed();
            }

            _tryBrew(_doctorIDs[i], currentEpoch, randomNumber);
        }

        totalBrewsCount += doctorIDsLength / 5;
    }

    /// @notice Request a random number from VRF for the current epoch
    function requestVRFforCurrentEpoch() external override {
        uint256 currentEpoch = plagueGame.currentEpoch();

        if (_epochRequestID[currentEpoch] != 0) {
            revert VRFAlreadyRequested();
        }

        _epochRequestID[currentEpoch] = _vrfCoordinator.requestRandomWords(_keyHash, _subscriptionId, 3, _maxGas, 1);
    }

    /**
     * View Functions *
     */

    /// @notice Fetches the makePotion() difficulty for the epoch
    /// After reaching the end of the difficulty array, the last value is returned
    /// @param _epoch Epoch
    /// @return difficulty Difficulty for the considered epoch
    function getDifficulty(uint256 _epoch) public view override returns (uint256 difficulty) {
        if (_epoch == 0) {
            return difficulty = 0;
        }

        uint256 difficultyPerEpochLength = _difficultyPerEpoch.length;
        difficulty = _epoch > difficultyPerEpochLength - 1
            ? _difficultyPerEpoch[difficultyPerEpochLength - 1]
            : _difficultyPerEpoch[_epoch - 1];
    }

    /// @notice Returns the total number of brew attempts from a plague doctor
    /// @param _doctorID Token ID of plague doctor
    /// @return doctorBrewsCount Number of brew attempts from plague doctor
    function getTotalBrewsCountForDoctor(uint256 _doctorID) external view override returns (uint256 doctorBrewsCount) {
        doctorBrewsCount = _getTotalBrewsCount(_doctorID);
    }

    /// @notice Returns the latest brew logs
    /// @return lastBrewLogs Latest brew logs
    function getLatestBrewLogs() external view override returns (BrewLog[] memory lastBrewLogs) {
        uint256 allLogsCount = _allBrewLogs.length;
        uint256 length = allLogsCount > RECENT_BREW_LOGS_COUNT ? RECENT_BREW_LOGS_COUNT : allLogsCount;
        lastBrewLogs = new BrewLog[](length);

        for (uint256 i = 0; i < length; ++i) {
            lastBrewLogs[i] = _allBrewLogs[allLogsCount - i - 1];
        }
    }

    /// @notice Returns the [n] brew logs of a plague doctor
    /// @dev Returns [n] number of brew logs if plague doctor has brewed up to [n] times
    /// @param _doctorID Token ID of plague doctor
    /// @param _count Number of latest brew logs to return
    /// @return lastNBrewLogs Last [n] brew logs of plague doctor
    function getBrewLogs(uint256 _doctorID, uint256 _count) external view override returns (BrewLog[] memory) {
        uint256 totalDoctorBrews = _getTotalBrewsCount(_doctorID);
        uint256 checkedLength = _count < totalDoctorBrews ? _count : totalDoctorBrews;
        BrewLog[] memory lastNBrewLogs = new BrewLog[](checkedLength);

        uint256 j = totalDoctorBrews;
        for (uint256 i = checkedLength; i > 0;) {
            unchecked {
                --i;
                --j;
            }

            lastNBrewLogs[i] = _doctorBrewLogs[_doctorID][j];
        }

        return lastNBrewLogs;
    }

    /**
     * Owner Functions
     */

    /// @notice Sets the start timestamp for claiming potions
    /// @dev Start time can only be set in the future
    /// @param _startTime Start timestamp for claiming potions
    function setClaimStartTime(uint256 _startTime) public override onlyOwner {
        if (claimStartTime != 0 && block.timestamp >= claimStartTime) {
            revert ClaimHasStarted();
        }
        if (_startTime < block.timestamp) {
            revert InvalidStartTime();
        }

        claimStartTime = _startTime;

        emit ClaimStartTimeSet(_startTime);
    }

    /// @notice Sets the difficulty of brewing a free potion
    /// @dev Probability is calculated as inverse of difficulty. (1 / difficulty)
    /// @param difficultyPerEpoch_ Difficulty of brewing a free potion
    function setDifficulty(uint256[] memory difficultyPerEpoch_) public override onlyOwner {
        uint256 difficultyPerEpochLength = difficultyPerEpoch_.length;
        for (uint256 i = 1; i < difficultyPerEpochLength; ++i) {
            if (difficultyPerEpoch_[i] < 1 || difficultyPerEpoch_[i] > 100_000) {
                revert InvalidDifficulty();
            }
        }
        _difficultyPerEpoch = difficultyPerEpoch_;

        emit DifficultySet(difficultyPerEpoch_);
    }

    /// @notice Updates the game address
    /// @dev Can only be called before the game start, both the previous contract and the new one are checked
    /// @param _plagueGame New game contract
    function setGameAddress(IPlagueGame _plagueGame) public override onlyOwner {
        // On deployment plagueGame is not set yet so we only check the new contract
        if (_plagueGame.isGameStarted() || (address(plagueGame) != address(0) && plagueGame.isGameStarted())) {
            revert GameAlreadyStarted();
        }

        plagueGame = _plagueGame;

        emit GameAddressSet(address(_plagueGame));
    }

    /// @notice Transfer potions from owner to the Apothecary contract
    /// @dev Potion IDs should be approved before this function is called
    /// @param _potionIDs Potion IDs to be transferred from owner to Apothecary contract
    function addPotions(uint256[] calldata _potionIDs) external override onlyOwner {
        for (uint256 i = 0; i < _potionIDs.length; ++i) {
            potions.transferFrom(msg.sender, address(this), _potionIDs[i]);
            _potionsOwnedByContract.push(_potionIDs[i]);
        }
        emit PotionsAdded(_potionIDs.length);
    }

    /// @notice Transfers potions from the Apothecary contract to the owner
    /// @dev Potion IDs should be owned by the Apothecary contract
    /// @param _amount Number of potions to be transferred from the Apothecary contract to the owner
    function removePotions(uint256 _amount) external override onlyOwner {
        for (uint256 i = 0; i < _amount; ++i) {
            _sendPotion(msg.sender);
        }
        emit PotionsRemoved(_amount);
    }

    /**
     * Private and Internal Functions *
     */

    /// @notice Compute random chance for a plague doctor to win a free potion
    /// @dev doctor is alive and has not brewed in current epoch
    /// @param _doctorID Token ID of the plague doctor
    function _tryBrew(uint256 _doctorID, uint256 _currentEpoch, uint256 _randomNumber) private {
        BrewLog memory brewLog;
        brewLog.doctorID = _doctorID;
        brewLog.timestamp = block.timestamp;

        triedBrewInEpoch[_currentEpoch][_doctorID] = true;

        uint256 randomNumber = uint256(keccak256(abi.encode(_randomNumber, _doctorID)));

        // Difficulty is considered by batches of 5 doctors
        // So we multiply the difficulty by 5 to get the difficulty of a single doctor
        if (randomNumber % (getDifficulty(_currentEpoch) * AMOUNT_OF_DEAD_DOCTORS_TO_BREW) == 0) {
            brewLog.brewPotion = true;
            ++totalPotionsBrewed;

            _sendPotion(doctors.ownerOf(_doctorID));
            emit PotionBrewed(_doctorID);
        } else {
            brewLog.brewPotion = false;
        }

        _doctorBrewLogs[_doctorID].push(brewLog);
        _allBrewLogs.push(brewLog);
    }

    /// @dev Sends a potion to the designated recipient
    /// @param _recipient Address of the recipient
    function _sendPotion(address _recipient) private {
        uint256 potionID = _getPotionID();

        potions.transferFrom(address(this), _recipient, potionID);
        _potionsOwnedByContract.pop();
    }

    /// @notice Returns first token ID of potions owned by Apothecary contract
    /// @dev Reverts if no potions is owned by Apothecary contract
    /// @return potionID First potion ID owned by Apothecary contract
    function _getPotionID() private view returns (uint256 potionID) {
        uint256 potionsOwnedByContractLength = _potionsOwnedByContract.length;

        if (potionsOwnedByContractLength == 0) {
            revert NoPotionLeft();
        }

        potionID = _potionsOwnedByContract[potionsOwnedByContractLength - 1];
    }

    /// @notice Callback by VRFConsumerBaseV2 to pass VRF results
    /// @dev See Chainlink {VRFConsumerBaseV2-fulfillRandomWords}
    /// @param _requestID Request ID
    /// @param _randomWords Random numbers provided by VRF
    function fulfillRandomWords(uint256 _requestID, uint256[] memory _randomWords) internal override {
        uint256 currentEpoch = plagueGame.currentEpoch();

        if (_epochRequestID[currentEpoch] != _requestID) {
            revert InvalidVrfRequestID();
        }

        _epochVRFNumber[currentEpoch] = _randomWords[0];
    }

    /// @notice Returns the total number of brew attempts from a plague doctor
    /// @param _doctorID Token ID of plague doctor
    /// @return doctorBrewsCount Number of brew attempts from plague doctor
    function _getTotalBrewsCount(uint256 _doctorID) private view returns (uint256 doctorBrewsCount) {
        doctorBrewsCount = _doctorBrewLogs[_doctorID].length;
    }
}
