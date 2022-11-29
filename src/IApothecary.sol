// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./IPlagueGame.sol";
import "./Errors.sol";

interface ILaunchpeg is IERC721Enumerable {
    function devMint(uint256 amount) external;
}

interface IApothecary {
    struct BrewLog {
        uint256 timestamp;
        uint256 doctorID;
        bool brewPotion;
    }

    event PotionClaimed(uint256 indexed doctorID);
    event PotionBrewed(uint256 indexed doctorID);
    event PotionsAdded(uint256 amount);
    event PotionsRemoved(uint256 amount);

    event ClaimStartTimeSet(uint256 timestamp);
    event DifficultySet(uint256[] difficulty);
    event GameAddressSet(address plagueGame);

    // Contract addresses
    function plagueGame() external view returns (IPlagueGame);
    function potions() external view returns (ILaunchpeg);
    function doctors() external view returns (IERC721);

    // Contract settings
    function claimStartTime() external view returns (uint256);
    function getDifficulty(uint256 epoch) external view returns (uint256);
    function AMOUNT_OF_DEAD_DOCTORS_TO_BREW() external view returns (uint256);

    // Contract interractions
    function claimFirstPotions(uint256[] calldata doctorIDs) external;
    function makePotions(uint256[] calldata doctorIDs) external;
    function requestVRFforCurrentEpoch() external;

    // Doctor data
    function hasMintedFirstPotion(uint256 doctorID) external view returns (bool);
    function triedBrewInEpoch(uint256 epoch, uint256 doctorID) external view returns (bool);

    // Logs
    function totalPotionsBrewed() external view returns (uint256);
    function totalBrewsCount() external view returns (uint256);
    function getLatestBrewLogs() external view returns (BrewLog[] memory);
    function getBrewLogs(uint256 doctorId, uint256 count) external view returns (BrewLog[] memory);
    function getTotalBrewsCountForDoctor(uint256 doctorID) external view returns (uint256);

    // Admin
    function setClaimStartTime(uint256 newClaimStartTime) external;
    function setDifficulty(uint256[] calldata difficultyPerEpoch) external;
    function setGameAddress(IPlagueGame newGameAddress) external;
    function addPotions(uint256[] calldata potionIds) external;
    function removePotions(uint256 amount) external;
}
