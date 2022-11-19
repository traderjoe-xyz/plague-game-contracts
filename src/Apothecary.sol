// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "openzeppelin/access/Ownable.sol";
import "openzeppelin/token/ERC721/IERC721Receiver.sol";
import "chainlink/VRFConsumerBaseV2.sol";
import "chainlink/interfaces/VRFCoordinatorV2Interface.sol";
import "./IApothecary.sol";
import "./IPlagueGame.sol";

/// @author Trader Joe
/// @title Apothecary
/// @notice Contract for alive plague doctors to attempt to brew a potion at each epoch
contract Apothecary is IApothecary, IERC721Receiver, Ownable, VRFConsumerBaseV2 {
    /// @notice Timestamp for Apothecary to allow plague doctors brew potions
    uint256 private startTime;
    /// @notice Probability for a doctor to receive a potion when he tries to brew one.
    /// @notice difficulty increases from 1 (100% probability) to 100,000 (0.001% probability)
    uint256 private difficulty;
    /// @notice Timestamp of the start of the latest (current) epoch
    uint256 private latestEpochTimestamp;
    /// @notice Duration of each epoch
    uint256 public constant EPOCH_DURATION = 6 hours;
    /// @notice Token ID of the plague doctor that called the VRF for the current epoch
    /// @dev Cache the ID of the plague doctor that called the VRF.
    /// @dev It avoids calling the VRF multiple times
    uint256 public plagueDoctorVRFCaller;

    /// @notice Contract address of plague game
    IPlagueGame public immutable override plagueGame;
    /// @notice Contract address of potions NFT
    IERC721Enumerable public immutable override potions;
    /// @notice Contract address of plague doctors NFT
    IERC721Enumerable public immutable override doctors;

    /// @notice Brew logs of all plague doctors
    BrewLog[] public brewLogs;
    /// @notice Keep track if plague doctor has tried to brew in an epoch
    /// @dev Mapping from an epoch timestamp to plague doctor ID to tried state
    mapping(uint256 => mapping(uint256 => bool)) private triedBrewInEpoch;
    /// @notice VRF numbers generated for epochs
    mapping(uint256 => uint256) private epochVRFNumber;
    /// @notice epoch start timestamp to VRF request id
    mapping(uint256 => uint256) private epochRequestId;

    /// @dev Address of VRF coordinator
    VRFCoordinatorV2Interface private immutable vrfCoordinator;
    /// @dev VRF subscription ID
    uint64 private immutable subscriptionId;
    /// @dev VRF key hash
    bytes32 private immutable keyHash;
    /// @dev Max gas used on the VRF callback
    uint32 private immutable maxGas;
    /// @dev Number of uint256 random values to receive in VRF callback
    uint32 private constant RANDOM_NUMBERS_COUNT = 1;
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
        if (triedBrewInEpoch[_getEpochStart(uint256(block.timestamp))][_doctorId]) {
            revert DoctorHasBrewed(latestEpochTimestamp);
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
    /// @param _vrfCoordinator Address of VRF coordinator contract
    /// @param _subscriptionId VRF subscription ID
    /// @param _keyHash VRF key hash
    /// @param _maxGas Max gas used on the VRF callback
    constructor(
        IPlagueGame _plagueGame,
        IERC721Enumerable _potions,
        IERC721Enumerable _doctors,
        uint256 _difficulty,
        uint256 _startTime,
        VRFCoordinatorV2Interface _vrfCoordinator,
        uint64 _subscriptionId,
        bytes32 _keyHash,
        uint32 _maxGas
    ) VRFConsumerBaseV2(address(_vrfCoordinator)) {
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
        vrfCoordinator = _vrfCoordinator;
        subscriptionId = _subscriptionId;
        keyHash = _keyHash;
        maxGas = _maxGas;
    }

    /**
     * View Functions *
     */

    /// @notice Returns the start timestamp for brewing potions in Apothecary contract
    /// @return brewStartTime Start timestamp for brewing potions
    function getStartTime() external view override returns (uint256 brewStartTime) {
        brewStartTime = startTime;
    }

    /// @notice Returns the total number of brew attempts from all doctors
    /// @return brewsCount Number of brew attempts from all doctors
    function getTotalBrewsCount() external view override returns (uint256 brewsCount) {
        brewsCount = brewLogs.length;
    }

    /// @notice Returns the total number of brew attempts from a plague doctor
    /// @param _doctorId Token ID of plague doctor
    /// @return doctorBrewsCount Number of brew attempts from plague doctor
    function getTotalBrewsCount(uint256 _doctorId) external view override returns (uint256 doctorBrewsCount) {
        doctorBrewsCount = _getTotalBrewsCount(_doctorId);
    }

    /// @notice Returns the [n] latest brew logs
    /// @dev Returns [n] number of brew logs if all brew logs is up to [n]
    /// @param _count Number of latest brew logs to return
    /// @return latestBrewLogs Last [n] brew logs
    function getBrewLogs(uint256 _count) external view override returns (BrewLog[] memory) {
        uint256 checkedLength = _count < brewLogs.length ? _count : brewLogs.length;
        BrewLog[] memory latestBrewLogs = new BrewLog[](checkedLength);

        uint256 j = brewLogs.length;
        for (uint256 i = checkedLength; i > 0;) {
            latestBrewLogs[i - 1] = brewLogs[j - 1];
            unchecked {
                --i;
                --j;
            }
        }

        return latestBrewLogs;
    }

    /// @notice Returns the [n] brew logs of a plague doctor
    /// @dev Returns [n] number of brew logs if plague doctor has brewed up to [n] times
    /// @param _doctorId Token ID of plague doctor
    /// @param _count Number of latest brew logs to return
    /// @return latestBrewLogs Last [n] brew logs of plague doctor
    function getBrewLogs(uint256 _doctorId, uint256 _count) external view override returns (BrewLog[] memory) {
        uint256 totalDoctorBrews = _getTotalBrewsCount(_doctorId);
        uint256 checkedLength = _count < totalDoctorBrews ? _count : totalDoctorBrews;
        BrewLog[] memory latestBrewLogs = new BrewLog[](checkedLength);

        uint256 j = brewLogs.length;
        for (uint256 i = checkedLength; i > 0;) {
            if (brewLogs[j - 1].doctorId == _doctorId) {
                latestBrewLogs[i - 1] = brewLogs[j - 1];
            }
            unchecked {
                --i;
                --j;
            }
        }

        return latestBrewLogs;
    }

    /// @notice Returns time in seconds till start of next epoch
    /// @return countdown Seconds till start of next epoch
    function getTimeToNextEpoch() external view override returns (uint256 countdown) {
        if (latestEpochTimestamp == 0 || block.timestamp - latestEpochTimestamp > EPOCH_DURATION) {
            countdown = 0;
        } else {
            countdown = EPOCH_DURATION + latestEpochTimestamp - uint256(block.timestamp);
        }
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
        epochVRF = epochVRFNumber[_getEpochStart(_epochTimestamp)];
    }

    /// @notice Returns current difficulty of brewing a free potion
    /// @dev Probability is calculated as inverse of difficulty. (1 / difficulty)
    /// @return winDifficulty Difficulty of brewing a free potion
    function getDifficulty() external view override returns (uint256 winDifficulty) {
        winDifficulty = difficulty;
    }

    /// @notice Returns start timestamp of latest epoch
    /// @return latestEpoch Start timestamp of latest epoch
    function getLatestEpochTimestamp() external view override returns (uint256 latestEpoch) {
        latestEpoch = latestEpochTimestamp;
    }

    /// @notice Returns true if plague doctor attempted to brew a potion in an epoch
    /// @notice and false otherwise
    /// @param _epochTimestamp Timestamp of epoch
    /// @param _doctorId Token ID of plague doctor
    /// @return tried Boolean showing plague doctor brew attempt in epoch
    function getTriedInEpoch(uint256 _epochTimestamp, uint256 _doctorId) external view override returns (bool tried) {
        tried = triedBrewInEpoch[_getEpochStart(_epochTimestamp)][_doctorId];
    }

    /**
     * External Functions *
     */

    /// @notice Give random chance to receive a potion at a probability of (1 / difficulty)
    /// @dev Plague doctor must be alive
    /// @dev Plague doctor should have not attempted brew in latest epoch
    /// @param _doctorId Token ID of plague doctor
    function makePotion(uint256 _doctorId)
        external
        override
        brewHasStarted
        doctorIsAlive(_doctorId)
        hasNotBrewedInLatestEpoch(_doctorId)
    {
        if (_getEpochStart(uint256(block.timestamp)) > latestEpochTimestamp) {
            uint256 nextEpochTimestampCache = _getEpochStart(uint256(block.timestamp));
            uint256 pendingRequestId = epochRequestId[nextEpochTimestampCache];

            if (pendingRequestId != 0) {
                revert VrfRequestPending(pendingRequestId);
            }

            plagueDoctorVRFCaller = _doctorId;
            epochRequestId[nextEpochTimestampCache] = vrfCoordinator.requestRandomWords(
                keyHash, subscriptionId, VRF_BLOCK_CONFIRMATIONS, maxGas, RANDOM_NUMBERS_COUNT
            );
        } else {
            _brew(_doctorId);
        }
    }

    /// @notice Function is called when Apothecary contract receives an ERC721 token
    /// @notice via `safeTransferFrom`
    /// @dev See OpenZeppelin {IERC721Receiver-onERC721Received}
    /// @return selector The selector of the function
    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4 selector)
    {
        selector = IERC721Receiver.onERC721Received.selector;
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
    function addPotions(uint256[] memory _potionIds) external override onlyOwner {
        for (uint256 i = 0; i < _potionIds.length;) {
            potions.safeTransferFrom(msg.sender, address(this), _potionIds[i]);

            unchecked {
                ++i;
            }
        }
        emit PotionsAdded(_potionIds);
    }

    /// @notice Transfers potions from Apothecary contract to owner
    /// @dev Potion IDs should be owned by Apothecary contract
    /// @param _potionIds Potion IDs to be transferred from Apothecary contract to owner
    function removePotions(uint256[] memory _potionIds) external override onlyOwner {
        for (uint256 i = 0; i < _potionIds.length;) {
            potions.safeTransferFrom(address(this), msg.sender, _potionIds[i]);

            unchecked {
                ++i;
            }
        }
        emit PotionsRemoved(_potionIds);
    }

    /**
     * Private and Internal Functions *
     */

    /// @notice Callback by VRFConsumerBaseV2 to pass VRF results
    /// @dev See Chainlink {VRFConsumerBaseV2-fulfillRandomWords}
    /// @param _randomWords Random numbers provided by VRF
    function fulfillRandomWords(uint256 _requestId, uint256[] memory _randomWords) internal override {
        latestEpochTimestamp = _getEpochStart(uint256(block.timestamp));

        if (epochRequestId[latestEpochTimestamp] != _requestId) {
            revert InvalidVrfRequestId();
        }

        epochVRFNumber[latestEpochTimestamp] = _randomWords[0];

        _brew(plagueDoctorVRFCaller);
    }

    /// @notice Compute random chance for a plague doctor to win a free potion
    /// @dev Should be called by functions that perform safety checks like plague
    /// @dev doctor is alive and has not brewed in current epoch
    /// @param _doctorId Token ID of plague doctor
    function _brew(uint256 _doctorId) private {
        if (plagueGame.isGameOver()) {
            revert GameIsClosed();
        }

        BrewLog memory brewLog;
        triedBrewInEpoch[latestEpochTimestamp][_doctorId] = true;
        bytes32 hash = keccak256(abi.encodePacked(epochVRFNumber[latestEpochTimestamp], _doctorId));

        if (uint256(hash) % difficulty == 0) {
            if (_getPotionsLeft() == 0) {
                revert PotionsNotEnough(0);
            }

            brewLog.brewPotion = true;
            uint256 potionId = _getPotionId();
            potions.safeTransferFrom(address(this), doctors.ownerOf(_doctorId), potionId);

            emit SentPotion(_doctorId, potionId);
        } else {
            brewLog.brewPotion = false;
        }

        brewLog.doctorId = _doctorId;
        brewLog.timestamp = uint256(block.timestamp);
        brewLogs.push(brewLog);
    }

    /// @notice Returns period start of epoch timestamp
    /// @param _epochTimestamp Timestamp of epoch
    /// @return epochStart Start timestamp of epoch
    function _getEpochStart(uint256 _epochTimestamp) private view returns (uint256 epochStart) {
        if (_epochTimestamp < EPOCH_DURATION) {
            epochStart = _epochTimestamp;
        } else {
            uint256 elapsedEpochs;
            if (_epochTimestamp >= latestEpochTimestamp) {
                elapsedEpochs = (_epochTimestamp - latestEpochTimestamp) / EPOCH_DURATION;
                epochStart = latestEpochTimestamp + (uint256(elapsedEpochs) * EPOCH_DURATION);
            } else {
                elapsedEpochs = (latestEpochTimestamp - _epochTimestamp) / EPOCH_DURATION;
                epochStart = latestEpochTimestamp - (uint256(elapsedEpochs) * EPOCH_DURATION);
            }
        }
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
        potionId = potions.tokenOfOwnerByIndex(address(this), 0);
    }

    /// @notice Returns the total number of brew attempts from a plague doctor
    /// @param _doctorId Token ID of plague doctor
    /// @return doctorBrewsCount Number of brew attempts from plague doctor
    function _getTotalBrewsCount(uint256 _doctorId) private view returns (uint256 doctorBrewsCount) {
        uint256 allBrewLogsCount = brewLogs.length;
        for (uint256 i = 0; i < allBrewLogsCount;) {
            if (brewLogs[i].doctorId == _doctorId) {
                doctorBrewsCount += 1;
            }

            unchecked {
                ++i;
            }
        }
    }
}
