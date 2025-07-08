// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract MeshToken is ERC20, Ownable(msg.sender) {
    mapping(address => bool) public minters;

    constructor() ERC20("Mesh Token", "MESH") {
        _mint(msg.sender, 10000000 * 10**18); // Initial supply
    }

    modifier onlyMinter() {
        require(minters[msg.sender] || msg.sender == owner(), "Not authorized to mint");
        _;
    }

    function addMinter(address minter) external onlyOwner {
        minters[minter] = true;
    }

    function mint(address to, uint256 amount) external onlyMinter {
        _mint(to, amount);
    }
}
