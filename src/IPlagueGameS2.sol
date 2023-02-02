// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "openzeppelin/token/ERC721//extensions/IERC721Enumerable.sol";
import "./Errors.sol";

interface IPlagueGameS2 {
    /// @dev Player Character (PC) states
    enum Status {
        Dead,
        NotYetPlayed,
        Played,
        Won
    }
    enum Quest {
        One,
        Two,
        Three,
        Four,
        Five,
        Six,
        Seven
    }

    /// Game events
    event GameStartTimeUpdated(uint256 newStartTime);
    event GameStarted();
    event RandomWordsFulfilled(uint256 indexed epoch, uint256 requestId);
    event EpochEnded(uint256 indexed epoch);
    event GameOver();
    event PrizeWithdrawalAllowed(bool newValue);
    event PrizeWithdrawn(uint256 indexed pcId, uint256 prize);
    event PrizePotIncreased(uint256 amount);
    event FundsEmergencyWithdraw(uint256 amount);

    /// epochs
    function startTime() external view returns (uint256);
    function currentEpoch() external view returns (uint256);
    function epochDuration() external view returns (uint256);
    function epochStartTime() external view returns (uint256);

    /// pc status
    function pcStatus(uint256 pcId) external returns (Status);
    function pcExpiry(uint256 pcId) external returns (uint256);
    function pcQuest(uint256 pcId) external returns (Quest);

    /// game over
    function numWinnersRequired() external view returns (uint256);
    function numWinners() external view returns (uint256);
    function numEmblems() external view returns (uint256[] calldata);
    function alivePCs() external view returns (uint256);
    function isGameOver() external view returns (bool);
    function isGameStarted() external view returns (bool);
    function prizePot() external view returns (uint256);
    function claimPrizeAllowed() external view returns (bool);
    function claimPrize(uint256 pcId) external;
    function hasClaimedPrize(uint256 pcId) external view returns (bool);

    /// admin
    function initializeGame(uint256 amount) external;
    function updateGameStartTime(uint256 newStartTime) external;
    function allowPrizeWithdraw(bool status) external;
    function startGame() external;
    function startEpoch() external;
    function endEpoch() external;
    function withdrawFunds() external;

    /// player
    function doQuest(uint256 pcId) external;
    function rerollQuest(uint256 pcId) external;
}
