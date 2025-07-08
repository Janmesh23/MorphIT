// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./UsernameRegistry.sol";
import "./MeshUSD.sol";

contract PaymentRouter is ReentrancyGuard {
    MeshUSD public meshUSD;
    UsernameRegistry public registry;

    event PaymentSent(
        address indexed sender,
        address indexed recipient,
        string recipientUsername,
        uint256 amount
    );

    constructor(address _meshUSD, address _registry) {
        meshUSD = MeshUSD(_meshUSD);
        registry = UsernameRegistry(_registry);
    }

    function sendToUser(string memory username, uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than 0");
        
        address recipient = registry.resolve(username);
        require(recipient != address(0), "User not found");
        require(recipient != msg.sender, "Cannot send to yourself");
        
        require(meshUSD.transferFrom(msg.sender, recipient, amount), "Transfer failed");
        
        emit PaymentSent(msg.sender, recipient, username, amount);
    }

    function sendToAddress(address recipient, uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than 0");
        require(recipient != address(0), "Invalid recipient");
        require(recipient != msg.sender, "Cannot send to yourself");
        
        require(meshUSD.transferFrom(msg.sender, recipient, amount), "Transfer failed");
        
        emit PaymentSent(msg.sender, recipient, "", amount);
    }
}