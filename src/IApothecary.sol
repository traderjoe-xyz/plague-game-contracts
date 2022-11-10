// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "openzeppelin/token/ERC721/extensions/IERC721Enumerable.sol";
import "./IPlagueGame.sol";

error DoctorIsDead();
error DoctorHasBrewed(uint112 epoch);
error PotionsNotEnough(uint256 potionsLeft);
error InvalidDifficulty();

interface IApothecary {
	event SentPotion(
		uint256 indexed doctorId,
		uint256 indexed potionId
	);

	event PotionsAdded(uint256[] potions);

	event PotionsRemoved(uint256[] potions);

	function plagueGame()
		external
		view
		returns (
			IPlagueGame
		);

	function potions()
		external
		view
		returns (
			IERC721Enumerable
		);

	function getLatestBrews(
		uint256 _doctorId,
		uint256 _count
	)
		external
		view
		returns (
			uint8[] memory latestBrewResults
		);

	function getTimeToNextEpoch()
		external
		view
		returns (
			uint256 countdown
		);

	function getPotionsLeft()
		external
		view
		returns (
			uint256 potionsLeft
		);

	function getVRFForEpoch(
		uint112 _epochTimestamp
	)
		external
		view
		returns (
			uint256 epochVRF
		);

	function getDifficulty()
		external
		view
		returns (
			uint8 winDifficulty
		);

	function getLatestEpochTimestamp()
		external
		view
		returns (
			uint112 latestEpoch
		);

	function getTriedInEpoch(
		uint112 _epochTimestamp,
		uint256 _doctorId
	)
		external
		view
		returns (
			bool tried
		);

	function addPotions(uint256[] memory _potionIds) external;

	function removePotions(uint256[] memory _potionIds) external;

	function openChest(uint256 _doctorId) external;

	function destroy(address payable _recipient) external;
}
