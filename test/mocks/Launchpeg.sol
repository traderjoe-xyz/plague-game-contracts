// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "openzeppelin/token/ERC721//extensions/ERC721Enumerable.sol";

contract Launchpeg is ERC721Enumerable {
    constructor() ERC721("ERC721 Mock contract", "ERC721") {}

    function mint(uint256 _number) external {
        for (uint256 i = 0; i < _number; ++i) {
            _mint(msg.sender, totalSupply());
        }
    }

    function devMint(uint256 _number) external {
        for (uint256 i = 0; i < _number; ++i) {
            _mint(msg.sender, totalSupply());
        }
    }
}
