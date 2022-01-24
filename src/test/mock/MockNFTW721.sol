// SPDX-License-Identifier: MIT
pragma solidity ^0.8.2;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract MockNFTW721 is ERC721, Ownable {
    constructor() ERC721("MockNFTW721", "MockNFTW721") {}

    // tokenId starts from 1
    function safeMint(address to, uint256 tokenId) public onlyOwner {
        require(tokenId > 0);
        _safeMint(to, tokenId);
    }

    function updateMetadataIPFSHash(uint _tokenId, string calldata _tokenMetadataIPFSHash) external {
        require(msg.sender == ownerOf(_tokenId), "You are not the owner of this token.");
        _tokenMetadataIPFSHash;
    }
}