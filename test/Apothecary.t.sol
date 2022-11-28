// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "src/IPlagueGame.sol";

import "forge-std/Test.sol";
import "src/Apothecary.sol";
import "src/PlagueGame.sol";
import "./mocks/ERC721.sol";
import "./PlagueGameTest.sol";
import "chainlink/mocks/VRFCoordinatorV2Mock.sol";
import "chainlink/interfaces/VRFCoordinatorV2Interface.sol";

contract ApothecaryTest is PlagueGameTest {
    Apothecary apothecary;

    // // Apothecary config
    uint256 claimStartTime = block.timestamp + 12 hours;
    uint256[] difficultyPerEpoch = [0, 50, 50, 58, 58, 67, 67, 100, 100, 134, 134, 200, 200, 400, 400];

    uint256[] potionIds;
    uint256[] doctorIds;

    function setUp() public override {
        super.setUp();

        apothecary = new Apothecary(
            plagueGame,
            ILaunchpeg(address(potions)),
            IERC721Enumerable(doctors),
            claimStartTime,
            difficultyPerEpoch,
            VRFCoordinatorV2Interface(coordinator),
            subscriptionId,
            keyHash,
            maxGas
        );
        coordinator.addConsumer(subscriptionId, address(apothecary));

        potions.setApprovalForAll(address(apothecary), true);
        _addPotions(200);

        vm.prank(ALICE);
        potions.mint(10);
    }

    function testClaimPotion() public {
        uint256 initialTotalSupply = potions.totalSupply();
        uint256 initialBalance = potions.balanceOf(doctors.ownerOf(0));

        // Claiming for 5 doctors
        doctorIds = [0, 1, 2, 3, 4];

        // Shouldn't be possible before the claim start time
        vm.expectRevert(ClaimNotStarted.selector);
        apothecary.claimFirstPotions(doctorIds);

        vm.warp(claimStartTime);
        apothecary.claimFirstPotions(doctorIds);

        // Shouldn't be possible to claim twice
        doctorIds = [4, 5, 6];
        vm.expectRevert(DoctorAlreadyClaimed.selector);
        apothecary.claimFirstPotions(doctorIds);

        doctorIds = [5, 6];
        apothecary.claimFirstPotions(doctorIds);

        for (uint256 i = 0; i < 7; i++) {
            assertEq(apothecary.hasMintedFirstPotion(i), true, "Doctor should have minted their first potion");
        }

        assertEq(potions.totalSupply(), initialTotalSupply + 7, "Total supply should be 7 more");
        assertEq(potions.balanceOf(doctors.ownerOf(0)), initialBalance + 7, "Balance should be 7 more");
    }

    function testMakePotion() public prepareForPotions {
        // Claiming for 5 doctors
        doctorIds = [0, 1, 2, 3, 4];

        apothecary.requestVRFforCurrentEpoch();

        // Can't try if the VRF response hasn't been received
        vm.expectRevert(VRFResponseMissing.selector);
        apothecary.makePotions(doctorIds);

        _mockVRFResponse(address(apothecary));

        // Can't try if the doctors are not dead
        vm.expectRevert(DoctorNotDead.selector);
        apothecary.makePotions(doctorIds);

        _forceDoctorStatuses(doctorIds, IPlagueGame.Status.Dead);

        // Can't try if the doctors are not yours
        vm.prank(BOB);
        vm.expectRevert(DoctorNotOwnedBySender.selector);
        apothecary.makePotions(doctorIds);

        doctorIds = [0, 0, 2, 3, 4];
        // Can't claim several times with the same doctor
        vm.expectRevert(DoctorAlreadyBrewed.selector);
        apothecary.makePotions(doctorIds);

        doctorIds = [0, 1, 2, 3, 4];

        apothecary.makePotions(doctorIds);

        // Can't try if the doctors have already brewed
        vm.expectRevert(DoctorAlreadyBrewed.selector);
        apothecary.makePotions(doctorIds);

        // Should be possible to make potions for the same doctors in the next epoch
        _skipGameEpoch();

        apothecary.requestVRFforCurrentEpoch();
        _mockVRFResponse(address(apothecary));

        apothecary.makePotions(doctorIds);
    }

    function testSuccesfullMakePotion() public prepareForPotions {
        // Claiming for 5 doctors
        doctorIds = [0, 1, 2, 3, 4];

        _forceDoctorStatuses(doctorIds, IPlagueGame.Status.Dead);
        apothecary.requestVRFforCurrentEpoch();

        uint256 currentDifficulty = apothecary.getDifficulty(plagueGame.currentEpoch());
        uint256 randomNumber;

        while (uint256(keccak256(abi.encode(randomNumber, doctorIds[0]))) % (currentDifficulty * 5) != 0) {
            ++randomNumber;
        }

        uint256[] memory words = new uint256[](1);
        words[0] = randomNumber;
        coordinator.fulfillRandomWordsWithOverride(s_nextRequestId++, address(apothecary), words);

        uint256 balanceBefore = potions.balanceOf(doctors.ownerOf(doctorIds[0]));
        apothecary.makePotions(doctorIds);

        assertEq(
            potions.balanceOf(doctors.ownerOf(doctorIds[0])), balanceBefore + 1, "User should have received a potion"
        );

        _skipGameEpoch();
        apothecary.requestVRFforCurrentEpoch();

        // Someone can get some extra lucky and receive 2 potions
        currentDifficulty = apothecary.getDifficulty(plagueGame.currentEpoch());
        while (
            uint256(keccak256(abi.encode(randomNumber, doctorIds[0]))) % (currentDifficulty * 5) != 0
                || uint256(keccak256(abi.encode(randomNumber, doctorIds[1]))) % (currentDifficulty * 5) != 0
        ) {
            ++randomNumber;
        }

        words[0] = randomNumber;
        coordinator.fulfillRandomWordsWithOverride(s_nextRequestId++, address(apothecary), words);

        balanceBefore = potions.balanceOf(doctors.ownerOf(doctorIds[0]));
        apothecary.makePotions(doctorIds);

        assertEq(
            potions.balanceOf(doctors.ownerOf(doctorIds[0])), balanceBefore + 2, "User should have received two potions"
        );
    }

    function testStartTime() public {
        assertEq(
            apothecary.claimStartTime(), claimStartTime, "Start time should be equal to timestamp set at deployment"
        );

        vm.prank(BOB);
        // Can't be called by anyone else than the owner
        vm.expectRevert("Ownable: caller is not the owner");
        apothecary.setClaimStartTime(claimStartTime + 1 days);

        apothecary.setClaimStartTime(claimStartTime + 1 days);
        assertEq(apothecary.claimStartTime(), claimStartTime + 1 days, "Start time should be udpated");

        // Can't set a start time in the past
        vm.expectRevert(InvalidStartTime.selector);
        apothecary.setClaimStartTime(block.timestamp - 1);

        vm.warp(apothecary.claimStartTime() + 1);

        // Can't update if the claim has already started
        vm.expectRevert(ClaimHasStarted.selector);
        apothecary.setClaimStartTime(block.timestamp + 1 days);
    }

    function testDifficulty() public prepareForPotions {
        for (uint256 i = 0; i < difficultyPerEpoch.length; i++) {
            assertEq(
                apothecary.getDifficulty(i + 1), difficultyPerEpoch[i], "Difficulty should be equal to the one set"
            );
        }

        difficultyPerEpoch[4] = 100;

        vm.prank(BOB);
        // Can't be called by anyone else than the owner
        vm.expectRevert("Ownable: caller is not the owner");
        apothecary.setDifficulty(difficultyPerEpoch);

        apothecary.setDifficulty(difficultyPerEpoch);
        assertEq(apothecary.getDifficulty(5), difficultyPerEpoch[4], "Difficulty should be correctly updated");

        difficultyPerEpoch[4] = 0;
        // Can't set a difficulty of 0
        vm.expectRevert(InvalidDifficulty.selector);
        apothecary.setDifficulty(difficultyPerEpoch);

        difficultyPerEpoch[4] = 1_000_000;
        // Can't set a too high difficulty
        vm.expectRevert(InvalidDifficulty.selector);
        apothecary.setDifficulty(difficultyPerEpoch);

        assertEq(
            apothecary.getDifficulty(difficultyPerEpoch.length + 99),
            apothecary.getDifficulty(difficultyPerEpoch.length),
            "Difficulty should be the same for epochs after the last one"
        );

        difficultyPerEpoch = [50, 50];
        apothecary.setDifficulty(difficultyPerEpoch);

        assertEq(
            apothecary.getDifficulty(difficultyPerEpoch.length + 99),
            apothecary.getDifficulty(difficultyPerEpoch.length),
            "Difficulty should be the same for epochs after the last one"
        );

        doctorIds = [0, 1, 2, 3, 4];

        _forceDoctorStatuses(doctorIds, IPlagueGame.Status.Dead);
        apothecary.requestVRFforCurrentEpoch();
        _mockVRFResponse(address(apothecary));

        apothecary.makePotions(doctorIds);

        difficultyPerEpoch = [50, 50, 50, 50, 50, 35];
        apothecary.setDifficulty(difficultyPerEpoch);

        doctorIds = [5, 6, 7, 8, 9];
        _forceDoctorStatuses(doctorIds, IPlagueGame.Status.Dead);
        apothecary.makePotions(doctorIds);
    }

    function testAddRemovePotions() public {
        potionIds = [potions.totalSupply(), potions.totalSupply() + 1];
        potions.mint(2);

        uint256 apothecaryInitialBalance = potions.balanceOf(address(apothecary));
        uint256 adminInitialBalance = potions.balanceOf(address(this));

        apothecary.addPotions(potionIds);

        assertEq(
            potions.balanceOf(address(this)),
            adminInitialBalance - potionIds.length,
            "Potions balance of ADMIN should reduce by one"
        );
        assertEq(
            potions.balanceOf(address(apothecary)),
            apothecaryInitialBalance + potionIds.length,
            "Potions balance of APOTHECARY should increase by one"
        );
        assertEq(potions.ownerOf(potionIds[0]), address(apothecary), "APOTHECARY should be the owner of the potion ID");
        assertEq(potions.ownerOf(potionIds[1]), address(apothecary), "APOTHECARY should be the owner of the potion ID");

        apothecary.removePotions(1);

        assertEq(
            potions.balanceOf(address(this)),
            adminInitialBalance - potionIds.length + 1,
            "Potions balance of ADMIN should increase by one"
        );
        assertEq(
            potions.balanceOf(address(apothecary)),
            apothecaryInitialBalance + potionIds.length - 1,
            "Potions balance of APOTHECARY should reduce by one"
        );
        assertEq(potions.ownerOf(potionIds[0]), address(apothecary), "APOTHECARY should be the owner of the potion ID");
        assertEq(potions.ownerOf(potionIds[1]), address(this), "ADMIN should be the owner of the potion ID");
    }

    /**
     * Helper Functions *
     */

    modifier prepareForPotions() {
        _initializeGame();
        plagueGame.startGame();
        _mockVRFResponse(address(plagueGame));
        plagueGame.computeInfectedDoctors(collectionSize);
        plagueGame.startEpoch();

        _skipGameEpoch();
        _;
    }

    function _skipGameEpoch() private {
        skip(epochDuration);
        plagueGame.endEpoch();
        _mockVRFResponse(address(plagueGame));
        plagueGame.computeInfectedDoctors(collectionSize);
        plagueGame.startEpoch();
    }

    function _mockVRFResponse(address _consumer) private {
        coordinator.fulfillRandomWords(s_nextRequestId++, _consumer);
        _checkVRFCost();
    }

    function _addPotions(uint256 _amount) private {
        uint256 totalSupply = potions.totalSupply();

        potions.mint(_amount);
        potionIds = new uint256[](0);

        for (uint256 i = totalSupply; i < totalSupply + _amount; i++) {
            potionIds.push(i);
        }

        apothecary.addPotions(potionIds);
    }
}
