// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "openzeppelin/access/Ownable.sol";
import "chainlink/VRFConsumerBaseV2.sol";
import "chainlink/interfaces/VRFCoordinatorV2Interface.sol";
import "./IApothecary.sol";
import "./IPlagueGame.sol";

/// @author Trader Joe
/// @title Apothecary
/// @notice Contract for alive plague doctors to attempt to brew a potion at each epoch
contract Apothecary is IApothecary, Ownable, VRFConsumerBaseV2 {
    /// @notice Timestamp for Apothecary to allow plague doctors brew potions
    uint256 public startTime;
    /// @notice Probability for a doctor to receive a potion when he tries to brew one.
    /// @notice difficulty increases from 1 (100% probability) to 100,000 (0.001% probability)
    uint256 public difficulty;
    /// @notice Total number of all plague doctors brew attempts
    uint256 public totalBrewsCount;
    /// @notice Total number of succesful brews
    uint256 public totalPotionsMinted;
    /// @notice Duration of each epoch
    uint256 public constant EPOCH_DURATION = 12 hours;
    /// @notice Number of latest brew logs to keep track of
    uint256 public constant RECENT_BREW_LOGS_COUNT = 100;

    /// @notice Contract address of plague game
    IPlagueGame public immutable override plagueGame;
    /// @notice Contract address of potions NFT
    ILaunchpeg public immutable override potions;
    /// @notice Contract address of plague doctors NFT
    IERC721Enumerable public immutable override doctors;

    /// @notice Ordered brew logs of all plague doctors
    BrewLog[] public allBrewLogs;
    /// @notice Track brew logs of plague doctors
    mapping(uint256 => BrewLog[]) private _doctorBrewLogs;

    /// @dev Potions owner by the contract
    uint256[] private _potionsOwnedByContract;

    /// @notice Used to check if a doctor already minted its first potion
    mapping(uint256 => bool) public hasMintedFirstPotion;
    /// @notice Keep track if plague doctor has tried to brew in an epoch
    /// @dev Mapping from an epoch timestamp to plague doctor ID to tried state
    mapping(uint256 => mapping(uint256 => bool)) private _triedBrewInEpoch;
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
    /// @dev Number of uint256 random values to receive in VRF callback
    uint32 private constant RANDOM_NUMBERS_AMOUNT = 1;
    /// @dev Number of blocks confirmations for oracle to respond to VRF request
    uint16 private constant VRF_BLOCK_CONFIRMATIONS = 3;

    /**
     * Modifiers *
     */

    /// @notice Verify that plague doctor is not dead
    /// @param _doctorId Token ID of plague doctor
    modifier doctorIsAlive(uint256 _doctorId) {
        if (plagueGame.doctorStatus(_doctorId) == IPlagueGame.Status.Dead) {
            revert DoctorIsDead();
        }
        _;
    }

    /// @notice Verify that plague doctor has not attempted to brew potion in latest epoch
    /// @param _doctorId Token ID of plague doctor
    modifier hasNotBrewedInLatestEpoch(uint256 _doctorId) {
        uint256 currentEpochTimestampCache = getEpochStart(block.timestamp);
        if (_triedBrewInEpoch[currentEpochTimestampCache][_doctorId]) {
            revert DoctorHasBrewed(currentEpochTimestampCache);
        }
        _;
    }

    /// @notice Verify that brew start time has reached
    modifier brewHasStarted() {
        if (block.timestamp < startTime) {
            revert BrewNotStarted();
        }
        _;
    }

    /**
     * Constructor *
     */

    /// @dev constructor
    /// @param _plagueGame Address of plague game contract
    /// @param _potions Address of potions collection contract
    /// @param _doctors Address of doctors collection contract
    /// @param _difficulty Probability of a doctor to receive a potion on brew
    /// @param _vrfCoordinatorInput Address of VRF coordinator contract
    /// @param _subscriptionIdInput VRF subscription ID
    /// @param _keyHashInput VRF key hash
    /// @param _maxGasInput Max gas used on the VRF callback
    constructor(
        IPlagueGame _plagueGame,
        ILaunchpeg _potions,
        IERC721Enumerable _doctors,
        uint256 _difficulty,
        uint256 _startTime,
        VRFCoordinatorV2Interface _vrfCoordinatorInput,
        uint64 _subscriptionIdInput,
        bytes32 _keyHashInput,
        uint32 _maxGasInput
    ) VRFConsumerBaseV2(address(_vrfCoordinatorInput)) {
        if (_difficulty < 1 || _difficulty > 100_000) {
            revert InvalidDifficulty();
        }

        if (_startTime < block.timestamp) {
            revert InvalidStartTime();
        }

        plagueGame = _plagueGame;
        potions = _potions;
        doctors = _doctors;
        difficulty = _difficulty;
        startTime = _startTime;

        // VRF setup
        _vrfCoordinator = _vrfCoordinatorInput;
        _subscriptionId = _subscriptionIdInput;
        _keyHash = _keyHashInput;
        _maxGas = _maxGasInput;
    }

    /**
     * View Functions *
     */

    /// @notice Returns the total number of brew attempts from a plague doctor
    /// @param _doctorId Token ID of plague doctor
    /// @return doctorBrewsCount Number of brew attempts from plague doctor
    function getTotalBrewsCount(uint256 _doctorId) external view override returns (uint256 doctorBrewsCount) {
        doctorBrewsCount = _getTotalBrewsCount(_doctorId);
    }

    /// @notice Returns the latest brew logs
    /// @return lastBrewLogs Latest brew logs
    function getlatestBrewLogs() external view override returns (BrewLog[] memory lastBrewLogs) {
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
    function getBrewLogs(uint256 _doctorId, uint256 _count) external view override returns (BrewLog[] memory) {
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

    /// @notice Returns time in seconds till start of next epoch
    /// @return countdown Seconds till start of next epoch
    function getTimeToNextEpoch() external view override returns (uint256 countdown) {
        countdown = EPOCH_DURATION + getEpochStart(block.timestamp) - block.timestamp;
    }

    /// @notice Returns number of potions owned by Apothecary contract
    /// @return potionsLeft Number of potions owned by contract
    function getPotionsLeft() external view override returns (uint256 potionsLeft) {
        potionsLeft = _getPotionsLeft();
    }

    /// @notice Returns random number from VRF for an epoch
    /// @param _epochTimestamp Timestamp of epoch
    /// @return epochVRF Random number from VRF used for epoch results
    function getVRFForEpoch(uint256 _epochTimestamp) external view override returns (uint256 epochVRF) {
        epochVRF = _epochVRFNumber[getEpochStart(_epochTimestamp)];
    }

    /// @notice Returns true if plague doctor attempted to brew a potion in an epoch
    /// @notice and false otherwise
    /// @param _epochTimestamp Timestamp of epoch
    /// @param _doctorId Token ID of plague doctor
    /// @return tried Boolean showing plague doctor brew attempt in epoch
    function triedToBrewPotionDuringEpoch(uint256 _epochTimestamp, uint256 _doctorId)
        external
        view
        override
        returns (bool tried)
    {
        tried = _triedBrewInEpoch[getEpochStart(_epochTimestamp)][_doctorId];
    }

    /**
     * External Functions *
     */

    /// @notice Calls _makePotion() for an array of plague doctors
    /// @param _doctorIds Array of doctor token IDs
    function makePotions(uint256[] calldata _doctorIds) external override brewHasStarted {
        if (plagueGame.isGameOver()) {
            revert GameIsClosed();
        }

        for (uint256 i = 0; i < _doctorIds.length; ++i) {
            _makePotion(_doctorIds[i]);
        }
    }

    /// @notice Calls _makePotion() for a single plague doctor
    /// @param _doctorId Token ID of plague doctor
    function makePotion(uint256 _doctorId) external override brewHasStarted {
        if (plagueGame.isGameOver()) {
            revert GameIsClosed();
        }

        _makePotion(_doctorId);
    }

    /// @notice Request a random number from VRF for the current epoch
    function requestVRFforCurrentEpoch() external override brewHasStarted {
        uint256 currentEpochTimestampCache = getEpochStart(block.timestamp);

        if (_epochRequestId[currentEpochTimestampCache] != 0) {
            revert VrfResponsePending();
        }

        _epochRequestId[currentEpochTimestampCache] = _vrfCoordinator.requestRandomWords(
            _keyHash, _subscriptionId, VRF_BLOCK_CONFIRMATIONS, _maxGas, RANDOM_NUMBERS_AMOUNT
        );
    }

    /**
     * Owner Functions *
     */

    /// @notice Sets the start timestamp for brewing potions
    /// @dev Start time can only be set if initial start time has not reached
    /// @param _startTime Start timestamp for brewing potions
    function setStartTime(uint256 _startTime) external override onlyOwner {
        if (block.timestamp >= startTime) {
            revert BrewHasStarted();
        }
        if (_startTime < block.timestamp) {
            revert InvalidStartTime();
        }

        startTime = _startTime;
    }

    /// @notice Sets the difficulty of brewing a free potion
    /// @dev Probability is calculated as inverse of difficulty. (1 / difficulty)
    /// @param _difficulty Difficulty of brewing a free potion
    function setDifficulty(uint256 _difficulty) external override onlyOwner {
        if (_difficulty < 1 || _difficulty > 100_000) {
            revert InvalidDifficulty();
        }
        difficulty = _difficulty;
    }

    /// @notice Transfer potions from owner to Apothecary contract
    /// @dev Potion IDs should be approved before this function is called
    /// @param _potionIds Potion IDs to be transferred from owner to Apothecary contract
    function addPotions(uint256[] calldata _potionIds) external override onlyOwner {
        for (uint256 i = 0; i < _potionIds.length; ++i) {
            potions.transferFrom(msg.sender, address(this), _potionIds[i]);
            _potionsOwnedByContract.push(_potionIds[i]);
        }
        emit PotionsAdded(_potionIds);
    }

    /// @notice Transfers potions from Apothecary contract to owner
    /// @dev Potion IDs should be owned by Apothecary contract
    /// @param _amount Number of potions to be transferred from Apothecary contract to owner
    function removePotions(uint256 _amount) external override onlyOwner {
        for (uint256 i = 0; i < _amount; ++i) {
            _sendPotion(msg.sender);
        }
        emit PotionsRemoved(_amount);
    }

    /**
     * Private and Internal Functions *
     */

    /// @dev Give random chance to receive a potion at a probability of (1 / difficulty)
    /// @dev Plague doctor must be alive
    /// @dev Plague doctor should have not attempted brew in latest epoch
    function _makePotion(uint256 _doctorId) private doctorIsAlive(_doctorId) hasNotBrewedInLatestEpoch(_doctorId) {
        if (hasMintedFirstPotion[_doctorId]) {
            if (_epochVRFNumber[getEpochStart(block.timestamp)] == 0) {
                revert VrfResponseNotReceived();
            }

            _brew(_doctorId);
        } else {
            potions.devMint(1);
            hasMintedFirstPotion[_doctorId] = true;

            potions.transferFrom(address(this), doctors.ownerOf(_doctorId), potions.totalSupply() - 1);
        }
    }

    /// @notice Callback by VRFConsumerBaseV2 to pass VRF results
    /// @dev See Chainlink {VRFConsumerBaseV2-fulfillRandomWords}
    /// @param _randomWords Random numbers provided by VRF
    function fulfillRandomWords(uint256 _requestId, uint256[] memory _randomWords) internal override {
        uint256 currentEpochTimestampCache = getEpochStart(block.timestamp);

        if (_epochRequestId[currentEpochTimestampCache] != _requestId) {
            revert InvalidVrfRequestId();
        }

        _epochVRFNumber[currentEpochTimestampCache] = _randomWords[0];
    }

    /// @notice Compute random chance for a plague doctor to win a free potion
    /// @dev Should be called by functions that perform safety checks like plague
    /// @dev doctor is alive and has not brewed in current epoch
    /// @param _doctorId Token ID of plague doctor
    function _brew(uint256 _doctorId) private {
        uint256 currentEpochTimestampCache = getEpochStart(block.timestamp);
        ++totalBrewsCount;

        BrewLog memory brewLog;
        _triedBrewInEpoch[currentEpochTimestampCache][_doctorId] = true;
        bytes32 hash = keccak256(abi.encodePacked(_epochVRFNumber[currentEpochTimestampCache], _doctorId));

        if (uint256(hash) % difficulty == 0) {
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

        brewLog.doctorId = _doctorId;
        brewLog.timestamp = block.timestamp;
        _doctorBrewLogs[_doctorId].push(brewLog);
        allBrewLogs.push(brewLog);
    }

    /// @dev Sends a potion to the designated recipient
    /// @param _recipient Address of the recipient
    function _sendPotion(address _recipient) private {
        uint256 potionId = _getPotionId();
        potions.safeTransferFrom(address(this), _recipient, potionId);

        _potionsOwnedByContract.pop();
    }

    /// @notice Returns period start of epoch timestamp
    /// @param _epochTimestamp Timestamp of epoch
    /// @return epochStart Start timestamp of epoch
    function getEpochStart(uint256 _epochTimestamp) public view returns (uint256 epochStart) {
        uint256 startTimeCached = startTime;
        epochStart = startTimeCached + ((_epochTimestamp - startTimeCached) / EPOCH_DURATION) * EPOCH_DURATION;
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
            revert PotionsNotEnough(0);
        }
        potionId = _potionsOwnedByContract[_potionsOwnedByContract.length - 1];
    }

    /// @notice Returns the total number of brew attempts from a plague doctor
    /// @param _doctorId Token ID of plague doctor
    /// @return doctorBrewsCount Number of brew attempts from plague doctor
    function _getTotalBrewsCount(uint256 _doctorId) private view returns (uint256 doctorBrewsCount) {
        doctorBrewsCount = _doctorBrewLogs[_doctorId].length;
    }
}
