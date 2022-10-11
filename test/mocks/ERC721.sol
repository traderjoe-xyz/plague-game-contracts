// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "openzeppelin/token/ERC721//extensions/ERC721Enumerable.sol";

contract ERC721Mock is ERC721Enumerable {
    constructor() ERC721("ERC721 Mock contract", "ERC721") {}

    function mint() external {
        _mint(msg.sender, totalSupply());
    }
}
