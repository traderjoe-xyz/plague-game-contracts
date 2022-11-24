// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

// Apothecary Errors
error InvalidDifficulty();
error InvalidVrfRequestID();
error InvalidStartTime();
error ClaimHasStarted();
error DoctorAlreadyClaimed();
error ClaimNotStarted();
error InvalidDoctorIdsLength();
error GameEnded();
error DoctorNotOwnedBySender();
error DoctorNotDead();
error DoctorAlreadyBrewed();
error NoPotionLeft();

// Plague Game Errors
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
error CantAddPrizeIfGameIsOver();
error NotAWinner();
error WithdrawalClosed();
error FundsTransferFailed();

// VRF Errors
error VRFResponseMissing();
error VRFAlreadyRequested();
