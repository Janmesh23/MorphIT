// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./MeshUSD.sol";

contract BillPayAggregator is ReentrancyGuard, Ownable(msg.sender) {
    MeshUSD public meshUSD;
    
    mapping(string => bool) public supportedBillTypes;
    mapping(address => uint256) public totalBillsPaid;
    
    event BillPaid(address indexed user, string billType, uint256 amount, string referenceId);
    event BillTypeAdded(string billType);
    event BillTypeRemoved(string billType);

    constructor(address _meshUSD) {
        meshUSD = MeshUSD(_meshUSD);
        
        // Initialize supported bill types
        supportedBillTypes["electricity"] = true;
        supportedBillTypes["water"] = true;
        supportedBillTypes["gas"] = true;
        supportedBillTypes["internet"] = true;
        supportedBillTypes["mobile"] = true;
    }

    function addBillType(string memory billType) external onlyOwner {
        supportedBillTypes[billType] = true;
        emit BillTypeAdded(billType);
    }

    function removeBillType(string memory billType) external onlyOwner {
        supportedBillTypes[billType] = false;
        emit BillTypeRemoved(billType);
    }

    function payBill(
        string memory billType,
        uint256 amount,
        string memory referenceId
    ) external nonReentrant {
        require(supportedBillTypes[billType], "Bill type not supported");
        require(amount > 0, "Amount must be greater than 0");
        require(bytes(referenceId).length > 0, "Reference ID required");
        
        require(meshUSD.transferFrom(msg.sender, address(this), amount), "Payment failed");
        
        totalBillsPaid[msg.sender] += amount;
        emit BillPaid(msg.sender, billType, amount, referenceId);
    }

    function withdrawFunds(uint256 amount) external onlyOwner {
        require(meshUSD.transfer(msg.sender, amount), "Withdrawal failed");
    }
}