// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "openzeppelin/token/ERC721//extensions/IERC721Enumerable.sol";

error InvalidPlayerNumberToEndGame();
error InvalidInfectionPercentage();
error InvalidEpochDuration();
error TooManyInitialized();
error CollectionTooBig();
error GameAlreadyStarted();
error GameNotStarted();
error GameNotOver();
error GameIsClosed();
error EpochNotReadyToEnd();
error EpochAlreadyEnded();
error DoctorNotInfected();
error UpdateToSameStatus();
error InvalidRequestId();
error VRFResponseMissing();
error VRFRequestAlreadyAsked();
error CantAddPrizeIfGameIsOver();
error NotAWinner();
error WithdrawalClosed();
error FundsTransferFailed();

interface IPlagueGame {
    /// @dev Different statuses a doctor can have
    enum Status {
        Dead,
        Healthy,
        Infected
    }

    /// Game events
    event GameStarted();
    event RandomWordsFulfilled(uint256 epoch, uint256 requestId);
    event DoctorsInfectedThisEpoch(uint256 indexed epoch, uint256 infectedDoctors);
    event DoctorsDeadThisEpoch(uint256 indexed epoch, uint256 deadDoctors);
    event GameOver();
    event PrizeWithdrawalAllowed(bool newValue);
    event PrizeWithdrawn(uint256 indexed doctorId, uint256 prize);
    event PrizePotIncreased(uint256 amount);
    event FundsEmergencyWithdraw(uint256 amount);

    /// Individual events
    event Sick(uint256 indexed doctorId);
    event Cured(uint256 indexed doctorId);
    event Dead(uint256 indexed doctorId);

    function doctors() external view returns (IERC721Enumerable);
    function potions() external view returns (IERC721Enumerable);

    function playerNumberToEndGame() external view returns (uint256);
    function infectionPercentagePerEpoch(uint256 epoch) external view returns (uint256);
    function totalDefinedEpochNumber() external view returns (uint256);

    function currentEpoch() external view returns (uint256);
    function epochDuration() external view returns (uint256);
    function epochStartTime() external view returns (uint256);

    function doctorStatus(uint256 doctorId) external view returns (Status);

    function infectedDoctorsPerEpoch(uint256 epoch) external view returns (uint256);
    function deadDoctorsPerEpoch(uint256 epoch) external view returns (uint256);
    function withdrewPrize(uint256 doctorId) external view returns (bool);

    function isGameOver() external view returns (bool);
    function isGameStarted() external view returns (bool);
    function prizePot() external view returns (uint256);
    function prizeWithdrawalAllowed() external view returns (bool);

    function getHealthyDoctorsNumber() external view returns (uint256);
    function initializeGame(uint256 _amount) external;
    function allowPrizeWithdraw(bool _status) external;
    function startGame() external;
    function startEpoch() external;
    function endEpoch() external;
    function drinkPotion(uint256 _doctorId, uint256 _potionId) external;
    function withdrawPrize(uint256 _doctorId) external;
    function withdrawFunds() external;
}
