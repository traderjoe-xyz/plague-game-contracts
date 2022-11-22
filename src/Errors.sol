// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

error DoctorIsDead();
error DoctorHasBrewed(uint256 epochTimestamp);
error PotionsNotEnough(uint256 potionsLeft);
error InvalidDifficulty();
error VrfRequestPending(uint256 requestId);
error InvalidVrfRequestId();
error InvalidStartTime();
error BrewNotStarted();
error BrewHasStarted();

error InvalidPlayerNumberToEndGame();
error InvalidInfectionPercentage();
error InvalidEpochDuration();
error TooManyInitialized();
error InvalidCollection();
error GameAlreadyStarted();
error GameNotStarted();
error GameNotOver();
error GameIsClosed();
error InfectionNotComputed();
error NothingToCompute();
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
