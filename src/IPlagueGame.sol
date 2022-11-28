// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "openzeppelin/token/ERC721//extensions/IERC721Enumerable.sol";
import "./Errors.sol";

interface IPlagueGame {
    /// @dev Different statuses a doctor can have
    enum Status {
        Dead,
        Healthy,
        Infected
    }

    /// Game events
    event GameStartTimeUpdated(uint256 newStartTime);
    event GameStarted();
    event RandomWordsFulfilled(uint256 indexed epoch, uint256 requestId);
    event DoctorsInfectedThisEpoch(uint256 indexed epoch, uint256 infectedDoctors);
    event EpochEnded(uint256 indexed epoch);
    event GameOver();
    event PrizeWithdrawalAllowed(bool newValue);
    event PrizeWithdrawn(uint256 indexed doctorId, uint256 prize);
    event PrizePotIncreased(uint256 amount);
    event FundsEmergencyWithdraw(uint256 amount);

    /// Doctor event
    event DoctorCured(uint256 indexed doctorId, uint256 indexed epoch);

    function doctors() external view returns (IERC721Enumerable);
    function potions() external view returns (IERC721Enumerable);

    function startTime() external view returns (uint256);
    function playerNumberToEndGame() external view returns (uint256);
    function infectionPercentages(uint256 epoch) external view returns (uint256);
    function cureSuccessRates(uint256 epoch) external view returns (uint256);

    function currentEpoch() external view returns (uint256);
    function epochDuration() external view returns (uint256);
    function epochStartTime() external view returns (uint256);

    function healthyDoctorsNumber() external view returns (uint256);
    function doctorStatus(uint256 doctorId) external view returns (Status);
    function potionUsed(uint256 doctorId) external view returns (uint256);

    function infectedDoctorsPerEpoch(uint256 epoch) external view returns (uint256);
    function curedDoctorsPerEpoch(uint256 epoch) external view returns (uint256);
    function withdrewPrize(uint256 doctorId) external view returns (bool);

    function isGameOver() external view returns (bool);
    function isGameStarted() external view returns (bool);
    function prizePot() external view returns (uint256);
    function prizeWithdrawalAllowed() external view returns (bool);

    function initializeGame(uint256 _amount) external;
    function updateGameStartTime(uint256 _newStartTime) external;
    function allowPrizeWithdraw(bool _status) external;
    function computeInfectedDoctors(uint256 _amount) external;
    function startGame() external;
    function startEpoch() external;
    function endEpoch() external;
    function drinkPotion(uint256 _doctorId, uint256 _potionId) external;
    function withdrawPrize(uint256 _doctorId) external;
    function withdrawFunds() external;
}
