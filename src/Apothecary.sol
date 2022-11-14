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
    /// @notice Probability for a doctor to receive a potion when he tries to brew one.
    /// @notice From 1 (1%) to 100 (100%)
    uint8 private difficulty;
    /// @notice Timestamp of the start of the latest (current) epoch
    uint112 private latestEpochTimestamp;
    /// @notice Duration of each epoch
    uint112 public constant EPOCH_DURATION = 6 hours;
    /// @notice Token ID of the plague doctor that called the VRF for the current epoch
    /// @dev Cache the ID of the plague doctor that called the VRF.
    /// @dev It avoids calling the VRF multiple times
    uint256 public plagueDoctorVRFCaller;

    /// @notice Contract address of plague game
    IPlagueGame public immutable override plagueGame;
    /// @notice Contract address of potions NFT
    IERC721Enumerable public immutable override potions;

    /// @notice Brew logs of all plague doctors
    BrewLog[] public brewLogs;
    /// @notice Keep track if plague doctor has tried to brew in an epoch
    /// @dev Mapping from an epoch timestamp to plague doctor ID to tried state
    mapping(uint112 => mapping(uint256 => bool)) private triedBrewInEpoch;
    /// @notice VRF numbers generated for epochs
    mapping(uint112 => uint256) private epochVRFNumber;

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
        if (triedBrewInEpoch[latestEpochTimestamp][_doctorId]) {
            revert DoctorHasBrewed(latestEpochTimestamp);
        }
        _;
    }

    /**
     * Constructor *
     */

    constructor(
        IPlagueGame _plagueGame,
        IERC721Enumerable _potions,
        uint8 _difficulty,
        VRFCoordinatorV2Interface _vrfCoordinator,
        uint64 _subscriptionId,
        bytes32 _keyHash,
        uint32 _maxGas
    ) VRFConsumerBaseV2(address(_vrfCoordinator)) {
        if (_difficulty == 0) {
            revert InvalidDifficulty();
        }

        plagueGame = _plagueGame;
        potions = _potions;
        difficulty = _difficulty;
        latestEpochTimestamp = uint112(block.timestamp);

        // VRF setup
        vrfCoordinator = _vrfCoordinator;
        subscriptionId = _subscriptionId;
        keyHash = _keyHash;
        maxGas = _maxGas;
    }

    /**
     * View Functions *
     */

    /// @notice Returns the [n] latest brew logs
    /// @dev Returns [n] number of brew logs if all brew logs is up to [n]
    /// @param _count Number of latest brew logs to return
    /// @return latestBrewLogs Last [n] brew logs
    function getBrewLogs(uint256 _count)
        external
        view
        override
        returns (BrewLog[] memory latestBrewLogs)
    {
        uint256 i = brewLogs.length - 1;
        while (i >= 0 || latestBrewLogs.length < _count) {
            latestBrewLogs[latestBrewLogs.length] = (brewLogs[i]);

            unchecked {
                --i;
            }
        }
    }

    /// @notice Returns the [n] brew logs of a plague doctor
    /// @dev Returns [n] number of brew logs if plague doctor has brewed up to [n] times
    /// @param _doctorId Token ID of plague doctor
    /// @param _count Number of latest brew logs to return
    /// @return latestBrewLogs Last [n] brew logs of plague doctor
    function getBrewLogs(uint256 _doctorId, uint256 _count)
        external
        view
        override
        returns (BrewLog[] memory latestBrewLogs)
    {
        uint256 i = brewLogs.length - 1;
        while (i >= 0 || latestBrewLogs.length < _count) {
            if (brewLogs[i].doctorId == _doctorId) {
               latestBrewLogs[latestBrewLogs.length] = (brewLogs[i]);
            }

            unchecked {
                --i;
            }
        }
    }

    /// @notice Returns time in seconds till start of next epoch
    /// @return countdown Seconds till start of next epoch
    function getTimeToNextEpoch() external view override returns (uint256 countdown) {
        countdown = block.timestamp - (block.timestamp % EPOCH_DURATION);
    }

    /// @notice Returns number of potions owned by Apothecary contract
    /// @return potionsLeft Number of potions owned by contract
    function getPotionsLeft() external view override returns (uint256 potionsLeft) {
        potionsLeft = _getPotionsLeft();
    }

    /// @notice Returns random number from VRF for an epoch
    /// @param _epochTimestamp Timestamp of epoch
    /// @return epochVRF Random number from VRF used for epoch results
    function getVRFForEpoch(uint112 _epochTimestamp) external view override returns (uint256 epochVRF) {
        epochVRF = epochVRFNumber[_getEpochStart(_epochTimestamp)];
    }

    /// @notice Returns current difficulty of brewing a free potion
    /// @dev Probability is calculated as inverse of difficulty. (1 / difficulty)
    /// @return winDifficulty Difficulty of brewing a free potion
    function getDifficulty() external view override returns (uint8 winDifficulty) {
        winDifficulty = difficulty;
    }

    /// @notice Returns start timestamp of latest epoch
    /// @return latestEpoch Start timestamp of latest epoch
    function getLatestEpochTimestamp() external view override returns (uint112 latestEpoch) {
        latestEpoch = latestEpochTimestamp;
    }

    /// @notice Returns true if plague doctor attempted to brew a potion in an epoch
    /// @notice and false otherwise
    /// @param _epochTimestamp Timestamp of epoch
    /// @param _doctorId Token ID of plague doctor
    /// @return tried Boolean showing plague doctor brew attempt in epoch
    function getTriedInEpoch(uint112 _epochTimestamp, uint256 _doctorId) external view override returns (bool tried) {
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
        doctorIsAlive(_doctorId)
        hasNotBrewedInLatestEpoch(_doctorId)
    {
        if (latestEpochTimestamp + EPOCH_DURATION < block.timestamp) {
            _brew(_doctorId);
        } else {
            plagueDoctorVRFCaller = _doctorId;
            vrfCoordinator.requestRandomWords(
                keyHash, subscriptionId, VRF_BLOCK_CONFIRMATIONS, maxGas, RANDOM_NUMBERS_COUNT
            );
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

    /// @notice Terminate Apothecary contract. i.e remove it's bytecode from the blockchain
    /// @dev Can only be executed when plague game is over
    /// @param _recipient Address to receive native balance and potion tokens left
    function destroy(address payable _recipient) external override onlyOwner {
        if (!plagueGame.isGameOver()) {
            revert GameNotOver();
        }

        if (_getPotionsLeft() > 0) {
            uint256[] memory _potionIds = _getPotionIds(_getPotionsLeft());
            for (uint256 i = 0; i < _potionIds.length;) {
                potions.safeTransferFrom(address(this), _recipient, _potionIds[i]);

                unchecked {
                    ++i;
                }
            }
        }
        selfdestruct(_recipient);
    }

    /**
     * Private and Internal Functions *
     */

    /// @notice Callback by VRFConsumerBaseV2 to pass VRF results
    /// @dev See Chainlink {VRFConsumerBaseV2-fulfillRandomWords}
    /// @param _randomWords Random numbers provided by VRF
    function fulfillRandomWords(uint256, uint256[] memory _randomWords) internal override {
        uint256 elapsedEpochs = (block.timestamp - latestEpochTimestamp) / EPOCH_DURATION;
        latestEpochTimestamp += uint112(EPOCH_DURATION * elapsedEpochs);
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
                revert PotionsNotEnough(_getPotionsLeft());
            }

            brewLog.brewPotion = true;
            uint256 potionId = _getPotionIds(1)[0];
            potions.safeTransferFrom(address(this), potions.ownerOf(_doctorId), potionId);

            emit SentPotion(_doctorId, potionId);
        } else {
            brewLog.brewPotion = false;
        }

        brewLog.doctorId = _doctorId;
        brewLog.timestamp = uint112(block.timestamp);
        brewLogs.push(brewLog);
    }

    /// @notice Returns period start of epoch timestamp
    /// @param _epochTimestamp Timestamp of epoch
    /// @return epochStart Start timestamp of epoch
    function _getEpochStart(uint112 _epochTimestamp) private pure returns (uint112 epochStart) {
        epochStart = _epochTimestamp - (_epochTimestamp % EPOCH_DURATION);
    }

    /// @notice Returns number of potions owned by Apothecary contract
    /// @return potionsLeft Number of potions owned by contract
    function _getPotionsLeft() private view returns (uint256 potionsLeft) {
        potionsLeft = potions.balanceOf(address(this));
    }

    /// @notice Returns [n] token IDs of potions owned by Apothecary contract
    /// @dev Reverts if [n] is greater than Apothecary contract balance
    /// @param _count Number of token IDs to return
    /// @return potionIds Array of [n] potion IDs owned by contract
    function _getPotionIds(uint256 _count) private view returns (uint256[] memory potionIds) {
        if (_count > _getPotionsLeft()) {
            revert PotionsNotEnough(_getPotionsLeft());
        }

        for (uint256 i = 0; i < _count;) {
            potionIds[i] = potions.tokenOfOwnerByIndex(address(this), i);
            unchecked {
                ++i;
            }
        }
    }
}
