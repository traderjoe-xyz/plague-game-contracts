// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./IPlagueGame.sol";

error DoctorIsDead();
error DoctorHasBrewed(uint256 epochTimestamp);
error PotionsNotEnough(uint256 potionsLeft);
error InvalidDifficulty();

interface IApothecary {
    event SentPotion(uint256 indexed doctorId, uint256 indexed potionId);

    event PotionsAdded(uint256[] potions);

    event PotionsRemoved(uint256[] potions);

    struct BrewLog {
        uint256 timestamp;
        uint256 doctorId;
        bool brewPotion;
    }

    function plagueGame() external view returns (IPlagueGame);

    function potions() external view returns (IERC721Enumerable);

    function doctors() external view returns (IERC721Enumerable);

    function getTotalBrewsCount() external view returns (uint256 brewsCount);

    function getTotalBrewsCount(uint256 _doctorId) external view returns (uint256 doctorBrewsCount);

    function getBrewLogs(uint256 _count) external view returns (BrewLog[] memory latestBrewLogs);

    function getBrewLogs(uint256 _doctorId, uint256 _count) external view returns (BrewLog[] memory latestBrewLogs);

    function getTimeToNextEpoch() external view returns (uint256 countdown);

    function getPotionsLeft() external view returns (uint256 potionsLeft);

    function getVRFForEpoch(uint256 _epochTimestamp) external view returns (uint256 epochVRF);

    function getDifficulty() external view returns (uint256 winDifficulty);

    function getLatestEpochTimestamp() external view returns (uint256 latestEpoch);

    function getTriedInEpoch(uint256 _epochTimestamp, uint256 _doctorId) external view returns (bool tried);

    function setDifficulty(uint256 _difficulty) external;

    function addPotions(uint256[] memory _potionIds) external;

    function removePotions(uint256[] memory _potionIds) external;

    function makePotion(uint256 _doctorId) external;
}
