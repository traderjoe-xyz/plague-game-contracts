// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./IPlagueGame.sol";
import "./Errors.sol";

interface ILaunchpeg is IERC721Enumerable {
    function devMint(uint256 amount) external;
}

interface IApothecary {
    event SentPotion(uint256 indexed doctorId);

    event PotionsAdded(uint256[] potions);

    event PotionsRemoved(uint256 amount);

    struct BrewLog {
        uint256 timestamp;
        uint256 doctorId;
        bool brewPotion;
    }

    function plagueGame() external view returns (IPlagueGame);

    function potions() external view returns (ILaunchpeg);

    function doctors() external view returns (IERC721Enumerable);

    function startTime() external view returns (uint256);

    function totalPotionsMinted() external view returns (uint256);

    function totalBrewsCount() external view returns (uint256);

    function getTotalBrewsCount(uint256 _doctorId) external view returns (uint256 doctorBrewsCount);

    function getlatestBrewLogs() external view returns (BrewLog[] memory lastBrewLogs);

    function getBrewLogs(uint256 _doctorId, uint256 _count) external view returns (BrewLog[] memory lastBrewLogs);

    function getTimeToNextEpoch() external view returns (uint256 countdown);

    function getPotionsLeft() external view returns (uint256 potionsLeft);

    function getVRFForEpoch(uint256 _epochTimestamp) external view returns (uint256 epochVRF);

    function difficulty() external view returns (uint256 winDifficulty);

    function triedToBrewPotionDuringEpoch(uint256 _epochTimestamp, uint256 _doctorId)
        external
        view
        returns (bool tried);

    function setStartTime(uint256 _startTime) external;

    function setDifficulty(uint256 _difficulty) external;

    function addPotions(uint256[] calldata _potionIds) external;

    function removePotions(uint256 amount) external;

    function makePotions(uint256[] calldata _doctorIds) external;

    function makePotion(uint256 _doctorId) external;

    function requestVRFforCurrentEpoch() external;
}
